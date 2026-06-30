import Foundation
import Observation

public enum SortField: String, CaseIterable, Identifiable, Hashable, Sendable {
    case name, address, count, unread, mostRecent
    public var id: String { rawValue }
}

public enum SortDirection: Hashable, Sendable {
    case ascending, descending
    public mutating func toggle() { self = (self == .ascending) ? .descending : .ascending }
}

public enum DisplayMode: String, CaseIterable, Identifiable {
    case sender, subject, date
    public var id: String { rawValue }
    public var label: String {
        switch self { case .sender: "Senders"; case .subject: "Subjects"; case .date: "Dates" }
    }
    public var symbol: String {
        switch self { case .sender: "person.2"; case .subject: "text.alignleft"; case .date: "calendar" }
    }
}

public enum InboxScope: Hashable {
    case unified
    case account(UUID)
}

@Observable
@MainActor
public final class InboxStore {
    public private(set) var sessions: [AccountSession] = []
    public var scope: InboxScope = .unified

    /// Used only for the demo experience when no real accounts are connected.
    private var demoHeaders: [MessageHeader] = []

    /// Raw search input the views bind to. Setting this schedules a short
    /// debounce that copies the value into `effectiveSearch`, which is what
    /// `displaySenders` / `subjectClusters` actually filter against. Keeps
    /// keystroke latency down on large mailboxes — the filter+sort pipeline
    /// only runs once the user pauses typing, not on every character.
    @ObservationIgnored private var _searchStorage: String = ""
    public var search: String {
        get {
            access(keyPath: \.search)
            return _searchStorage
        }
        set {
            withMutation(keyPath: \.search) {
                _searchStorage = newValue
            }
            scheduleSearchDebounce()
        }
    }

    /// Debounced search value that the display projections actually read.
    /// Empty strings propagate immediately (clearing the field should feel
    /// instant); non-empty strings settle after `searchDebounceInterval`.
    public private(set) var effectiveSearch: String = ""

    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    /// Delay between the last keystroke and applying the search. 200 ms feels
    /// like "no lag" to most users while still cutting the per-character
    /// filter+sort cost on a typed-out word from ~6 runs to 1.
    private static let searchDebounceInterval: Duration = .milliseconds(200)

    public var sortField: SortField = .count
    public var sortDirection: SortDirection = .descending
    public var displayMode: DisplayMode = .sender
    public var newslettersOnly: Bool = false
    public var expandedSenderIds: Set<String> = []
    public var expandedSubjectIds: Set<String> = []
    public var expandedBucketIds: Set<DateBucketKind> = []

    /// Single source of truth for the user's selection. Sender-row checks materialize all of
    /// the sender's current message IDs into this set; cluster/bucket/message checks insert/
    /// remove individual IDs. This collapses the previous dual-set model so that O(1) lookups
    /// suffice in row bodies and selection-derived helpers run in O(selection.count) instead
    /// of O(allHeaders) per read.
    public var selectedMessageIds: Set<String> = []

    /// The sender currently shown in the right-hand inspector pane, if any. A row tap in
    /// `SenderListView` sets this; the inspector view subscribes and renders the sender's
    /// messages, AI insights, and per-sender actions.
    public var inspectedSenderId: String?
    /// Subject cluster currently shown in the inspector. Set by row tap in `SubjectListView`.
    /// Mutually exclusive with `inspectedSenderId` — setting either should clear the other so
    /// the inspector renders one focused thing at a time.
    public var inspectedSubjectClusterId: String?

    public var lastError: String?

    public private(set) var pendingAction: PendingAction?

    private var actionTask: Task<Void, Never>?
    /// Long-running task that periodically refreshes all connected sessions when the user has
    /// chosen a non-manual refresh schedule. Reset whenever the schedule changes.
    @ObservationIgnored private var scheduledRefreshTask: Task<Void, Never>?
    /// Background categorization task. Held here so concurrent refresh calls can't fire
    /// duplicate AI runs against the same uncategorized senders.
    @ObservationIgnored private var autoCategorizationTask: Task<Void, Never>?
    private let cache: MessageCache?
    private var settings: SettingsStore?
    /// Category lookup for rule evaluation. `nil` simply means rules with a category condition
    /// won't match (safe default — no data ⇒ no automated action).
    @ObservationIgnored private var categoryStore: SenderCategoryStore?
    /// VIP lookup for rule evaluation. `nil` means we have no VIP data yet, so the
    /// "protect VIPs from rules" gate becomes a no-op.
    @ObservationIgnored private var vipStore: VIPStore?
    /// Persistent reply data. `nil` means in-memory-only — fine for tests, but the app wires
    /// in a real store so reply detection survives launches.
    @ObservationIgnored private var repliedStore: RepliedMessagesStore?

    // MARK: Aggregate caches (rebuilt only when the underlying inputs change)
    //
    // SwiftUI re-runs view bodies on every observable mutation. These caches keep
    // `senders` / `subjectClusters` / header-by-id index / transactional id set from being
    // recomputed on every read — they're rebuilt only when the input fingerprint changes
    // (sessions × headersVersion, scope, newslettersOnly, or demo mode).

    @ObservationIgnored private var _aggregateFP: AggregateFingerprint?
    @ObservationIgnored private var _allHeadersCache: [MessageHeader] = []
    @ObservationIgnored private var _headersByIdCache: [String: MessageHeader] = [:]
    @ObservationIgnored private var _sendersCache: [Sender] = []
    @ObservationIgnored private var _sendersByIdCache: [String: Sender] = [:]
    @ObservationIgnored private var _transactionalIdsCache: Set<String> = []
    @ObservationIgnored private var _subjectClustersCache: [SubjectCluster] = []
    @ObservationIgnored private var _subjectClustersByIdCache: [String: SubjectCluster] = [:]
    @ObservationIgnored private var _dateBucketsCache: [DateBucket] = []
    /// Last-published activity report. Deliberately NOT
    /// `@ObservationIgnored` — the async recompute path mutates this from
    /// a continuation, and views that read `activityReport` need to
    /// re-render when the new value lands. The rest of the per-aggregate
    /// caches stay `@ObservationIgnored` because they're (re)built
    /// synchronously inside `ensureAggregateCache` and views latch onto
    /// the underlying inputs instead.
    private var _activityReportCache: ActivityReport?
    /// Bumped whenever the aggregate fingerprint changes, signaling that
    /// the displayed `_activityReportCache` is stale. The next read of
    /// `activityReport` kicks an off-main recompute when the published
    /// version trails this one.
    @ObservationIgnored private var _activityReportInputVersion: Int = 0
    /// Version of inputs that produced the current `_activityReportCache`.
    /// When `_activityReportInputVersion > _activityReportPublishedVersion`,
    /// the displayed cache is stale and a recompute is needed.
    @ObservationIgnored private var _activityReportPublishedVersion: Int = 0
    /// In-flight recompute task, kept so we can cancel it when a newer
    /// invalidation arrives before this one finishes.
    @ObservationIgnored private var _activityReportTask: Task<Void, Never>?
    @ObservationIgnored private var _demoVersion: Int = 0

    // Secondary caches keyed off the user's search/sort knobs. Busted whenever the
    // primary aggregate fingerprint changes, so they never serve stale data. Without
    // these, every keystroke in the search field re-filters and re-sorts O(N log N)
    // even when the sender list itself hasn't moved.
    @ObservationIgnored private var _displaySendersCache: [Sender]?
    @ObservationIgnored private var _displaySendersKey: DisplaySendersKey?
    @ObservationIgnored private var _displayClustersCache: [SubjectCluster]?
    @ObservationIgnored private var _displayClustersKey: String?
    /// Cached bucketing of `displaySenders` into unsubscribe-mechanism groups. Used by the
    /// Newsletters view when `newslettersOnly == true`. Reuses the same key as
    /// `_displaySendersCache` so it's invalidated together.
    @ObservationIgnored private var _displaySendersGroupedCache: [SenderGroupSection]?
    @ObservationIgnored private var _displaySendersGroupedKey: DisplaySendersKey?

    private struct DisplaySendersKey: Equatable {
        let search: String
        let sortField: SortField
        let sortDirection: SortDirection
    }

    private struct AggregateFingerprint: Equatable {
        var sessionStamps: [SessionStamp]
        var newslettersOnly: Bool
        var isDemoMode: Bool
        var demoVersion: Int
        /// Hash of the per-session reply versions. Bumped when any session's
        /// `repliedMessageIds` changes, which is what drives the cached `ActivityReport` to
        /// rebuild with up-to-date reply counts.
        var repliedVersionHash: Int

        struct SessionStamp: Equatable {
            let id: UUID
            let version: Int
        }
    }

    public struct PendingAction: Hashable {
        public enum Kind: Hashable {
            case delete
            case archive
            case move(destination: String)

            public var label: String {
                switch self {
                case .delete:                  "Deleting"
                case .archive:                 "Archiving"
                case .move(let destination):   "Moving to \(destination)"
                }
            }

            public var verb: String {
                switch self {
                case .delete:  "deleted"
                case .archive: "archived"
                case .move:    "moved"
                }
            }
        }

        public struct PerAccount: Hashable {
            public let accountId: UUID
            public let uids: [UInt32]
            public let sourceMailbox: String
            /// `nil` for `.delete`. For `.archive`, this is the per-account Archive folder name.
            /// For `.move`, every entry holds the same destination (single-account scope only).
            public let destinationMailbox: String?
            public let snapshotHeaders: [MessageHeader]
            /// UIDVALIDITY of `sourceMailbox` at the moment the action was
            /// scheduled. Passed to the IMAP client at commit time so a
            /// server-side UIDVALIDITY change between schedule and commit
            /// refuses the operation instead of acting on stale UIDs.
            /// `nil` only when the mailbox has never been synced.
            public let expectedUIDValidity: UInt64?
        }

        public let kind: Kind
        public let messageIds: Set<String>
        public let perAccount: [PerAccount]
        public let firesAt: Date
        /// Number of messages in the original selection that were transactional and got skipped
        /// by the deletion protection. Surfaced in the undo banner.
        public var protectedFromDeletion: Int = 0
    }

    public init(
        senders: [Sender] = [],
        cache: MessageCache? = nil,
        settings: SettingsStore? = nil,
        categoryStore: SenderCategoryStore? = nil,
        vipStore: VIPStore? = nil,
        repliedStore: RepliedMessagesStore? = nil
    ) {
        self.cache = cache
        self.settings = settings
        self.categoryStore = categoryStore
        self.vipStore = vipStore
        self.repliedStore = repliedStore
        if !senders.isEmpty {
            self.demoHeaders = senders.flatMap(\.messages)
        }
    }

    private func scheduleSearchDebounce() {
        searchDebounceTask?.cancel()
        // Clearing the search field is the one case where the user expects
        // instant feedback — pumping the value through synchronously keeps
        // "tap the X" from feeling laggy.
        if _searchStorage.isEmpty {
            searchDebounceTask = nil
            if effectiveSearch != "" { effectiveSearch = "" }
            return
        }
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.searchDebounceInterval)
            guard !Task.isCancelled, let self else { return }
            let target = self._searchStorage
            if self.effectiveSearch != target {
                self.effectiveSearch = target
            }
        }
    }

    /// Late-binding hook so the app can attach the category store after construction (used by
    /// `File13App` because the store also needs to be `@State`-owned by the scene).
    public func attachCategoryStore(_ store: SenderCategoryStore) {
        self.categoryStore = store
    }

    public func attachVIPStore(_ store: VIPStore) {
        self.vipStore = store
    }

    // MARK: Settings-backed knobs

    public var undoBufferSeconds: Int { settings?.undoBufferSeconds ?? 30 }
    public var isDryRunActive: Bool { settings?.dryRunMode ?? false }
    public var requiresDeleteConfirmation: Bool { settings?.confirmBeforeDelete ?? true }
    public var requiresUnsubscribeConfirmation: Bool { settings?.confirmBeforeUnsubscribe ?? true }
    /// Resolved app URL for the user's preferred `mailto:` handler (e.g. Spark). `nil` means
    /// "use the system default". Surfaced here so unsubscribe-driving views don't need a
    /// direct reference to `SettingsStore`.
    public var preferredMailClientAppURL: URL? { settings?.preferredMailClientAppURL }
    /// Resolved app URL for the user's preferred browser, used to open web unsubscribe pages.
    /// `nil` means "use the system default".
    public var preferredBrowserAppURL: URL? { settings?.preferredBrowserAppURL }
    public var isSoftDeleteActive: Bool { settings?.softDeleteToTrash ?? false }

    /// Whether the user has asked us to protect transactional mail from being deleted. Applies
    /// universally — to both manual and rule-driven deletes, and regardless of whether
    /// soft-delete (move to Trash) is on. The user's intent is "treat receipts as
    /// undeleteable", and that's the same intent in both modes.
    public var shouldProtectTransactionalFromDeletion: Bool {
        settings?.protectTransactionalFromDeletion ?? true
    }

    /// Whether the user has asked us to protect VIP senders from being deleted. Like the
    /// transactional protection, applies to both manual and rule-driven deletes. Archive,
    /// Move, and Unsubscribe outcomes still run on VIPs — only destructive deletion is
    /// blocked.
    public var shouldProtectVIPsFromDeletion: Bool {
        settings?.protectVIPsFromRules ?? true
    }

    // MARK: Demo mode

    /// Loads or replaces the demo headers. Real sessions, if any, are unaffected.
    public func loadDemoData() {
        demoHeaders = MockInbox.generateHeaders()
        _demoVersion &+= 1
    }

    public var isDemoMode: Bool {
        sessions.isEmpty && !demoHeaders.isEmpty
    }

    // MARK: Sessions

    public var connectedAccount: Account? {
        if case .account(let id) = scope, let s = sessions.first(where: { $0.id == id }) {
            return s.account
        }
        if sessions.count == 1, scope == .unified {
            return sessions.first?.account
        }
        return nil
    }

    public var activeSession: AccountSession? {
        if case .account(let id) = scope { return sessions.first { $0.id == id } }
        return nil
    }

    public var activeSessions: [AccountSession] {
        switch scope {
        case .unified:           sessions
        case .account(let id):   sessions.filter { $0.id == id }
        }
    }

    /// Sessions whose headers should be aggregated for display.
    public var displayedSessions: [AccountSession] {
        activeSessions
    }

    public var allHeaders: [MessageHeader] {
        ensureAggregateCache()
        return _allHeadersCache
    }

    public var senders: [Sender] {
        ensureAggregateCache()
        return _sendersCache
    }

    /// Snapshot every cached header (across every connected account and every
    /// mailbox we've ever fetched) into a flat `(headers, senders)` pair.
    /// Used by the whole-inbox rule suggester so the model can reason about
    /// archived patterns and sent-folder data, not just whatever's loaded in
    /// the currently-displayed mailbox.
    ///
    /// This bypasses the aggregate cache (`_sendersCache`) on purpose: that
    /// cache is keyed off `displayedSessions` and respects the user's current
    /// scope/filter selections. The suggester wants the unfiltered superset.
    /// Demo mode falls back to `demoHeaders` so the offline preview path
    /// keeps working.
    ///
    /// One SwiftData fetch per account. Call from off the hot path; results
    /// are not memoized because the corpus grows with every refresh and
    /// invalidating it correctly would mean tracking per-mailbox versions.
    public func wholeInboxCorpus() -> (headers: [MessageHeader], senders: [Sender]) {
        if isDemoMode {
            return (demoHeaders, demoHeaders.groupedBySender())
        }
        guard let cache else {
            let fallback = sessions.flatMap(\.headers)
            return (fallback, fallback.groupedBySender())
        }
        // One SwiftData fetch covering every account vs. one fetch per
        // session. Cuts launch latency roughly proportional to account
        // count on cold caches and is felt every time the rule-suggester
        // sheet is opened.
        let perAccount = cache.loadAllHeadersForAccounts(sessions.map { $0.account.id })
        let headers = sessions.flatMap { perAccount[$0.account.id] ?? [] }
        return (headers, headers.groupedBySender())
    }

    /// Header lookup by message id. O(1) — built lazily as part of the aggregate cache.
    public var headersById: [String: MessageHeader] {
        ensureAggregateCache()
        return _headersByIdCache
    }

    /// Look up a sender by id without scanning the full sender list. Used by the inspector to
    /// render the currently-inspected sender on every state change.
    public func sender(byId id: String) -> Sender? {
        ensureAggregateCache()
        return _sendersByIdCache[id]
    }

    /// Look up a subject cluster by its canonical id. Used by the inspector when the user is
    /// drilling into a cluster from `SubjectListView`.
    public func subjectCluster(byId id: String) -> SubjectCluster? {
        ensureAggregateCache()
        return _subjectClustersByIdCache[id]
    }

    /// Set of message ids whose subject heuristically classified as transactional. Used by
    /// `selectedTransactionalCount` and rule-driven deletion protection without re-scanning
    /// the full inbox on every read.
    public var transactionalIds: Set<String> {
        ensureAggregateCache()
        return _transactionalIdsCache
    }

    /// Compute the input fingerprint and rebuild all derived aggregates if it changed. Reads
    /// `headersVersion` (an `@Observable` Int on each session) so SwiftUI invalidates views
    /// that consumed any cached aggregate when real header changes occur.
    private func ensureAggregateCache() {
        // Combine each session's reply version into a single Int; same value ⇒ no reply
        // changes, so the cache can stay even if the reply set is large.
        var replyHash = 0
        for session in displayedSessions {
            replyHash &+= session.repliedMessageIdsVersion
        }
        let fp = AggregateFingerprint(
            sessionStamps: displayedSessions.map {
                .init(id: $0.id, version: $0.headersVersion)
            },
            newslettersOnly: newslettersOnly,
            isDemoMode: isDemoMode,
            demoVersion: _demoVersion,
            repliedVersionHash: replyHash
        )
        if let cached = _aggregateFP, cached == fp { return }

        // Single-pass rebuild — fuses what used to be six separate passes
        // (`filter`, `groupedBySender`, `clusteredBySubject`, `bucketedByDate`,
        // `transactionalIds`, `headersById`) into one walk plus three small
        // by-id index builds over the finalized collections.
        let raw = isDemoMode ? demoHeaders : displayedSessions.flatMap(\.headers)
        let grouping = raw.groupedForDisplay(newslettersOnly: newslettersOnly)

        _allHeadersCache = grouping.allHeaders
        _headersByIdCache = Dictionary(
            grouping.allHeaders.lazy.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        _sendersCache = grouping.senders
        _sendersByIdCache = Dictionary(
            grouping.senders.lazy.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        _transactionalIdsCache = grouping.transactionalIds
        _subjectClustersCache = grouping.subjectClusters
        _subjectClustersByIdCache = Dictionary(
            grouping.subjectClusters.lazy.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        _dateBucketsCache = grouping.dateBuckets
        // Bump the activity-report input version instead of nilling the
        // cache — we want views to keep painting the previous report
        // while the off-main recompute runs (stale-while-revalidate).
        // The next read of `activityReport` will kick the recompute.
        _activityReportInputVersion &+= 1
        // Bust the search/sort projection caches — they're derived from
        // `_sendersCache` / `_subjectClustersCache`, which we just replaced.
        _displaySendersCache = nil
        _displaySendersKey = nil
        _displaySendersGroupedCache = nil
        _displaySendersGroupedKey = nil
        _displayClustersCache = nil
        _displayClustersKey = nil
        _aggregateFP = fp
    }

    public var mailboxes: [Mailbox] { activeSession?.mailboxes ?? [] }

    public var currentMailbox: String { activeSession?.currentMailbox ?? "INBOX" }
    public var currentMailboxDisplayName: String { activeSession?.currentMailboxDisplayName ?? currentMailbox }

    /// Single-pass connection-state aggregation. ContentView's body
    /// reads this on every observable tick; the prior three-`.contains`
    /// implementation re-walked the session list on each scan. With many
    /// observable inputs (per-session `connectionState`, `fetchProgress`,
    /// `fetchTotal`, etc.) firing during initial sync, that adds up.
    public var connectionState: ConnectionState {
        if isDemoMode { return .connected }
        switch scope {
        case .unified:
            if sessions.isEmpty { return .disconnected }
            var hasFetching = false
            var hasConnecting = false
            var hasConnected = false
            var hasOfflineWithCache = false
            var nonFailed = false
            var firstError: String?
            var firstOfflineMessage: String?
            for session in sessions {
                switch session.connectionState {
                case .fetching:    hasFetching = true;   nonFailed = true
                case .connecting:  hasConnecting = true; nonFailed = true
                case .connected:   hasConnected = true;  nonFailed = true
                case .disconnected: nonFailed = true
                case .offlineWithCache(let m):
                    hasOfflineWithCache = true
                    nonFailed = true
                    if firstOfflineMessage == nil { firstOfflineMessage = m }
                case .failed(let m):
                    if firstError == nil { firstError = m }
                }
            }
            if hasFetching { return .fetching }
            if hasConnecting { return .connecting }
            if !nonFailed, let firstError { return .failed(firstError) }
            if hasConnected { return .connected }
            // No live sessions, but at least one is offline-with-cache —
            // surface that to the inbox-level state so the toolbar /
            // banner can render an "Offline" treatment instead of the
            // green "connected" treatment.
            if hasOfflineWithCache, let firstOfflineMessage {
                return .offlineWithCache(firstOfflineMessage)
            }
            return .disconnected
        case .account(let id):
            return sessions.first { $0.id == id }?.connectionState ?? .disconnected
        }
    }

    /// One-pass aggregated fetch-progress title for the progress banner.
    /// Moved out of ContentView so the work is shared across macOS and
    /// iOS and so a single pass replaces the prior filter + two
    /// reduces. Called from view bodies that re-run on every
    /// observable tick during initial sync — the per-call savings
    /// compound during the most "is the app doing something" moments.
    public var fetchProgressTitle: String {
        var progress = 0
        var total = 0
        var anyActive = false
        for session in displayedSessions where session.fetchTotal > 0 {
            anyActive = true
            progress &+= session.fetchProgress
            total &+= session.fetchTotal
        }
        if !anyActive { return "Fetching messages…" }
        if total > 0 {
            return "Fetching headers — \(progress.formatted()) of \(total.formatted())"
        }
        return "Fetching messages…"
    }

    public var isRefreshing: Bool { displayedSessions.contains { $0.isRefreshing } }

    public var archiveMailboxName: String? {
        // When all displayed sessions agree on a mailbox name, use it. Otherwise nil.
        let names = Set(displayedSessions.compactMap(\.archiveMailboxName))
        return names.count == 1 ? names.first : nil
    }

    public var canArchiveSelection: Bool {
        guard !selectedMessageIds.isEmpty else { return false }
        let lookup = headersById
        var seenAccounts: Set<UUID> = []
        for id in selectedMessageIds {
            guard let header = lookup[id] else { continue }
            if seenAccounts.insert(header.accountId).inserted {
                guard let session = sessions.first(where: { $0.id == header.accountId }) else { return false }
                guard let archive = session.archiveMailboxName else { return false }
                if session.currentMailbox == archive { return false }
            }
        }
        return !seenAccounts.isEmpty
    }

    public var canMoveSelection: Bool {
        // Move-to-folder requires a single-account scope (so destination is unambiguous).
        if case .account = scope { return !selectedMessageIds.isEmpty }
        return false
    }

    // MARK: Connection lifecycle (multi-account)

    public func ensureSession(for account: Account) -> AccountSession {
        if let existing = sessions.first(where: { $0.id == account.id }) { return existing }
        let session = AccountSession(account: account, cache: cache)
        // Restore persisted reply data so reply detection's value carries across launches —
        // a fresh Sent fetch can be slow, and we'd rather show stale-but-useful data
        // immediately than nothing while the user waits for a re-scan.
        if let stored = repliedStore?.replies(forAccountId: account.id), !stored.isEmpty {
            session.restoreRepliedMessageIds(stored)
        }
        sessions.append(session)
        return session
    }

    @discardableResult
    public func connect(account: Account, credentials: AccountCredentials) async -> AccountSession {
        let session = ensureSession(for: account)
        // First real connect kicks demo data out.
        if !demoHeaders.isEmpty {
            demoHeaders = []
            _demoVersion &+= 1
        }
        await session.connect(credentials: credentials)
        // Default scope: if this is the only account, focus on it; otherwise leave existing scope alone.
        if sessions.count == 1 { scope = .account(session.id) }
        // Auth succeeded — kick off the long-running mailbox + header fetch in the background so
        // the caller (e.g. the Add Account sheet) can dismiss immediately. Skip if auth failed.
        switch session.connectionState {
        case .failed(let message):
            // Surface the underlying failure on the main banner. The
            // sidebar's orange "failed" glyph used to be the only signal,
            // which left the user with no idea whether the problem was
            // network, TLS, host, or auth. Prefix with the account name
            // so multi-account users know which one needs attention.
            lastError = "Couldn't connect to \(account.displayName): \(message)"
        case .offlineWithCache(let message):
            // Connect failed but the session already loaded cached
            // headers (`AccountSession.connect` does this before the
            // network attempt). Surface the cause on the banner so the
            // user knows the data they're seeing is stale; the sidebar
            // glyph also renders a distinct "offline" treatment. Don't
            // start initial sync — that would loop on the same failure.
            lastError = "\(account.displayName) is offline: \(message). Showing last-known headers."
        default:
            session.startInitialSync()
        }
        return session
    }

    /// Cancel any in-flight fetches across all sessions. Local state is preserved; partial results stay.
    public func cancelFetches() {
        for session in sessions { session.cancelFetch() }
    }

    public func disconnect(accountId: UUID) async {
        guard let session = sessions.first(where: { $0.id == accountId }) else { return }
        await session.disconnect()
        sessions.removeAll { $0.id == accountId }
        if case .account(let active) = scope, active == accountId {
            scope = sessions.isEmpty ? .unified : .account(sessions[0].id)
        }
    }

    public func disconnectAll() async {
        for session in sessions { await session.disconnect() }
        sessions = []
        scope = .unified
        clearSelection()
        cancelPendingAction()
    }

    public func refresh() async {
        for session in displayedSessions {
            await session.refresh()
        }
        autoCategorizeIfEnabled()
    }

    /// Refresh every connected session, ignoring the current display scope. Used by the
    /// scheduled-refresh timer so headers stay fresh across all accounts (rule automation runs
    /// on the union, not the visible scope).
    public func refreshAll() async {
        for session in sessions where session.connectionState == .connected {
            await session.refresh()
        }
        autoCategorizeIfEnabled()
    }

    /// If the user has opted into auto-categorization and there are uncategorized senders,
    /// kick off a background categorization run. Idempotent — concurrent calls during an
    /// in-flight run are no-ops.
    private func autoCategorizeIfEnabled() {
        guard let settings, settings.autoCategorizeNewSenders else { return }
        guard let categoryStore else { return }
        guard autoCategorizationTask == nil else { return }

        // Snapshot the uncategorized targets *now*; they're the senders that exist after the
        // refresh just completed. We don't want to re-snapshot inside the Task in case more
        // senders arrive while categorization is running — they'll be picked up by the next
        // refresh cycle.
        let uncategorizedIds = Set(categoryStore.uncategorized(amongSenderIds: senders.map(\.id)))
        let targets = senders.filter { uncategorizedIds.contains($0.id) }
        guard !targets.isEmpty else { return }

        let provider = LLMProviderFactory.make(for: .senderCategorize, settings: settings)
        let categorizer = SenderCategorizer(provider: provider, tuning: settings.tuning(for: .senderCategorize))

        autoCategorizationTask = Task { @MainActor [weak self] in
            defer { self?.autoCategorizationTask = nil }
            do {
                let (results, _) = try await categorizer.categorize(targets)
                if !results.isEmpty {
                    self?.categoryStore?.merge(results)
                }
            } catch {
                // Auto-categorize is best-effort — failures here are silent. The user always
                // has the manual button as the explicit-feedback path.
            }
        }
    }

    /// Trigger a Sent-folder fetch on every connected session to rebuild reply data. Manual —
    /// the user clicks "Detect replies" in the activity dashboard. Sent fetches can be slow on
    /// large mailboxes, so we don't run it automatically.
    public func refreshAllSentReplies() async {
        for session in sessions where session.connectionState == .connected {
            await session.refreshSentReplies()
            // Persist the freshly-fetched set per account so the data survives a relaunch.
            // Done per-session rather than batched so a partial run still saves what landed.
            repliedStore?.replace(session.repliedMessageIds, forAccountId: session.id)
        }
    }

    /// Aggregated set of `rawMessageId`s the user has replied to across all *displayed*
    /// sessions. Empty until the user has run reply detection.
    public var repliedMessageIds: Set<String> {
        var combined: Set<String> = []
        for session in displayedSessions {
            combined.formUnion(session.repliedMessageIds)
        }
        return combined
    }

    /// Cancel any running scheduled-refresh task and start a new one for the current
    /// `settings.refreshSchedule`. Idempotent — call from `.task` and on schedule changes.
    public func reconcileScheduledRefresh() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        guard let interval = settings?.refreshSchedule.interval, interval > 0 else { return }
        scheduledRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.refreshAll()
            }
        }
    }

    public func selectMailbox(_ name: String) async {
        guard let session = activeSession else { return }
        if name == session.currentMailbox { return }

        await commitPendingActionImmediately()
        clearSelection()

        await session.selectMailbox(name)
    }

    public func createMailbox(named name: String) async throws {
        guard let session = activeSession else { throw IMAPClientError.notConnected }
        try await session.createMailbox(name)
    }

    public func deleteMailbox(named name: String) async throws {
        guard let session = activeSession else { throw IMAPClientError.notConnected }
        try await session.deleteMailbox(name)
    }

    public func renameMailbox(from source: String, to destination: String) async throws {
        guard let session = activeSession else { throw IMAPClientError.notConnected }
        try await session.renameMailbox(from: source, to: destination)
    }

    /// Permanently delete every message in `mailbox` on the active account.
    /// Wired to the "Empty Trash" sidebar action; the caller is responsible
    /// for the confirmation dialog. Returns the count the server reported
    /// at the moment the action ran, so the UI can show "Removed N
    /// messages." Surfaces any failure through the same `lastError` banner
    /// as other destructive actions.
    @discardableResult
    public func emptyMailbox(named name: String) async -> Int {
        guard let session = activeSession else { return 0 }
        // Force any pending Delete / Archive / Move to land before we wipe
        // the mailbox — otherwise a buffered action could fire after the
        // empty and operate on stale UIDs from the snapshot.
        await commitPendingActionImmediately()
        let removed = await session.emptyMailbox(name)
        surfaceSessionErrors(for: [session.id])
        return removed
    }

    public func forgetCachedMessages(accountId: UUID) {
        try? cache?.purge(accountId: accountId)
        repliedStore?.clear(accountId: accountId)
    }

    /// Clear every cached header + UIDValidity for an account and trigger a fresh full fetch.
    /// Useful when we ship new header fields that incremental sync wouldn't otherwise backfill —
    /// or when the user just wants to rebuild the cache from scratch.
    public func resyncFromScratch(accountId: UUID) async {
        cache?.clearUIDValidities(accountId: accountId)
        try? cache?.purge(accountId: accountId)
        guard let session = sessions.first(where: { $0.id == accountId }) else { return }
        session.replaceHeaders([])
        await session.refresh()
    }

    // MARK: Display

    public var displaySenders: [Sender] {
        ensureAggregateCache()
        // Read the debounced value, not the raw input — typing a 12-char
        // search used to fire 12 filter+sort passes; now only the settled
        // value lands here.
        let activeSearch = effectiveSearch
        let key = DisplaySendersKey(
            search: activeSearch,
            sortField: sortField,
            sortDirection: sortDirection
        )
        if let cached = _displaySendersCache, _displaySendersKey == key {
            return cached
        }
        let base: [Sender]
        if activeSearch.isEmpty {
            base = _sendersCache
        } else {
            let q = activeSearch.lowercased()
            base = _sendersCache.filter {
                $0.name.lowercased().contains(q) || $0.address.lowercased().contains(q)
            }
        }
        let sorted = base.sorted(by: comparator(sortField, sortDirection))
        _displaySendersCache = sorted
        _displaySendersKey = key
        return sorted
    }

    /// `displaySenders` bucketed by `Sender.unsubscribeGroup`, with sections in
    /// `UnsubscribeGroup.allCases` order (One-Click → Website → Email → None). The Newsletters
    /// view (`newslettersOnly == true`) uses this so the user can scan and act on the most-
    /// actionable bucket first. Within each section, senders keep the current sort order from
    /// `displaySenders`. Empty sections are dropped so the table doesn't render placeholder
    /// headers for buckets nobody is in.
    public var displaySendersGrouped: [SenderGroupSection] {
        // Read `displaySenders` first so its cache + invalidation runs; reuse its key so we
        // don't have to track our own debounced search / sort state separately.
        let senders = displaySenders
        let key = DisplaySendersKey(
            search: effectiveSearch,
            sortField: sortField,
            sortDirection: sortDirection
        )
        if let cached = _displaySendersGroupedCache, _displaySendersGroupedKey == key {
            return cached
        }
        var buckets: [UnsubscribeGroup: [Sender]] = [:]
        for sender in senders {
            buckets[sender.unsubscribeGroup, default: []].append(sender)
        }
        var sections: [SenderGroupSection] = []
        for group in UnsubscribeGroup.allCases {
            guard let entries = buckets[group], !entries.isEmpty else { continue }
            sections.append(SenderGroupSection(group: group, senders: entries))
        }
        _displaySendersGroupedCache = sections
        _displaySendersGroupedKey = key
        return sections
    }

    private func comparator(_ field: SortField, _ direction: SortDirection) -> (Sender, Sender) -> Bool {
        let ascending: (Sender, Sender) -> Bool
        switch field {
        case .name:       ascending = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .address:    ascending = { $0.address.localizedCaseInsensitiveCompare($1.address) == .orderedAscending }
        case .count:      ascending = { $0.messageCount < $1.messageCount }
        case .unread:     ascending = { $0.unreadCount < $1.unreadCount }
        case .mostRecent: ascending = { $0.mostRecent < $1.mostRecent }
        }
        return direction == .ascending ? ascending : { ascending($1, $0) }
    }

    public func toggleSort(_ field: SortField) {
        if sortField == field { sortDirection.toggle() }
        else {
            sortField = field
            sortDirection = (field == .count || field == .unread || field == .mostRecent) ? .descending : .ascending
        }
    }

    public func toggleExpansion(_ senderId: String) {
        if expandedSenderIds.contains(senderId) { expandedSenderIds.remove(senderId) }
        else { expandedSenderIds.insert(senderId) }
    }

    public func toggleSubjectExpansion(_ id: String) {
        if expandedSubjectIds.contains(id) { expandedSubjectIds.remove(id) }
        else { expandedSubjectIds.insert(id) }
    }

    public func toggleBucketExpansion(_ kind: DateBucketKind) {
        if expandedBucketIds.contains(kind) { expandedBucketIds.remove(kind) }
        else { expandedBucketIds.insert(kind) }
    }

    public var subjectClusters: [SubjectCluster] {
        ensureAggregateCache()
        let activeSearch = effectiveSearch
        if let cached = _displayClustersCache, _displayClustersKey == activeSearch {
            return cached
        }
        let clusters = _subjectClustersCache
        let filtered: [SubjectCluster]
        if activeSearch.isEmpty {
            filtered = clusters
        } else {
            let q = activeSearch.lowercased()
            filtered = clusters.filter {
                $0.representative.lowercased().contains(q) || $0.id.contains(q)
            }
        }
        let sorted = filtered.sorted { lhs, rhs in
            if lhs.messageCount != rhs.messageCount { return lhs.messageCount > rhs.messageCount }
            return lhs.representative.localizedCaseInsensitiveCompare(rhs.representative) == .orderedAscending
        }
        _displayClustersCache = sorted
        _displayClustersKey = activeSearch
        return sorted
    }

    public var dateBuckets: [DateBucket] {
        ensureAggregateCache()
        return _dateBucketsCache
    }

    /// Dashboard stats over `allHeaders`. Computed off the main actor on
    /// every input change; the **previously-published** report stays
    /// displayed while the recompute runs (stale-while-revalidate). On
    /// a 50k-message unified inbox the compute is multi-tens of ms — we
    /// don't want the list to freeze right after a fetch lands just to
    /// rebuild the dashboard. First-ever read returns `.empty` and the
    /// dashboard fills in when the initial recompute completes.
    public var activityReport: ActivityReport {
        ensureAggregateCache()
        if _activityReportInputVersion != _activityReportPublishedVersion {
            startActivityReportRecompute()
        }
        return _activityReportCache ?? .empty
    }

    /// Snapshot inputs and kick the off-main compute. Cancels any
    /// outstanding recompute that's about to be superseded.
    private func startActivityReportRecompute() {
        // Snapshot inputs synchronously so the detached task sees a
        // consistent set even if more mutations land before it runs.
        let inputVersion = _activityReportInputVersion
        let headers = _allHeadersCache
        let replied = repliedMessageIds
        _activityReportTask?.cancel()
        _activityReportTask = Task.detached(priority: .userInitiated) { [weak self] in
            let report = ActivityReport.compute(
                from: headers,
                repliedMessageIds: replied
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Drop the result on the floor if a newer invalidation
                // arrived while this one was computing — the next read
                // will trigger a fresh task anyway.
                guard inputVersion == self._activityReportInputVersion else { return }
                self._activityReportCache = report
                self._activityReportPublishedVersion = inputVersion
                self._activityReportTask = nil
            }
        }
    }

    // MARK: Selection
    //
    // All row-state checks below are O(M_row) on the row's own message list and use only
    // `selectedMessageIds.contains(_:)` (O(1)) — no full-inbox iteration.

    public func isSenderFullySelected(_ sender: Sender) -> Bool {
        guard !sender.messages.isEmpty else { return false }
        return sender.messages.allSatisfy { selectedMessageIds.contains($0.id) }
    }

    public func isSenderPartiallySelected(_ sender: Sender) -> Bool {
        var anyIn = false
        var anyOut = false
        for m in sender.messages {
            if selectedMessageIds.contains(m.id) { anyIn = true } else { anyOut = true }
            if anyIn && anyOut { return true }
        }
        return false
    }

    public func setSenderSelected(_ sender: Sender, selected: Bool) {
        if selected {
            for m in sender.messages { selectedMessageIds.insert(m.id) }
        } else {
            for m in sender.messages { selectedMessageIds.remove(m.id) }
        }
    }

    public func setMessageSelected(_ message: MessageHeader, in sender: Sender, selected: Bool) {
        // The previous dual-set model needed to "demote" sender-level selection here. With a
        // single materialized set, the row is the single source of truth — just toggle the id.
        _ = sender
        if selected { selectedMessageIds.insert(message.id) }
        else        { selectedMessageIds.remove(message.id) }
    }

    public func isClusterFullySelected(_ cluster: SubjectCluster) -> Bool {
        guard !cluster.messages.isEmpty else { return false }
        return cluster.messages.allSatisfy { selectedMessageIds.contains($0.id) }
    }

    public func isClusterPartiallySelected(_ cluster: SubjectCluster) -> Bool {
        var anyIn = false
        var anyOut = false
        for m in cluster.messages {
            if selectedMessageIds.contains(m.id) { anyIn = true } else { anyOut = true }
            if anyIn && anyOut { return true }
        }
        return false
    }

    public func setClusterSelected(_ cluster: SubjectCluster, selected: Bool) {
        for m in cluster.messages {
            if selected { selectedMessageIds.insert(m.id) }
            else        { selectedMessageIds.remove(m.id) }
        }
    }

    public func isBucketFullySelected(_ bucket: DateBucket) -> Bool {
        guard !bucket.messages.isEmpty else { return false }
        return bucket.messages.allSatisfy { selectedMessageIds.contains($0.id) }
    }

    public func isBucketPartiallySelected(_ bucket: DateBucket) -> Bool {
        var anyIn = false
        var anyOut = false
        for m in bucket.messages {
            if selectedMessageIds.contains(m.id) { anyIn = true } else { anyOut = true }
            if anyIn && anyOut { return true }
        }
        return false
    }

    public func setBucketSelected(_ bucket: DateBucket, selected: Bool) {
        for m in bucket.messages {
            if selected { selectedMessageIds.insert(m.id) }
            else        { selectedMessageIds.remove(m.id) }
        }
    }

    /// Replace the selection with exactly this cluster's messages. Used by
    /// the cluster row's context menu so "Delete this group" / "Archive this
    /// group" act on what the user right-clicked, not on whatever was already
    /// in the selection set.
    public func replaceSelection(withCluster cluster: SubjectCluster) {
        selectedMessageIds = Set(cluster.messages.map(\.id))
    }

    /// Replace the selection with exactly this bucket's messages. Mirrors
    /// `replaceSelection(withCluster:)` for the date view.
    public func replaceSelection(withBucket bucket: DateBucket) {
        selectedMessageIds = Set(bucket.messages.map(\.id))
    }

    public var selectedMessageCount: Int { selectedMessageIds.count }
    public var hasSelection: Bool { !selectedMessageIds.isEmpty }

    public func clearSelection() {
        selectedMessageIds.removeAll()
    }

    /// Select every row visible in the active view, respecting the current search filter.
    public func selectAllVisible() {
        switch displayMode {
        case .sender:
            for sender in displaySenders {
                for message in sender.messages { selectedMessageIds.insert(message.id) }
            }
        case .subject:
            for cluster in subjectClusters {
                for message in cluster.messages {
                    selectedMessageIds.insert(message.id)
                }
            }
        case .date:
            for bucket in dateBuckets {
                for message in bucket.messages {
                    selectedMessageIds.insert(message.id)
                }
            }
        }
    }

    /// How many of the currently selected messages would be skipped by transactional protection
    /// if a Delete were issued right now. O(selection.count) via the cached transactional set.
    public var selectedTransactionalCount: Int {
        guard shouldProtectTransactionalFromDeletion else { return 0 }
        let txn = transactionalIds
        return selectedMessageIds.reduce(into: 0) { count, id in
            if txn.contains(id) { count += 1 }
        }
    }

    // MARK: Unsubscribe

    public struct UnsubscribeCandidate: Identifiable, Hashable {
        public let sender: Sender
        public let anchor: MessageHeader
        public let mechanisms: [UnsubscribeMechanism]
        public var id: String { sender.id }
        public var primary: UnsubscribeMechanism? { mechanisms.first }

        public init(sender: Sender, anchor: MessageHeader, mechanisms: [UnsubscribeMechanism]) {
            self.sender = sender
            self.anchor = anchor
            self.mechanisms = mechanisms
        }
    }

    /// Whether at least one selected message carries a List-Unsubscribe header. Kept O(1) per
    /// selected id by reading from the cached header index — BulkActionBar's render no longer
    /// re-iterates the entire inbox just to evaluate this.
    public var canUnsubscribeSelection: Bool {
        guard hasSelection else { return false }
        let lookup = headersById
        for id in selectedMessageIds {
            if let header = lookup[id], header.listUnsubscribe != nil { return true }
        }
        return false
    }

    /// Apply a one-time action to every message from a sender, without disturbing whatever the
    /// user already had selected. Used by the AI triage sheet to make decisions stick.
    public func applyAction(_ kind: PendingAction.Kind, toSender sender: Sender) {
        let savedMessageIds = selectedMessageIds
        selectedMessageIds = Set(sender.messages.map(\.id))
        switch kind {
        case .delete:                       startDelete()
        case .archive:                      archiveSelection()
        case .move(let destination):        moveSelection(to: destination)
        }
        // The action methods clear selection internally; restore the user's selection so they
        // don't get yanked out of whatever they were looking at.
        selectedMessageIds = savedMessageIds
    }

    /// Top senders in the active scope by message count, useful for AI triage.
    public func topSendersByVolume(limit: Int) -> [Sender] {
        senders.sorted { $0.messageCount > $1.messageCount }.prefix(limit).map { $0 }
    }

    /// Senders implicated by the user's current selection. Pure
    /// O(selection.count) via two O(1) dictionary lookups — the prior
    /// implementation walked all senders to filter, which on a 5k-sender
    /// inbox meant 5000 hash lookups per render. ContentView's toolbar
    /// reads this from three sites in the same body so the savings
    /// compound per render cycle.
    public var sendersInSelection: [Sender] {
        guard hasSelection else { return [] }
        ensureAggregateCache()
        let byHeaderId = _headersByIdCache
        let bySenderId = _sendersByIdCache
        var senderIds: [String] = []
        var seen: Set<String> = []
        senderIds.reserveCapacity(min(selectedMessageIds.count, 64))
        for messageId in selectedMessageIds {
            guard let header = byHeaderId[messageId] else { continue }
            let key = header.senderAddress.lowercased()
            if seen.insert(key).inserted {
                senderIds.append(key)
            }
        }
        return senderIds.compactMap { bySenderId[$0] }
    }

    /// Build one unsubscribe candidate per selected sender. The anchor is the sender's most
    /// recent message that carries a List-Unsubscribe header. Senders without any unsubscribe
    /// path are dropped — they're surfaced as "manual review needed" elsewhere if desired.
    public func unsubscribeCandidatesForSelection() -> [UnsubscribeCandidate] {
        guard hasSelection else { return [] }
        ensureAggregateCache()
        let byHeaderId = _headersByIdCache
        let bySenderId = _sendersByIdCache
        var senderIds = Set<String>()
        for id in selectedMessageIds {
            if let header = byHeaderId[id] {
                senderIds.insert(header.senderAddress.lowercased())
            }
        }
        guard !senderIds.isEmpty else { return [] }
        // Resolve each selected sender by direct id lookup instead of
        // scanning every sender (mirrors `sendersInSelection`). The final
        // sort below makes iteration order irrelevant.
        var candidates: [UnsubscribeCandidate] = []
        for senderId in senderIds {
            guard let sender = bySenderId[senderId],
                  let anchor = sender.unsubscribeAnchor else { continue }
            let mechanisms = UnsubscribeParser.parse(
                listUnsubscribe: anchor.listUnsubscribe,
                listUnsubscribePost: anchor.listUnsubscribePost
            )
            guard !mechanisms.isEmpty else { continue }
            candidates.append(UnsubscribeCandidate(sender: sender, anchor: anchor, mechanisms: mechanisms))
        }
        return candidates.sorted { lhs, rhs in
            lhs.sender.name.localizedCaseInsensitiveCompare(rhs.sender.name) == .orderedAscending
        }
    }

    // MARK: Buffered actions (Delete / Archive / Move-to-Folder)
    //
    // All three follow the same pattern: optimistically mutate the local view, schedule a
    // commit task to fire after the configured undo buffer, and let the user cancel via Undo.
    // Switching mailboxes / starting a new action force-commits the pending one first.

    public func startDelete() {
        guard !selectedMessageIds.isEmpty else { return }
        // destinationFor is non-escaping — no capture list needed.
        scheduleAction(kind: .delete, messageIds: selectedMessageIds) { accountId in
            guard self.isSoftDeleteActive else { return nil }
            return self.sessions.first { $0.id == accountId }?.trashMailboxName
        }
    }

    public func archiveSelection() {
        guard !selectedMessageIds.isEmpty else { return }
        scheduleAction(kind: .archive, messageIds: selectedMessageIds) { accountId in
            self.sessions.first { $0.id == accountId }?.archiveMailboxName
        }
    }

    public func moveSelection(to mailbox: String) {
        guard case .account = scope else { return }
        guard !selectedMessageIds.isEmpty else { return }
        scheduleAction(kind: .move(destination: mailbox), messageIds: selectedMessageIds, destinationFor: { _ in mailbox })
    }

    public func undoPendingAction() {
        guard let p = pendingAction else { return }
        for entry in p.perAccount {
            guard let session = sessions.first(where: { $0.id == entry.accountId }) else { continue }
            session.replaceHeaders(entry.snapshotHeaders)
            // Mirror-reverse the optimistic count adjustment from scheduleAction
            // so the sidebar chip snaps back to its pre-action value.
            let n = entry.uids.count
            session.adjustMessageCount(for: entry.sourceMailbox, by: n)
            if let destination = entry.destinationMailbox {
                session.adjustMessageCount(for: destination, by: -n)
            }
        }
        actionTask?.cancel()
        actionTask = nil
        pendingAction = nil
    }

    /// Drop the pending action without committing it. Used during disconnect / shutdown.
    public func cancelPendingAction() {
        actionTask?.cancel()
        actionTask = nil
        pendingAction = nil
    }

    /// Force the pending action to commit to the server now. Awaits the in-flight server work so
    /// callers that need to know it's complete can.
    public func commitPendingActionImmediately() async {
        guard let pending = pendingAction else { return }
        actionTask?.cancel()
        actionTask = nil
        pendingAction = nil
        await commit(pending, dryRun: isDryRunActive)
    }

    private func scheduleAction(
        kind: PendingAction.Kind,
        messageIds: Set<String>,
        destinationFor: (UUID) -> String?
    ) {
        // Take ownership of any prior pending action *synchronously* before setting up the new
        // one. Committing it via Task fires after the new pendingAction is in place, but the
        // captured value is the OLD action — so the timer for the new one still has its full
        // 30s window.
        let prior = pendingAction
        actionTask?.cancel()
        actionTask = nil
        pendingAction = nil
        if let prior {
            let dryRun = isDryRunActive
            Task { await self.commit(prior, dryRun: dryRun) }
        }

        let lookup = headersById
        let originalMessages = messageIds.compactMap { lookup[$0] }

        // Delete protections: when the action is .delete, drop any message that looks
        // transactional and/or comes from a VIP sender, per the user's settings. Protected
        // rows stay visible in the local view (we never optimistically remove them) and
        // never make it to the server commit. Archive and Move-to-Folder bypass this branch
        // entirely.
        let isDelete = (kind == .delete)
        let protectTransactional = isDelete && shouldProtectTransactionalFromDeletion
        let vipSet: Set<String> = isDelete && shouldProtectVIPsFromDeletion ? (vipStore?.effective ?? []) : []
        let protectVIPs = !vipSet.isEmpty
        let messages: [MessageHeader]
        let actualMessageIds: Set<String>
        let protectedCount: Int
        if protectTransactional || protectVIPs {
            let kept = originalMessages.filter { header in
                if protectTransactional, header.isLikelyTransactional { return false }
                if protectVIPs, vipSet.contains(header.senderAddress.lowercased()) { return false }
                return true
            }
            protectedCount = originalMessages.count - kept.count
            messages = kept
            actualMessageIds = Set(kept.map(\.id))
        } else {
            messages = originalMessages
            actualMessageIds = messageIds
            protectedCount = 0
        }

        let byAccount = Dictionary(grouping: messages, by: \.accountId)
        var entries: [PendingAction.PerAccount] = []

        for (accountId, msgs) in byAccount {
            guard let session = sessions.first(where: { $0.id == accountId }) else { continue }
            let needsDestination = !(kind == .delete)
            let destination = destinationFor(accountId)
            if needsDestination, destination == nil { continue }
            let source = session.currentMailbox
            entries.append(.init(
                accountId: accountId,
                uids: msgs.compactMap(\.uid),
                sourceMailbox: source,
                destinationMailbox: destination,
                snapshotHeaders: session.headers,
                expectedUIDValidity: session.uidValidity(for: source)
            ))
            session.removeMessages(matching: Set(msgs.map(\.id)))
            // Keep the sidebar chip in sync with the optimistic header removal.
            // The authoritative number is reconciled by the post-commit
            // refreshMailboxStatuses() call; this just prevents the chip from
            // lying during the undo-buffer window.
            let n = msgs.count
            session.adjustMessageCount(for: source, by: -n)
            if let destination {
                session.adjustMessageCount(for: destination, by: n)
            }
        }
        clearSelection()

        // If protection swallowed every selected message, surface a no-op pending action so the
        // user sees a banner saying "N protected" without an actual delete countdown.
        if entries.isEmpty {
            if protectedCount > 0 {
                lastError = "\(protectedCount.formatted()) message\(protectedCount == 1 ? "" : "s") protected from deletion."
            }
            return
        }

        let seconds = undoBufferSeconds
        let dryRun = isDryRunActive

        // 0 = no undo: commit on the next runloop turn without ever
        // setting `pendingAction`, so the undo banner doesn't flash for a
        // single frame. Still hops through a Task so the optimistic UI
        // mutations from this call get a chance to render first — calling
        // `commit` synchronously would block until every server commit
        // finished.
        guard seconds > 0 else {
            let immediate = PendingAction(
                kind: kind,
                messageIds: actualMessageIds,
                perAccount: entries,
                firesAt: Date(),
                protectedFromDeletion: protectedCount
            )
            actionTask = Task { [weak self] in
                guard let self else { return }
                self.actionTask = nil
                await self.commit(immediate, dryRun: dryRun)
            }
            return
        }

        let firesAt = Date().addingTimeInterval(TimeInterval(seconds))
        pendingAction = PendingAction(
            kind: kind,
            messageIds: actualMessageIds,
            perAccount: entries,
            firesAt: firesAt,
            protectedFromDeletion: protectedCount
        )

        actionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            guard let pending = self.pendingAction else { return }
            self.pendingAction = nil
            self.actionTask = nil
            await self.commit(pending, dryRun: dryRun)
        }
    }

    private func commit(_ action: PendingAction, dryRun: Bool) async {
        for entry in action.perAccount {
            guard let session = sessions.first(where: { $0.id == entry.accountId }) else { continue }
            switch action.kind {
            case .delete:
                // Soft-delete mode populates `destinationMailbox` with the session's Trash folder
                // at schedule time, so the same .delete kind transparently routes through MOVE.
                if let destination = entry.destinationMailbox {
                    await session.moveMessages(
                        uids: entry.uids,
                        from: entry.sourceMailbox,
                        to: destination,
                        isDryRun: dryRun,
                        expectedUIDValidity: entry.expectedUIDValidity
                    )
                } else {
                    await session.deleteMessages(
                        uids: entry.uids,
                        in: entry.sourceMailbox,
                        isDryRun: dryRun,
                        expectedUIDValidity: entry.expectedUIDValidity
                    )
                }
            case .archive, .move:
                guard let destination = entry.destinationMailbox else { continue }
                await session.moveMessages(
                    uids: entry.uids,
                    from: entry.sourceMailbox,
                    to: destination,
                    isDryRun: dryRun,
                    expectedUIDValidity: entry.expectedUIDValidity
                )
            }
        }
        // Reconcile the sidebar chips with the server's authoritative counts.
        // The optimistic adjust in scheduleAction kept them roughly right
        // during the undo window; STATUS here corrects for races (cross-
        // device moves, server-side filters), Gmail's "EXPUNGE just unlabels"
        // semantics for non-Trash sources, and any commit failures that
        // didn't actually move the messages.
        let accountIds = Set(action.perAccount.map(\.accountId))
        for accountId in accountIds {
            guard let session = sessions.first(where: { $0.id == accountId }) else { continue }
            await session.refreshMailboxStatuses()
        }
        surfaceSessionErrors(for: accountIds)
    }

    /// Promote per-session error strings into `lastError` so the inline
    /// banner can show them. Sessions set `lastError` on delete/move/refresh
    /// failures, but there's no view that observes a session's error
    /// directly — without this hop, the user clicks Delete, watches the
    /// sidebar revert, and has no signal that the IMAP commit failed.
    /// Picks the first error it finds; multi-account scenarios are rare and
    /// the inline banner only renders one message at a time anyway.
    private func surfaceSessionErrors(for accountIds: Set<UUID>) {
        for accountId in accountIds {
            guard let session = sessions.first(where: { $0.id == accountId }),
                  let error = session.lastError, !error.isEmpty
            else { continue }
            let prefix = sessions.count > 1 ? "\(session.account.displayName.isEmpty ? session.account.address : session.account.displayName): " : ""
            lastError = prefix + error
            session.lastError = nil
            return
        }
    }

    // MARK: Rules

    public func draftRuleFromSelection() -> Rule {
        let lookup = headersById
        let messages = selectedMessageIds.compactMap { lookup[$0] }

        var conditions = Rule.Conditions()
        let addresses = Set(messages.map { $0.senderAddress.lowercased() }).filter { !$0.isEmpty }
        // Pre-fill "From" so a user who selected N senders before opening
        // the rule sheet gets those addresses already populated — they
        // shouldn't have to re-type. Three shapes:
        //   1 address  → just the address
        //   N addresses, single shared domain → the bare domain (matches
        //     every address under it without enumerating them)
        //   N addresses, multiple domains → comma-separated address list,
        //     which the matcher treats as OR-over-needles
        if let only = addresses.first, addresses.count == 1 {
            conditions.fromAddressOrDomain = only
        } else if addresses.count > 1 {
            let domains = Set(addresses.compactMap { addr -> String? in
                guard let at = addr.firstIndex(of: "@") else { return nil }
                return String(addr[addr.index(after: at)...])
            })
            if domains.count == 1, let domain = domains.first, !domain.isEmpty {
                conditions.fromAddressOrDomain = domain
            } else {
                conditions.fromAddressOrDomain = addresses.sorted().joined(separator: ", ")
            }
        }
        let canonicalSubjects = Set(messages.map { SubjectNormalizer.canonical($0.subject) })
        if canonicalSubjects.count == 1, let only = canonicalSubjects.first, !only.isEmpty {
            conditions.subjectContains = only
        }
        return Rule(conditions: conditions, outcome: .delete)
    }

    public func runRules(_ rules: [Rule]) async -> RuleRunReport {
        let connectedSessions = sessions.filter { $0.connectionState == .connected }
        guard !connectedSessions.isEmpty else {
            return RuleRunReport(actions: [], skipReason: "Not connected to a mail server.")
        }
        // Coalesce headersVersion bumps across all the per-rule
        // `removeFromCache` calls. Without this, a rule run that matches
        // multiple mailboxes across multiple sessions fires N aggregate-
        // cache rebuilds in tight succession; one bump at end is enough
        // for the UI to settle on the final state.
        for session in connectedSessions { session.beginStreamingHeaders() }
        defer { for session in connectedSessions { session.endStreamingHeaders() } }

        let protectFromDeletion = shouldProtectTransactionalFromDeletion
        // Snapshot the category and VIP sets once so per-message lookups don't bounce through
        // the observable stores inside a tight filter loop.
        let categoryMap: [String: SenderCategory] = categoryStore?.categories ?? [:]
        let categoryFor: (String) -> SenderCategory? = { categoryMap[$0] }
        let vipSet: Set<String> = vipStore?.effective ?? []
        let protectVIPs = (settings?.protectVIPsFromRules ?? true) && !vipSet.isEmpty
        var report: [RuleRunReport.Action] = []
        var protectedCount = 0

        for rule in rules where rule.enabled && !rule.conditions.isEmpty && rule.outcome.isSupported {
            var totalMatched = 0
            // Only `.delete` outcomes are gated by the protections — Archive, Move, and
            // Unsubscribe are reversible (or non-destructive), so receipts and VIP senders
            // are not exempt from them.
            let isDeleteRule: Bool = {
                if case .delete = rule.outcome { return true }
                return false
            }()
            let applyTransactionalProtection = protectFromDeletion && isDeleteRule
            let applyVIPProtection = protectVIPs && isDeleteRule
            for session in connectedSessions {
                let mailboxesForRule = mailboxesToScan(for: rule, in: session)
                for sourceMailbox in mailboxesForRule {
                    let pool = session.headers(in: sourceMailbox)
                    let matched = pool.filter { header in
                        if applyVIPProtection, vipSet.contains(header.senderAddress.lowercased()) { return false }
                        return RuleEvaluator.matches(header, rule: rule, categoryFor: categoryFor)
                    }
                    let matches: [MessageHeader]
                    if applyTransactionalProtection {
                        var kept: [MessageHeader] = []
                        kept.reserveCapacity(matched.count)
                        for header in matched {
                            if header.isLikelyTransactional {
                                protectedCount += 1
                            } else {
                                kept.append(header)
                            }
                        }
                        matches = kept
                    } else {
                        matches = matched
                    }
                    guard !matches.isEmpty else { continue }
                    let ids = Set(matches.map(\.id))
                    let uids = matches.compactMap(\.uid)

                    // Capture UIDVALIDITY for this mailbox right now, alongside
                    // the UIDs we just collected. If the server has rotated
                    // it since the local headers were last synced, the IMAP
                    // client will refuse the mutation rather than acting on
                    // recycled UIDs.
                    let expected = session.uidValidity(for: sourceMailbox)

                    let n = matches.count
                    switch rule.outcome {
                    case .delete:
                        session.removeFromCache(matching: ids, in: sourceMailbox)
                        session.adjustMessageCount(for: sourceMailbox, by: -n)
                        await session.deleteMessages(
                            uids: uids,
                            in: sourceMailbox,
                            isDryRun: isDryRunActive,
                            expectedUIDValidity: expected
                        )
                    case .archive:
                        guard let archive = session.archiveMailboxName,
                              archive != sourceMailbox else { continue }
                        session.removeFromCache(matching: ids, in: sourceMailbox)
                        session.adjustMessageCount(for: sourceMailbox, by: -n)
                        session.adjustMessageCount(for: archive, by: n)
                        await session.moveMessages(
                            uids: uids,
                            from: sourceMailbox,
                            to: archive,
                            isDryRun: isDryRunActive,
                            expectedUIDValidity: expected
                        )
                    case .moveToFolder(let dest):
                        guard dest != sourceMailbox else { continue }
                        session.removeFromCache(matching: ids, in: sourceMailbox)
                        session.adjustMessageCount(for: sourceMailbox, by: -n)
                        session.adjustMessageCount(for: dest, by: n)
                        await session.moveMessages(
                            uids: uids,
                            from: sourceMailbox,
                            to: dest,
                            isDryRun: isDryRunActive,
                            expectedUIDValidity: expected
                        )
                    case .unsubscribe:
                        continue
                    }
                    totalMatched += n
                }
            }
            if totalMatched > 0 {
                report.append(.init(
                    id: rule.id,
                    ruleName: rule.name.isEmpty ? "Untitled rule" : rule.name,
                    count: totalMatched,
                    outcomeLabel: rule.outcome.label
                ))
            }
        }
        // Same rationale as commit(): the per-rule loop adjusted counts
        // optimistically; STATUS here reconciles with the server in case
        // anything raced or got rejected.
        for session in connectedSessions {
            await session.refreshMailboxStatuses()
        }
        surfaceSessionErrors(for: Set(connectedSessions.map(\.id)))
        return RuleRunReport(actions: report, skipReason: nil, protectedFromRules: protectedCount)
    }

    /// Resolve a rule's `RuleScope` against this session's mailboxes. Returns
    /// the list of mailbox names the rule should iterate over for that
    /// account. Empty result means "skip this account for this rule" (e.g.
    /// the `folder(name)` scope refers to a mailbox the account doesn't
    /// have).
    private func mailboxesToScan(for rule: Rule, in session: AccountSession) -> [String] {
        switch rule.effectiveScope {
        case .currentMailbox:
            return [session.currentMailbox]
        case .folder(let name):
            return session.mailboxes.contains(where: { $0.name == name }) ? [name] : []
        case .allFolders:
            // Skip nothing-cached mailboxes (mostly system-only views the user
            // hasn't opened): `headers(in:)` returns [] for those, so the
            // filter short-circuits anyway.
            return session.mailboxes.map(\.name)
        }
    }
}

