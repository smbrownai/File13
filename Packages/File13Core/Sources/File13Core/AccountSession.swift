
import Foundation
import Observation

@Observable
@MainActor
public final class AccountSession: Identifiable, Hashable {
    public nonisolated let id: UUID
    public nonisolated let account: Account

    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var mailboxes: [Mailbox] = []
    public private(set) var currentMailbox: String = "INBOX"
    public private(set) var headers: [MessageHeader] = []
    /// Bumped on every mutation of `headers`. Lets `InboxStore` skip its derived caches
    /// (senders, header index, transactional set, …) when nothing actually changed. Bumped
    /// explicitly via `setHeaders` / `mutateHeaders` rather than relying on a `didSet`, since
    /// `@Observable`'s generated accessors don't always cooperate with property observers.
    public private(set) var headersVersion: Int = 0

    private func setHeaders(_ new: [MessageHeader]) {
        headers = new
        bumpHeadersVersion()
    }

    private func mutateHeaders(_ mutate: (inout [MessageHeader]) -> Void) {
        var copy = headers
        mutate(&copy)
        headers = copy
        bumpHeadersVersion()
    }

    /// Coalescing window for `headersVersion` bumps during a streaming
    /// fetch. SwiftUI's aggregate cache in `InboxStore` is busted on every
    /// bump — at 250-row batches and 20 commits/sec, that's 20 full
    /// senders/clusters/transactional rebuilds per second, which the user
    /// experiences as row-paint stutter. By coalescing bumps inside a
    /// streaming window we get the live-list look (rows still land per
    /// batch via the `headers` mutation, which is independently observed)
    /// without the rebuild storm. The aggregate views (sender list,
    /// activity dashboard, etc.) update at ~4 Hz instead of ~20 Hz —
    /// still feels live, but the renderer keeps up.
    private static let streamingBumpInterval: Duration = .milliseconds(250)

    /// True while a streaming fetch is in progress. When set,
    /// `bumpHeadersVersion` defers the bump to a coalescing task instead
    /// of firing immediately. Toggled by `beginStreamingHeaders` /
    /// `endStreamingHeaders` around the streaming commit blocks.
    @ObservationIgnored private var streamingHeadersActive: Bool = false
    @ObservationIgnored private var pendingStreamingBump: Task<Void, Never>?

    private func bumpHeadersVersion() {
        if streamingHeadersActive {
            scheduleCoalescedHeadersBump()
        } else {
            headersVersion &+= 1
        }
    }

    private func scheduleCoalescedHeadersBump() {
        if pendingStreamingBump != nil { return }
        pendingStreamingBump = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.streamingBumpInterval)
            guard let self else { return }
            self.pendingStreamingBump = nil
            // Even if the streaming window has ended by the time the
            // sleep completes, fire the bump — there's pending work that
            // hasn't yet been signaled.
            self.headersVersion &+= 1
        }
    }

    /// Begin a streaming window. While active, `mutateHeaders` /
    /// `setHeaders` callers update `headers` immediately (so SwiftUI's
    /// row-level observation still fires) but coalesce
    /// `headersVersion` bumps onto a 4 Hz timer. Public so the rule
    /// runner can batch its successive `removeFromCache` calls across
    /// many rules without thrashing the InboxStore aggregate cache.
    public func beginStreamingHeaders() {
        streamingHeadersActive = true
    }

    /// End the streaming window and force one final, immediate bump so
    /// any reader sitting on a stale aggregate cache rebuilds before the
    /// next view paint.
    public func endStreamingHeaders() {
        streamingHeadersActive = false
        pendingStreamingBump?.cancel()
        pendingStreamingBump = nil
        headersVersion &+= 1
    }

    /// Maximum number of new headers to accumulate before committing them
    /// into the live `headers` list during a streaming fetch. Smaller values
    /// produce a more "alive" list (rows visibly land as the network feeds
    /// them) at the cost of more frequent InboxStore aggregate-cache rebuilds.
    /// 250 keeps roughly ~20 commits per second on a fast server while still
    /// looking continuous to the eye.
    fileprivate static let streamingCommitBatchSize: Int = 250
    public private(set) var isRefreshing: Bool = false
    /// True when the last header fetch ended mid-stream — typically a
    /// WiFi drop or the IMAP server severing the connection partway
    /// through a full or incremental sync. The locally-visible header
    /// list is whatever we successfully collected before the error;
    /// the rest is still on the server and will arrive on the next
    /// refresh. The sidebar surfaces this on the mailbox row so the
    /// user knows the count they see isn't authoritative — without it
    /// they might delete / archive / rule what they think is the full
    /// inbox when it's actually a partial view.
    ///
    /// Cleared on successful refresh completion and on entering a
    /// new refresh attempt; set only in the partial-fetch catch
    /// branches of `performFullSync` / `performIncrementalSync`.
    public private(set) var lastFetchWasIncomplete: Bool = false
    public private(set) var fetchProgress: Int = 0
    public private(set) var fetchTotal: Int = 0
    public var lastError: String?

    fileprivate var imapClient: (any IMAPClientProtocol)?
    private let cache: MessageCache?
    private var inFlightTask: Task<Void, Never>?

    public init(account: Account, cache: MessageCache?) {
        self.id = account.id
        self.account = account
        self.cache = cache
    }

    public nonisolated static func == (lhs: AccountSession, rhs: AccountSession) -> Bool { lhs.id == rhs.id }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var archiveMailboxName: String? {
        mailboxes.first { $0.kind == .archive }?.name
    }

    public var trashMailboxName: String? {
        mailboxes.first { $0.kind == .trash }?.name
    }

    public var sentMailboxName: String? {
        mailboxes.first { $0.kind == .sent }?.name
    }

    /// Set of `rawMessageId`s the user has replied to, derived by scanning In-Reply-To values
    /// from the Sent folder. Populated by `refreshSentReplies()`. Empty until the user
    /// triggers it explicitly — Sent fetches can be slow on large mailboxes, so we don't run
    /// it automatically. Persisted across launches by `InboxStore` via `RepliedMessagesStore`.
    public private(set) var repliedMessageIds: Set<String> = []
    /// Bumped when `repliedMessageIds` changes, so `InboxStore`'s aggregate cache can
    /// detect replies-changed independently of header changes.
    public private(set) var repliedMessageIdsVersion: Int = 0

    /// Restore reply data from the persistent store on session creation. Bumps the version
    /// so any aggregate cache built off "no reply data" gets invalidated and rebuilds with
    /// the restored set.
    public func restoreRepliedMessageIds(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        repliedMessageIds = ids
        repliedMessageIdsVersion &+= 1
    }

    public var currentMailboxDisplayName: String {
        mailboxes.first { $0.name == currentMailbox }?.displayName ?? currentMailbox
    }

    // MARK: Lifecycle

    /// Authenticate against the IMAP server. Returns once auth completes (or fails). Does **not**
    /// fetch mailboxes or headers — call `startInitialSync()` to kick that off in the background.
    public func connect(credentials: AccountCredentials) async {
        await disconnect()
        lastError = nil

        let cachedHeaders = cache?.loadHeaders(accountId: account.id, mailbox: currentMailbox) ?? []
        if !cachedHeaders.isEmpty {
            setHeaders(cachedHeaders)
            connectionState = .connected
            isRefreshing = true
        } else {
            connectionState = .connecting
        }

        // Make a mutable local copy so we can zero the secret buffer
        // after the connect attempt completes. `AccountCredentials`'s
        // secret lives in a `Data` field; `clearSecrets()` calls
        // `memset_s` on it before the value goes out of scope, shrinking
        // the credential's heap-residency window to the duration of one
        // connect call instead of the lifetime of the SwiftUI signal
        // chain that produced it.
        var workingCreds = credentials
        defer { workingCreds.clearSecrets() }

        let client = SwiftMailIMAPClient()
        do {
            try await client.connect(workingCreds)
        } catch {
            handleConnectError(IMAPClientError.describe(error), hadCache: !cachedHeaders.isEmpty)
            return
        }
        imapClient = client
    }

    /// Kick off the post-auth work (mailbox listing + header fetch) in a detached, cancellable task.
    /// Returns immediately. Use `cancelFetch()` to stop in-flight work.
    public func startInitialSync() {
        cancelFetch()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshMailboxes()
            // Populate per-mailbox unseen counts in parallel with the
            // selected-mailbox header fetch — the STATUS roundtrips are
            // small and serial *inside* the call, but kicked off
            // concurrently so the user sees the inbox header table while
            // the badges fill in for other folders.
            async let statusSweep: Void = self.refreshMailboxStatuses()
            await self.performRefresh()
            _ = await statusSweep
            // Prefetch the two folders the user almost always navigates
            // to next — Archive and Sent — so the first folder-switch
            // after launch feels instant. The active mailbox stays
            // current; this just populates the SwiftData cache. Skipped
            // when sync was cancelled or failed.
            if !Task.isCancelled, case .connected = self.connectionState {
                await self.backgroundPrefetchCommonFolders()
            }
        }
        inFlightTask = task
    }

    /// Folders whose first-visit experience benefits most from a warm
    /// cache. Inbox is already the initial mailbox (no prefetch needed).
    /// Sent + Archive are the obvious next clicks; Trash is intentionally
    /// excluded because it tends to be the heaviest mailbox by volume and
    /// users rarely review it.
    private var prefetchCandidateMailboxes: [String] {
        var names: [String] = []
        if let archive = archiveMailboxName, archive != currentMailbox {
            names.append(archive)
        }
        if let sent = sentMailboxName, sent != currentMailbox, !names.contains(sent) {
            names.append(sent)
        }
        return names
    }

    /// Prefetch headers for a small set of common folders without
    /// disturbing `currentMailbox` / `headers`. Writes directly to the
    /// SwiftData cache. Designed to yield: cancellation, an outstanding
    /// `currentMailbox` change, or a user-initiated `selectMailbox` will
    /// all naturally interrupt the work (the per-folder block re-checks
    /// `Task.isCancelled`, and a real selectMailbox will issue its own
    /// `refresh()` that selects the same mailbox cleanly).
    private func backgroundPrefetchCommonFolders() async {
        guard let client = imapClient, let cache else { return }
        let candidates = prefetchCandidateMailboxes
        for mailbox in candidates {
            if Task.isCancelled { return }
            if mailbox == currentMailbox { continue }
            // If the cache already has data for this mailbox, skip — the
            // user has presumably opened it before. We trade "freshness"
            // for "snappy first switch"; subsequent selectMailbox will
            // refresh on entry.
            let existing = cache.loadHeaders(accountId: account.id, mailbox: mailbox)
            if !existing.isEmpty { continue }
            await prefetchSingleMailbox(mailbox, client: client, cache: cache)
        }
    }

    private func prefetchSingleMailbox(_ mailbox: String, client: any IMAPClientProtocol, cache: MessageCache) async {
        let snapshot: UIDFlagsSnapshot
        do {
            snapshot = try await client.fetchUIDFlags(accountId: account.id, mailbox: mailbox)
        } catch {
            return
        }
        if Task.isCancelled { return }
        // If the user has navigated into this mailbox in the meantime,
        // bail out — the user-facing `performRefresh` will do its own
        // fetch and write authoritative data.
        if mailbox == currentMailbox { return }
        let fetch: HeadersFetch
        do {
            fetch = try await client.fetchHeaders(accountId: account.id, mailbox: mailbox)
        } catch {
            return
        }
        var collected: [MessageHeader] = []
        collected.reserveCapacity(fetch.totalCount)
        do {
            for try await header in fetch.stream {
                if Task.isCancelled { return }
                if mailbox == currentMailbox { return }
                collected.append(header)
            }
        } catch {
            // Partial fetch — drop it rather than persist a partial cache.
            return
        }
        if Task.isCancelled { return }
        if mailbox == currentMailbox { return }
        try? cache.replaceHeaders(collected, accountId: account.id, mailbox: mailbox)
        cache.setUIDValidity(snapshot.uidValidity, accountId: account.id, mailbox: mailbox)
        invalidateNonActiveCache(for: mailbox)
    }

    public func cancelFetch() {
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    public func disconnect() async {
        if let client = imapClient {
            await client.disconnect()
        }
        imapClient = nil
        mailboxes = []
        currentMailbox = "INBOX"
        setHeaders([])
        invalidateAllNonActiveCache()
        isRefreshing = false
        connectionState = .disconnected
    }

    public func refreshMailboxes() async {
        guard let client = imapClient else { return }
        do {
            let list = try await client.listMailboxes()
            mailboxes = sortedForSidebar(list)
        } catch {
            lastError = "Couldn't list folders: \(IMAPClientError.describe(error))"
        }
    }

    /// Run `STATUS (UNSEEN MESSAGES)` against every listed mailbox and
    /// populate `Mailbox.unseenCount` / `Mailbox.messageCount`. Cheap
    /// metadata roundtrips — no headers fetched — so this stays in the
    /// "few hundred milliseconds total for a typical account" budget.
    ///
    /// Why: without this, `unreadCount(in:)` callers derive a badge from
    /// the SwiftData header cache, which has no entries for mailboxes the
    /// user has never opened — so a never-visited folder shows no badge
    /// even when it has unread mail. The sidebar (macOS) and the
    /// mailbox-picker menu (iOS) both rely on `Mailbox.unseenCount` when
    /// it's non-nil, with the cache count as fallback.
    ///
    /// Best-effort: per-mailbox failures don't fail the sweep. A folder
    /// the server refuses to STATUS (e.g. `\Noselect` parents on some
    /// servers — the listMailboxes filter usually drops those, but we
    /// still tolerate it) stays at `nil` rather than poisoning the
    /// remaining results.
    public func refreshMailboxStatuses() async {
        guard let client = imapClient else { return }
        var updated = mailboxes
        for index in updated.indices {
            if Task.isCancelled { return }
            // Skip IMAP `\Noselect` containers (e.g. Gmail's bare `[Gmail]`
            // parent). STATUS against them returns NONEXISTENT and just
            // pollutes the log — and on a constrained command budget, a
            // failed STATUS still costs us a round-trip plus a forced
            // reconnect on some servers.
            guard updated[index].isSelectable else { continue }
            let name = updated[index].name
            guard let status = try? await client.mailboxStatus(name) else { continue }
            updated[index].messageCount = status.messageCount ?? updated[index].messageCount
            updated[index].unseenCount = status.unseenCount
        }
        // `mailboxes` is `@Observable`-tracked; assigning the rebuilt
        // array is what tells dependent views (sidebar, picker menu) to
        // re-render.
        guard imapClient != nil else { return }
        mailboxes = updated
    }

    /// One-shot fetch of the Sent folder to build the "messages we've replied to" index.
    /// Reads `In-Reply-To` from each sent message and stashes the referenced ids. Called
    /// from `InboxStore.refreshAllSentReplies()` when the user opts into reply detection.
    /// Best-effort — failures are swallowed because reply data is enrichment, not load-bearing.
    public func refreshSentReplies() async {
        guard let client = imapClient, let sent = sentMailboxName else { return }
        let fetch: HeadersFetch
        do {
            fetch = try await client.fetchHeaders(accountId: account.id, mailbox: sent)
        } catch {
            return
        }
        var replies: Set<String> = []
        do {
            for try await header in fetch.stream {
                if Task.isCancelled { return }
                if let inReplyTo = header.inReplyTo, !inReplyTo.isEmpty {
                    replies.insert(inReplyTo)
                }
            }
        } catch {
            // Partial result is still useful — keep what we collected.
        }
        repliedMessageIds = replies
        repliedMessageIdsVersion &+= 1
    }

    /// User-initiated refresh. Cancels any in-flight work first so explicit refreshes always start
    /// from a clean slate.
    public func refresh() async {
        cancelFetch()
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        inFlightTask = task
        await task.value
    }

    private func performRefresh() async {
        guard let client = imapClient else { return }
        if headers.isEmpty {
            connectionState = .fetching
        } else {
            isRefreshing = true
        }
        let mailbox = currentMailbox
        fetchProgress = 0
        fetchTotal = 0
        // Clear the partial-fetch flag at the start of every refresh —
        // a fresh attempt is allowed to succeed cleanly. The
        // mid-stream-failure branches below will re-set it if needed.
        lastFetchWasIncomplete = false

        // Phase 1: Always fetch UID+flags first. It's cheap and tells us:
        //   - Whether UIDValidity changed (server-side reset → rebuild from scratch)
        //   - The current set of UIDs and their flag state
        let snapshot: UIDFlagsSnapshot
        do {
            snapshot = try await client.fetchUIDFlags(accountId: account.id, mailbox: mailbox)
        } catch {
            guard mailbox == currentMailbox else { return }
            if headers.isEmpty {
                connectionState = .failed(IMAPClientError.describe(error))
            } else {
                lastError = IMAPClientError.describe(error)
                isRefreshing = false
            }
            return
        }
        guard mailbox == currentMailbox else { return }
        if Task.isCancelled {
            handleFetchCancelled(collected: headers, total: snapshot.messageCount)
            return
        }

        let storedValidity = cache?.loadUIDValidity(accountId: account.id, mailbox: mailbox)
        let canDiff = storedValidity == snapshot.uidValidity && !headers.isEmpty

        if canDiff {
            await performIncrementalSync(snapshot: snapshot, mailbox: mailbox, client: client)
        } else {
            if storedValidity != nil, storedValidity != snapshot.uidValidity {
                // UID space was reset on the server side; bust the local cache.
                try? cache?.replaceHeaders([], accountId: account.id, mailbox: mailbox)
                headers = []
                connectionState = .fetching
            }
            await performFullSync(mailbox: mailbox, client: client)
            cache?.setUIDValidity(snapshot.uidValidity, accountId: account.id, mailbox: mailbox)
        }
    }

    private func performIncrementalSync(
        snapshot: UIDFlagsSnapshot,
        mailbox: String,
        client: any IMAPClientProtocol
    ) async {
        // `Dictionary(uniqueKeysWithValues:)` traps on duplicate keys, which
        // we *shouldn't* see — UIDs are unique per (account, mailbox,
        // UIDVALIDITY) by IMAP guarantee, and per-row in the SwiftData store.
        // But "shouldn't" isn't the same as "can't": cache corruption from
        // crashed mid-writes, schema migrations that double-inserted rows, or
        // a server that returns the same UID twice in one response can all
        // produce duplicates. Trapping the user out of their inbox over it is
        // a much worse failure mode than silently deduping. We collapse
        // duplicates last-write-wins (newest cached row representation) and
        // continue.
        let serverFlags = Dictionary(
            snapshot.entries.map { ($0.uid, $0.isRead) },
            uniquingKeysWith: { _, new in new }
        )
        let serverUIDs = Set(serverFlags.keys)
        let cachedByUID = Dictionary(
            headers.compactMap { h in h.uid.map { ($0, h) } },
            uniquingKeysWith: { _, new in new }
        )
        let cachedUIDs = Set(cachedByUID.keys)

        let newUIDs = serverUIDs.subtracting(cachedUIDs)
        let deletedUIDs = cachedUIDs.subtracting(serverUIDs)
        var flagUpdates: [UInt32: Bool] = [:]
        for (uid, serverIsRead) in serverFlags {
            if let cached = cachedByUID[uid], cached.isRead != serverIsRead {
                flagUpdates[uid] = serverIsRead
            }
        }

        if newUIDs.isEmpty && deletedUIDs.isEmpty && flagUpdates.isEmpty {
            connectionState = .connected
            isRefreshing = false
            fetchProgress = 0
            fetchTotal = 0
            return
        }

        // Phase 2a: apply deletions and flag updates to the local list NOW,
        // before the new-headers stream starts. The user gets the fresh state
        // of what they already have within one server round-trip — they don't
        // have to wait through the (potentially slow) new-headers fetch to
        // see read-marks flip or deleted rows disappear. New headers stream
        // in on top of this base.
        var base = headers
        if !deletedUIDs.isEmpty || !flagUpdates.isEmpty {
            var i = base.startIndex
            while i < base.endIndex {
                let h = base[i]
                if let uid = h.uid {
                    if deletedUIDs.contains(uid) {
                        base.remove(at: i)
                        continue
                    }
                    if let newIsRead = flagUpdates[uid] {
                        // Forward every field by going through `withRead`. The earlier
                        // explicit-init form silently dropped list-* headers, sizeBytes,
                        // toAddresses/ccAddresses, isAutoSubmitted, inReplyTo, and
                        // hasAttachments to their defaults on every read-state flip from
                        // another mail client.
                        base[i] = h.withRead(newIsRead)
                    }
                }
                i = base.index(after: i)
            }
            setHeaders(base)
        }

        // Phase 2b: fetch headers for new UIDs and stream them into the live
        // list in batches. Every ~250 headers we commit what's been collected
        // so rows appear as the network delivers them. `headersVersion` is
        // coalesced via the streaming window (~4 Hz) so the aggregate cache
        // rebuilds at a tolerable rate even when batches arrive 20× per sec.
        var newHeaders: [MessageHeader] = []
        if !newUIDs.isEmpty {
            beginStreamingHeaders()
            defer { endStreamingHeaders() }
            fetchTotal = newUIDs.count
            let fetch: HeadersFetch
            do {
                fetch = try await client.fetchHeaders(uids: newUIDs, accountId: account.id, mailbox: mailbox)
            } catch {
                guard mailbox == currentMailbox else { return }
                lastError = IMAPClientError.describe(error)
                isRefreshing = false
                fetchProgress = 0
                fetchTotal = 0
                return
            }
            guard mailbox == currentMailbox else { return }
            var pendingBatch: [MessageHeader] = []
            pendingBatch.reserveCapacity(Self.streamingCommitBatchSize)
            do {
                for try await header in fetch.stream {
                    if Task.isCancelled { break }
                    newHeaders.append(header)
                    pendingBatch.append(header)
                    if pendingBatch.count >= Self.streamingCommitBatchSize {
                        mutateHeaders { $0.append(contentsOf: pendingBatch) }
                        pendingBatch.removeAll(keepingCapacity: true)
                        fetchProgress = newHeaders.count
                    } else if newHeaders.count % 25 == 0 {
                        // Below the commit threshold we still surface progress
                        // so the iOS / sidebar bars stay alive on small
                        // mailboxes that finish in a single batch.
                        fetchProgress = newHeaders.count
                    }
                }
            } catch is CancellationError {
                guard mailbox == currentMailbox else { return }
                if !pendingBatch.isEmpty {
                    mutateHeaders { $0.append(contentsOf: pendingBatch) }
                }
                handleFetchCancelled(collected: headers, total: snapshot.messageCount)
                return
            } catch {
                guard mailbox == currentMailbox else { return }
                if !pendingBatch.isEmpty {
                    mutateHeaders { $0.append(contentsOf: pendingBatch) }
                }
                lastError = "Fetch interrupted at \(newHeaders.count.formatted()) of \(newUIDs.count.formatted()) new messages: \(IMAPClientError.describe(error))"
                isRefreshing = false
                fetchProgress = 0
                fetchTotal = 0
                // Partial: caller still applies what we got — the cache write
                // below works with `headers` as a single source of truth.
                // Mark incomplete so the sidebar row warns the user.
                lastFetchWasIncomplete = true
            }
            if !pendingBatch.isEmpty {
                mutateHeaders { $0.append(contentsOf: pendingBatch) }
            }
        }

        // `headers` is now authoritative — base mutations were committed
        // above and new headers streamed in. Just refresh the steady-state
        // flags.
        connectionState = .connected
        isRefreshing = false
        fetchProgress = 0
        fetchTotal = 0

        try? cache?.applyDiff(
            accountId: account.id,
            mailbox: mailbox,
            deletedUIDs: deletedUIDs,
            flagUpdates: flagUpdates,
            insertedHeaders: newHeaders
        )
    }

    private func performFullSync(mailbox: String, client: any IMAPClientProtocol) async {
        let fetch: HeadersFetch
        do {
            fetch = try await client.fetchHeaders(accountId: account.id, mailbox: mailbox)
        } catch {
            guard mailbox == currentMailbox else { return }
            if headers.isEmpty {
                connectionState = .failed(IMAPClientError.describe(error))
            } else {
                lastError = IMAPClientError.describe(error)
                isRefreshing = false
            }
            return
        }
        guard mailbox == currentMailbox else { return }
        fetchTotal = fetch.totalCount

        var collected: [MessageHeader] = []
        collected.reserveCapacity(fetch.totalCount)
        var pendingBatch: [MessageHeader] = []
        pendingBatch.reserveCapacity(Self.streamingCommitBatchSize)

        // On a full sync the list starts empty — committing in batches lets
        // the first rows land within hundreds of ms instead of waiting for
        // the whole mailbox to arrive. Same trade-offs as
        // `performIncrementalSync`'s streaming block; see that comment.
        beginStreamingHeaders()
        defer { endStreamingHeaders() }
        do {
            for try await header in fetch.stream {
                if Task.isCancelled { break }
                collected.append(header)
                pendingBatch.append(header)
                if pendingBatch.count >= Self.streamingCommitBatchSize {
                    let batch = pendingBatch
                    pendingBatch.removeAll(keepingCapacity: true)
                    mutateHeaders { $0.append(contentsOf: batch) }
                    fetchProgress = collected.count
                    if connectionState != .connected {
                        // First batch of a never-before-seen mailbox flips us
                        // out of the full-screen `.fetching` UI as soon as we
                        // have something to show.
                        connectionState = .connected
                        isRefreshing = true
                    }
                } else if collected.count % 25 == 0 {
                    fetchProgress = collected.count
                }
            }
            guard mailbox == currentMailbox else { return }
            if Task.isCancelled {
                if !pendingBatch.isEmpty {
                    mutateHeaders { $0.append(contentsOf: pendingBatch) }
                }
                handleFetchCancelled(collected: collected, total: fetch.totalCount)
                return
            }
            if !pendingBatch.isEmpty {
                mutateHeaders { $0.append(contentsOf: pendingBatch) }
            }
            connectionState = .connected
            isRefreshing = false
            fetchProgress = 0
            fetchTotal = 0
            try? cache?.replaceHeaders(collected, accountId: account.id, mailbox: mailbox)
        } catch is CancellationError {
            guard mailbox == currentMailbox else { return }
            handleFetchCancelled(collected: collected, total: fetch.totalCount)
        } catch {
            guard mailbox == currentMailbox else { return }
            setHeaders(collected)
            fetchProgress = 0
            fetchTotal = 0
            if collected.isEmpty {
                connectionState = .failed(IMAPClientError.describe(error))
            } else {
                lastError = "Fetch interrupted at \(collected.count.formatted()) of \(fetch.totalCount.formatted()): \(IMAPClientError.describe(error))"
                connectionState = .connected
                isRefreshing = false
                // Mark the mailbox as showing partial data. The sidebar
                // row will append "(incomplete)" so the user knows
                // their count isn't authoritative; the next refresh
                // will backfill the remaining headers.
                lastFetchWasIncomplete = true
            }
        }
    }

    private func handleFetchCancelled(collected: [MessageHeader], total: Int) {
        setHeaders(collected)
        fetchProgress = 0
        fetchTotal = 0
        isRefreshing = false
        if collected.isEmpty {
            connectionState = .disconnected
            lastError = "Sync cancelled."
        } else {
            connectionState = .connected
            lastError = "Sync cancelled at \(collected.count.formatted()) of \(total.formatted())."
        }
    }

    public func selectMailbox(_ name: String) async {
        guard name != currentMailbox else { return }
        // Refuse to SELECT a `\Noselect` container. Defense in depth on
        // top of the sidebar's click guard — callers in tests, the CLI,
        // and any future entry point should all get the same answer
        // (silent no-op) rather than letting the IMAP server return
        // NONEXISTENT after we've already mutated `currentMailbox`.
        if let mailbox = mailboxes.first(where: { $0.name == name }), !mailbox.isSelectable {
            return
        }
        currentMailbox = name
        // The formerly-active mailbox is now eligible for the non-active
        // cache; clear the whole cache so a re-read picks up its current
        // SwiftData state instead of any stale entry, and so the newly-
        // active mailbox's old non-active entry can't shadow live data.
        invalidateAllNonActiveCache()
        setHeaders([])

        let cached = cache?.loadHeaders(accountId: account.id, mailbox: name) ?? []
        if !cached.isEmpty {
            setHeaders(cached)
            connectionState = .connected
            isRefreshing = imapClient != nil
        } else {
            connectionState = imapClient != nil ? .fetching : .disconnected
        }
        if imapClient != nil {
            await refresh()
        }
    }

    public func createMailbox(_ name: String) async throws {
        guard let client = imapClient else { throw IMAPClientError.notConnected }
        try await client.createMailbox(name)
        await refreshMailboxes()
    }

    public func deleteMailbox(_ name: String) async throws {
        guard let client = imapClient else { throw IMAPClientError.notConnected }
        try await client.deleteMailbox(name)
        if currentMailbox == name {
            await selectMailbox("INBOX")
        }
        await refreshMailboxes()
    }

    public func renameMailbox(from source: String, to destination: String) async throws {
        guard let client = imapClient else { throw IMAPClientError.notConnected }
        try await client.renameMailbox(from: source, to: destination)
        if currentMailbox == source {
            currentMailbox = destination
        }
        await refreshMailboxes()
    }

    // MARK: Mutations driven by InboxStore

    /// Optimistically remove from local headers; caller is responsible for the server commit.
    public func removeMessages(matching ids: Set<String>) {
        mutateHeaders { $0.removeAll { ids.contains($0.id) } }
    }

    /// Add `delta` to a mailbox's cached STATUS message count so the sidebar
    /// chip stays in lockstep with optimistic mutations. The authoritative
    /// number gets reconciled when `refreshMailboxStatuses()` runs after the
    /// server commit completes — this is just the bridge between "user
    /// clicked Delete" and "server confirmed the change."
    ///
    /// Why a manual adjustment instead of always waiting for STATUS:
    /// committing happens after the undo buffer (30s by default), so the
    /// chip would lie for half a minute on every action. Worse, the
    /// optimistic header removal already happens at schedule time — without
    /// this, the row list shrinks immediately but the badge still claims
    /// the old total. Adjusting the count alongside the header mutation
    /// keeps the two views consistent until STATUS lands.
    ///
    /// Clamps to zero. If `messageCount` was `nil` (never-fetched mailbox)
    /// we leave it `nil` rather than fabricating a starting count — the
    /// chip can stay blank until a real STATUS arrives.
    public func adjustMessageCount(for mailboxName: String, by delta: Int) {
        guard delta != 0,
              let index = mailboxes.firstIndex(where: { $0.name == mailboxName })
        else { return }
        guard let current = mailboxes[index].messageCount else { return }
        var updated = mailboxes
        updated[index].messageCount = max(0, current + delta)
        mailboxes = updated
    }

    /// Memoize the SwiftData fetch for non-active mailboxes. The iOS
    /// mailbox picker reads `headers(in:)` once per row to compute the
    /// unread badge — opening the menu fires N SwiftData fetches without
    /// this cache. Invalidated on `selectMailbox`, `disconnect`, and any
    /// path that writes to a non-active mailbox's cache rows
    /// (`removeFromCache`, `replaceHeaders` on disk, full refresh).
    /// Active mailbox is served from in-memory `headers` and not stored
    /// here.
    @ObservationIgnored private var nonActiveHeadersCache: [String: [MessageHeader]] = [:]

    /// Drop one mailbox's entry from the non-active headers cache. Called
    /// from every site that mutates the SwiftData backing for a non-
    /// active mailbox so stale rows can't persist between refreshes.
    private func invalidateNonActiveCache(for mailbox: String) {
        nonActiveHeadersCache.removeValue(forKey: mailbox)
    }

    /// Drop the entire non-active cache. Used when the active mailbox
    /// changes (the formerly-active mailbox becomes a non-active cache
    /// candidate; the former entry for the newly-active mailbox is now
    /// served from in-memory). Cheaper than tracking which keys to
    /// invalidate and the cache rebuilds on next read anyway.
    private func invalidateAllNonActiveCache() {
        nonActiveHeadersCache.removeAll(keepingCapacity: true)
    }

    /// Headers in `mailbox`. If it matches the active mailbox we return the
    /// in-memory `headers` (which include any pending optimistic mutations);
    /// otherwise we read from the SwiftData cache, which is the authoritative
    /// snapshot for non-active mailboxes. Non-active reads hit the
    /// per-session memoization cache — the second and subsequent calls
    /// for the same mailbox within one refresh window are O(1).
    public func headers(in mailbox: String) -> [MessageHeader] {
        if mailbox == currentMailbox { return headers }
        if let cached = nonActiveHeadersCache[mailbox] { return cached }
        let fresh = cache?.loadHeaders(accountId: account.id, mailbox: mailbox) ?? []
        nonActiveHeadersCache[mailbox] = fresh
        return fresh
    }

    /// Drop the given message ids from `mailbox` in the local cache.
    /// Used by folder-aware rule runs when the rule operates on a mailbox
    /// the user isn't currently viewing — `removeMessages(matching:)` only
    /// touches the active mailbox's in-memory headers, so non-active
    /// mailboxes need this direct cache update.
    public func removeFromCache(matching ids: Set<String>, in mailbox: String) {
        if mailbox == currentMailbox {
            removeMessages(matching: ids)
            return
        }
        guard let cache, !ids.isEmpty else { return }
        let current = cache.loadHeaders(accountId: account.id, mailbox: mailbox)
        guard !current.isEmpty else { return }
        let filtered = current.filter { !ids.contains($0.id) }
        guard filtered.count != current.count else { return }
        try? cache.replaceHeaders(filtered, accountId: account.id, mailbox: mailbox)
        invalidateNonActiveCache(for: mailbox)
    }

    /// Restore the in-memory headers from a snapshot (used to undo a delete or archive).
    public func replaceHeaders(_ newHeaders: [MessageHeader]) {
        setHeaders(newHeaders)
    }

    /// Delete by UID on the server. `expectedUIDValidity` pins the operation
    /// to the UIDVALIDITY the caller's UIDs were captured under — if the
    /// server's current UIDVALIDITY differs, the operation is refused and
    /// `lastError` is set to a user-actionable message. Pass `nil` only when
    /// the caller has no prior validity to compare against.
    public func deleteMessages(
        uids: [UInt32],
        in mailbox: String,
        isDryRun: Bool,
        expectedUIDValidity: UInt64?
    ) async {
        guard !uids.isEmpty, !isDryRun, let client = imapClient else { return }
        do {
            try await client.deleteMessages(
                uids: uids,
                in: mailbox,
                expectedUIDValidity: expectedUIDValidity
            )
        } catch IMAPClientError.uidValidityChanged {
            lastError = "Refused to delete: \(mailbox) changed on the server. Refresh and try again."
            // Drop the local cache for this mailbox so the next refresh does a
            // full re-sync against the new UIDVALIDITY namespace.
            try? cache?.replaceHeaders([], accountId: account.id, mailbox: mailbox)
            cache?.clearUIDValidity(accountId: account.id, mailbox: mailbox)
        } catch {
            // Could be a cross-device race: another Mac / iPhone moved or
            // deleted these UIDs first, our commit then NO'd. Verify before
            // surfacing — if the UIDs are gone from the source mailbox, the
            // user's local optimistic removal already matches the outcome
            // and an error message would just be confusing.
            if await raceAlreadyResolved(uids: uids, in: mailbox) { return }
            lastError = "Couldn't delete on server: \(IMAPClientError.describe(error))"
        }
    }

    public func moveMessages(
        uids: [UInt32],
        from source: String,
        to destination: String,
        isDryRun: Bool,
        expectedUIDValidity: UInt64?
    ) async {
        guard !uids.isEmpty, !isDryRun, let client = imapClient else { return }
        do {
            try await client.moveMessages(
                uids: uids,
                from: source,
                to: destination,
                expectedUIDValidity: expectedUIDValidity
            )
        } catch IMAPClientError.uidValidityChanged {
            lastError = "Refused to move: \(source) changed on the server. Refresh and try again."
            try? cache?.replaceHeaders([], accountId: account.id, mailbox: source)
            cache?.clearUIDValidity(accountId: account.id, mailbox: source)
        } catch {
            if await raceAlreadyResolved(uids: uids, in: source) { return }
            lastError = "Couldn't move on server: \(IMAPClientError.describe(error))"
        }
    }

    /// After a `deleteMessages` / `moveMessages` failure, ask the server for
    /// the current UID set in `mailbox` and decide whether the failure was
    /// actually a benign cross-device race. Returns `true` when **none** of
    /// the operation's UIDs are still present in the source mailbox — meaning
    /// another device (or the user's own action on a different Mac) already
    /// moved or deleted them. Our local optimistic removal already matches
    /// that outcome, so the right move is to swallow the error.
    ///
    /// Returns `false` when:
    /// - The verification fetch itself failed (network gone, auth lost) →
    ///   we shouldn't claim "all good" without proof; surface the original.
    /// - Some or all of the UIDs are still present in the source → this was
    ///   a real server-side failure (permission, quota, missing destination,
    ///   …), and the user needs to see it because their local view now
    ///   disagrees with what's actually on the server.
    private func raceAlreadyResolved(uids: [UInt32], in mailbox: String) async -> Bool {
        guard let client = imapClient, !uids.isEmpty else { return false }
        do {
            let snapshot = try await client.fetchUIDFlags(
                accountId: account.id,
                mailbox: mailbox
            )
            let serverUIDs = Set(snapshot.entries.map(\.uid))
            return Set(uids).intersection(serverUIDs).isEmpty
        } catch {
            return false
        }
    }

    /// Empty an entire mailbox — server-side STORE `\Deleted` on every
    /// message followed by EXPUNGE, then refresh local state to match.
    /// Used by the "Empty Trash" sidebar action. Unlike `deleteMessages` /
    /// `moveMessages`, this isn't UID-pinned: the user's intent is "remove
    /// everything currently here," so a UIDVALIDITY rotation between
    /// listing and acting is not a reason to refuse. If the active mailbox
    /// is the one being emptied, the in-memory headers and the SwiftData
    /// rows are wiped to match the server.
    ///
    /// Returns the number of messages the server reported at selection
    /// time. The caller surfaces this in a confirmation message; it's not
    /// load-bearing for correctness.
    @discardableResult
    public func emptyMailbox(_ mailbox: String) async -> Int {
        guard let client = imapClient else { return 0 }
        let removedCount: Int
        do {
            removedCount = try await client.emptyMailbox(mailbox)
        } catch {
            lastError = "Couldn't empty \(mailbox): \(IMAPClientError.describe(error))"
            return 0
        }
        if mailbox == currentMailbox {
            setHeaders([])
        }
        try? cache?.replaceHeaders([], accountId: account.id, mailbox: mailbox)
        invalidateNonActiveCache(for: mailbox)
        // Snap the sidebar chip to zero immediately. STATUS would do this
        // too, but only after the next refresh round-trip; this avoids the
        // jump-then-settle on the just-emptied row.
        if let index = mailboxes.firstIndex(where: { $0.name == mailbox }) {
            var updated = mailboxes
            updated[index].messageCount = 0
            updated[index].unseenCount = 0
            mailboxes = updated
        }
        return removedCount
    }

    /// Read the last-known UIDVALIDITY for a mailbox from the local cache.
    /// Callers use this to capture the value at action-build time so it can
    /// be passed to `deleteMessages` / `moveMessages` at commit time. Returns
    /// `nil` when the mailbox has never been synced — in which case the
    /// caller should pass `nil` for `expectedUIDValidity` (no expectation).
    public func uidValidity(for mailbox: String) -> UInt64? {
        cache?.loadUIDValidity(accountId: account.id, mailbox: mailbox)
    }

    private func handleConnectError(_ message: String, hadCache: Bool) {
        if hadCache {
            // Previously stayed in `.connected` with `lastError` set, which
            // misled the sidebar into rendering an "active" account.
            // `.offlineWithCache` carries the same headers (the cache load
            // happened before this call) but lets the sidebar render a
            // distinct gray "offline" glyph and prevents downstream code
            // from treating the session as truly online.
            lastError = "Couldn't reach mail server: \(message). Showing last-known headers."
            isRefreshing = false
            connectionState = .offlineWithCache(message)
        } else {
            connectionState = .failed(message)
        }
    }

    private func sortedForSidebar(_ boxes: [Mailbox]) -> [Mailbox] {
        boxes.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
