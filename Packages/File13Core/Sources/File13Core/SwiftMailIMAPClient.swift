import Foundation
import SwiftMail

public actor SwiftMailIMAPClient: IMAPClientProtocol {
    public init() {}

    private var server: SwiftMail.IMAPServer?
    private var selectedMailbox: String?

    public func connect(_ credentials: AccountCredentials) async throws {
        await disconnect()
        let s = SwiftMail.IMAPServer(host: credentials.host, port: credentials.port, useTLS: credentials.useTLS)
        do {
            try await s.connect()
        } catch {
            throw IMAPClientError.underlying(error)
        }
        do {
            // The secret is carried as `Data` through `AccountCredentials`
            // so it can be zeroed when we're done. `withSecretString`
            // materializes a Swift `String` only for the duration of the
            // SwiftMail login / XOAUTH2 call — once the closure returns,
            // our reference to the String is gone and the bytes can be
            // released by ARC. (Swift can't zero String storage; the
            // window is still short.)
            switch credentials.auth {
            case .password:
                let ok: Bool = try await credentials.withSecretString { pw in
                    try await s.login(username: credentials.username, password: pw)
                    return true
                } ?? false
                if !ok { throw IMAPClientError.authFailed("Password isn't valid UTF-8.") }
            case .oauth2:
                // XOAUTH2 binds the token to the user identity (RFC 4954 §3).
                // Gmail and Microsoft both validate that the token was issued
                // for this email — sending the wrong user surfaces as an
                // auth failure here, not a fetch failure later.
                let ok: Bool = try await credentials.withSecretString { token in
                    try await s.authenticateXOAUTH2(email: credentials.username, accessToken: token)
                    return true
                } ?? false
                if !ok { throw IMAPClientError.authFailed("Access token isn't valid UTF-8.") }
            }
        } catch {
            try? await s.disconnect()
            throw IMAPClientError.authFailed(String(describing: error))
        }
        server = s
        selectedMailbox = nil
    }

    public func disconnect() async {
        guard let s = server else { return }
        try? await s.logout()
        try? await s.disconnect()
        server = nil
        selectedMailbox = nil
    }

    public func fetchHeaders(accountId: UUID, mailbox: String) async throws -> HeadersFetch {
        guard let s = server else { throw IMAPClientError.notConnected }
        try Self.validateMailboxName(mailbox)
        let selection: SwiftMail.Mailbox.Selection
        do {
            selection = try await s.selectMailbox(mailbox)
        } catch {
            throw IMAPClientError.fetchFailed(String(describing: error))
        }
        selectedMailbox = mailbox
        let total = selection.messageCount
        guard total > 0 else {
            return HeadersFetch(totalCount: 0, stream: AsyncThrowingStream { $0.finish() })
        }

        // Use the slim fetch (UID + ENVELOPE + INTERNALDATE + FLAGS) so we drop BODYSTRUCTURE and
        // BODY[HEADER] from the response — roughly 25× less data per message. Allows much larger
        // chunks while staying inside SwiftMail's per-command 10-second timeout.
        let seqSet = SwiftMail.SequenceNumberSet(1...total)
        let infoStream = s.fetchSlimMessageInfos(using: seqSet)

        let stream = AsyncThrowingStream<MessageHeader, Error> { continuation in
            let task = Task {
                do {
                    for try await info in infoStream {
                        if let header = makeMessageHeader(from: info, accountId: accountId) {
                            continuation.yield(header)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }

        return HeadersFetch(totalCount: total, stream: stream)
    }

    public func fetchHeaders(uids: Set<UInt32>, accountId: UUID, mailbox: String) async throws -> HeadersFetch {
        guard let s = server else { throw IMAPClientError.notConnected }
        try Self.validateMailboxName(mailbox)
        do {
            _ = try await s.selectMailbox(mailbox)
        } catch {
            throw IMAPClientError.fetchFailed(String(describing: error))
        }
        selectedMailbox = mailbox
        guard !uids.isEmpty else {
            return HeadersFetch(totalCount: 0, stream: AsyncThrowingStream { $0.finish() })
        }

        var uidSet = SwiftMail.UIDSet()
        for u in uids { uidSet.insert(SwiftMail.UID(u)) }
        let infoStream = s.fetchSlimMessageInfos(using: uidSet)

        let stream = AsyncThrowingStream<MessageHeader, Error> { continuation in
            let task = Task {
                do {
                    for try await info in infoStream {
                        if let header = makeMessageHeader(from: info, accountId: accountId) {
                            continuation.yield(header)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
        return HeadersFetch(totalCount: uids.count, stream: stream)
    }

    public func fetchUIDFlags(accountId: UUID, mailbox: String) async throws -> UIDFlagsSnapshot {
        guard let s = server else { throw IMAPClientError.notConnected }
        try Self.validateMailboxName(mailbox)
        let selection: SwiftMail.Mailbox.Selection
        do {
            selection = try await s.selectMailbox(mailbox)
        } catch {
            throw IMAPClientError.fetchFailed(String(describing: error))
        }
        selectedMailbox = mailbox
        let uidValidity = UInt64(selection.uidValidity.value)
        let total = selection.messageCount
        guard total > 0 else {
            return UIDFlagsSnapshot(uidValidity: uidValidity, messageCount: 0, entries: [])
        }

        // Stream the UID+FLAGS rows in chunks instead of one giant FETCH.
        // The bulk variant sends `FETCH 1:<total> (UID FLAGS)` as a single
        // tagged command. On Gmail mailboxes with ~80k+ messages that
        // response can exceed SwiftMail's per-command 10s timeout and the
        // whole refresh fails with "Operation timed out" — even though
        // every individual chunk would have come back in milliseconds. The
        // streaming variant chunks at `uidFlagsFetchChunkSize` internally
        // (5000) and yields each chunk as it arrives, so the timer resets
        // per round-trip. Accumulating the stream's output here preserves
        // the existing callers' contract.
        let seqSet = SwiftMail.SequenceNumberSet(1...total)
        var entries: [UIDFlagsSnapshot.Entry] = []
        entries.reserveCapacity(Int(total))
        do {
            for try await info in s.fetchUIDFlags(using: seqSet) {
                guard let uid = info.uid else { continue }
                entries.append(.init(uid: uid.value, isRead: info.flags.contains(.seen)))
            }
        } catch {
            throw IMAPClientError.fetchFailed(String(describing: error))
        }
        return UIDFlagsSnapshot(uidValidity: uidValidity, messageCount: total, entries: entries)
    }

    /// Per-IMAP-command UID batch size for destructive ops. 500 keeps each
    /// command finishing well inside the 30s per-command timeout even on
    /// Gmail-scale mailboxes. Picked empirically: 5k+ UIDs in a single MOVE
    /// against Gmail can take >30s and is then unrecoverable (the orphaned
    /// tag corrupts the next reconnect's command stream). 500 is a comfortable
    /// 1-3s per chunk and lets 10k-message bulk deletes complete in ~30-60s
    /// total instead of failing.
    private static let destructiveBatchSize = 500

    /// Wrap a transient-prone IMAP command in an exponential-backoff
    /// retry. Gmail (and to a lesser extent other big providers) randomly
    /// returns `Command failed: no(System Error (Failure))` mid-burst when
    /// it's overloaded or rate-limiting — same UIDs, identical request,
    /// works on retry a second later. Without this, a single hiccup mid-
    /// bulk-move surfaces as a hard "Couldn't move on server" banner and
    /// leaves the user with partial progress.
    ///
    /// Only retries the failure modes that are known transient: command
    /// timeouts and "System Error" / "TRYAGAIN" / "OVERQUOTA" `no` responses.
    /// Anything else (auth, UIDVALIDITY, NONEXISTENT folder, …) is a real
    /// error that retrying would just hide.
    ///
    /// 3 attempts with 0.5s / 1s waits is enough for Gmail's transient
    /// dips and short enough that the user isn't watching a frozen UI for
    /// long if the failure is actually persistent.
    private func retryTransient<T>(_ body: () async throws -> T) async throws -> T {
        let backoffs: [UInt64] = [500_000_000, 1_000_000_000]  // nanoseconds: 0.5s, 1s
        var lastError: Error?
        for attempt in 0...backoffs.count {
            do {
                return try await body()
            } catch let error where Self.isTransient(error) {
                lastError = error
                if attempt < backoffs.count {
                    try? await Task.sleep(nanoseconds: backoffs[attempt])
                    continue
                }
            }
        }
        throw lastError ?? IMAPClientError.fetchFailed("retry exhausted")
    }

    /// Classify an error as transient (worth retrying) vs. permanent.
    /// Conservative: we only retry on signals that match published or
    /// frequently-observed transient responses across the major IMAP
    /// providers we ship support for. False negatives are fine — they
    /// just propagate the way the original error would have anyway.
    ///
    /// Provider notes for the substrings below:
    /// - Gmail: emits `Command failed: no(System Error (Failure))` mid-
    ///   burst when overloaded or rate-limiting.
    /// - Yahoo / AOL: `OVERQUOTA`, `LIMIT`, `INUSE` response codes — all
    ///   recoverable on retry.
    /// - Outlook (Microsoft 365): `temporary failure`, `server error`,
    ///   `internal error` for transient backend hiccups.
    /// - Generic Cyrus / Dovecot: `TRYAGAIN`, `[INUSE]`.
    private static func isTransient(_ error: Error) -> Bool {
        if let imap = error as? SwiftMail.IMAPError {
            switch imap {
            case .timeout:
                return true
            case .commandFailed(let reason),
                 .moveFailed(let reason),
                 .copyFailed(let reason),
                 .storeFailed(let reason),
                 .expungeFailed(let reason),
                 .fetchFailed(let reason):
                let lower = reason.lowercased()
                return lower.contains("system error")
                    || lower.contains("tryagain")
                    || lower.contains("try again")
                    || lower.contains("temporary")
                    || lower.contains("overquota")
                    || lower.contains("internal error")
                    || lower.contains("[limit]")
                    || lower.contains("[inuse]")
                    || lower.contains("server unavailable")
                    || lower.contains("server busy")
            default:
                return false
            }
        }
        return false
    }

    public func deleteMessages(uids: [UInt32], in mailbox: String, expectedUIDValidity: UInt64?) async throws {
        guard let s = server else { throw IMAPClientError.notConnected }
        try Self.validateMailboxName(mailbox)
        try await selectAndVerifyValidity(mailbox: mailbox, expected: expectedUIDValidity)
        guard !uids.isEmpty else { return }
        // STORE in chunks first, EXPUNGE once at the end. STORE is the
        // expensive step on a large set; EXPUNGE just sweeps the
        // already-flagged messages and isn't bounded by the input list.
        do {
            for chunk in Self.batches(of: uids, size: Self.destructiveBatchSize) {
                let set = uidSet(from: chunk)
                guard !set.isEmpty else { continue }
                try await retryTransient {
                    try await s.store(flags: [.deleted], on: set, operation: .add)
                }
            }
            try await retryTransient { try await s.expunge(messages: uidSet(from: uids)) }
        } catch {
            throw IMAPClientError.underlying(error)
        }
    }

    public func moveMessages(uids: [UInt32], from source: String, to destination: String, expectedUIDValidity: UInt64?) async throws {
        guard let s = server else { throw IMAPClientError.notConnected }
        try Self.validateMailboxName(source)
        try Self.validateMailboxName(destination)
        try await selectAndVerifyValidity(mailbox: source, expected: expectedUIDValidity)
        guard !uids.isEmpty else { return }
        do {
            // MOVE in batches. The IMAP layer issues a separate UID MOVE
            // per chunk; the server processes them sequentially over the
            // same connection. If one chunk fails (e.g. timeout, server
            // hiccup) we propagate immediately — partial completion is
            // observable through STATUS on the next refresh, and surfacing
            // the failure quickly is better than silently soldiering on.
            for chunk in Self.batches(of: uids, size: Self.destructiveBatchSize) {
                let set = uidSet(from: chunk)
                guard !set.isEmpty else { continue }
                try await retryTransient { try await s.move(messages: set, to: destination) }
            }
        } catch {
            throw IMAPClientError.underlying(error)
        }
    }

    /// Slice a UID array into contiguous fixed-size chunks. Inlined here
    /// instead of using a shared extension — `Array.chunked` lives in
    /// `SenderCategorizer.swift` and is `fileprivate` there, and exposing
    /// a public helper just for two call sites would be more invasive than
    /// this five-line static.
    private static func batches(of uids: [UInt32], size: Int) -> [[UInt32]] {
        guard size > 0 else { return [uids] }
        return stride(from: 0, to: uids.count, by: size).map {
            Array(uids[$0..<Swift.min($0 + size, uids.count)])
        }
    }

    public func listMailboxes() async throws -> [Mailbox] {
        guard let s = server else { throw IMAPClientError.notConnected }
        let infos: [SwiftMail.Mailbox.Info]
        do {
            infos = try await s.listMailboxes()
        } catch {
            throw IMAPClientError.fetchFailed(String(describing: error))
        }
        return infos.map { info in
            Mailbox(
                name: info.name,
                kind: kind(for: info.attributes, name: info.name),
                hierarchyDelimiter: info.hierarchyDelimiter,
                isSelectable: info.isSelectable,
                messageCount: nil
            )
        }
    }

    public func createMailbox(_ name: String) async throws {
        guard let s = server else { throw IMAPClientError.notConnected }
        try Self.validateMailboxName(name)
        do {
            try await s.createMailbox(name)
        } catch {
            throw IMAPClientError.underlying(error)
        }
    }

    public func deleteMailbox(_ name: String) async throws {
        guard let s = server else { throw IMAPClientError.notConnected }
        try Self.validateMailboxName(name)
        do {
            try await s.deleteMailbox(name)
        } catch {
            throw IMAPClientError.underlying(error)
        }
    }

    public func renameMailbox(from source: String, to destination: String) async throws {
        guard let s = server else { throw IMAPClientError.notConnected }
        try Self.validateMailboxName(source)
        try Self.validateMailboxName(destination)
        do {
            try await s.renameMailbox(from: source, to: destination)
        } catch {
            throw IMAPClientError.underlying(error)
        }
    }

    public func emptyMailbox(_ name: String) async throws -> Int {
        guard let s = server else { throw IMAPClientError.notConnected }
        try Self.validateMailboxName(name)
        let selection: SwiftMail.Mailbox.Selection
        do {
            selection = try await s.selectMailbox(name)
        } catch {
            throw IMAPClientError.fetchFailed(String(describing: error))
        }
        selectedMailbox = name
        let total = selection.messageCount
        guard total > 0 else { return 0 }
        // STORE `\Deleted` in sequence-number chunks so a Trash with tens
        // of thousands of messages still completes within the per-command
        // timeout. Using `1:*` in one shot worked on small mailboxes but
        // tripped the 30s budget once the user actually filled Trash.
        // EXPUNGE runs once at the end and is bounded by what STORE just
        // flagged.
        let batch = Self.destructiveBatchSize
        var start = 1
        do {
            while start <= total {
                let end = min(start + batch - 1, total)
                let chunk = SwiftMail.SequenceNumberSet(start...end)
                try await retryTransient {
                    try await s.store(flags: [.deleted], on: chunk, operation: .add)
                }
                start = end + 1
            }
            try await retryTransient { try await s.expunge() }
        } catch {
            throw IMAPClientError.underlying(error)
        }
        return total
    }

    public func mailboxStatus(_ name: String) async throws -> MailboxStatus {
        guard let s = server else { throw IMAPClientError.notConnected }
        try Self.validateMailboxName(name)
        let status: SwiftMail.Mailbox.Status
        do {
            status = try await s.mailboxStatus(name)
        } catch {
            throw IMAPClientError.fetchFailed(String(describing: error))
        }
        return MailboxStatus(messageCount: status.messageCount, unseenCount: status.unseenCount)
    }

    private func ensureSelected(_ mailbox: String) async throws {
        guard let s = server else { throw IMAPClientError.notConnected }
        try Self.validateMailboxName(mailbox)
        if selectedMailbox != mailbox {
            _ = try await s.selectMailbox(mailbox)
            selectedMailbox = mailbox
        }
    }

    /// SELECT the mailbox unconditionally (so we get a fresh UIDVALIDITY in
    /// the response) and verify it matches `expected`. Pass `nil` to skip the
    /// check — used only by ad-hoc callers that built the UIDs in the same
    /// call and have no prior validity to compare against.
    ///
    /// Why always-SELECT instead of `ensureSelected`'s cached fast path:
    /// IMAP servers send UIDVALIDITY only in the SELECT response, not on
    /// every command. If we reuse a stale selection from earlier in the
    /// session, we never notice that the server changed UIDVALIDITY mid-
    /// session — and our locally-cached UIDs are now silently misaligned.
    /// The cost of one extra SELECT per mutation is well worth the
    /// guarantee that we never delete the wrong messages.
    private func selectAndVerifyValidity(mailbox: String, expected: UInt64?) async throws {
        guard let s = server else { throw IMAPClientError.notConnected }
        try Self.validateMailboxName(mailbox)
        let selection: SwiftMail.Mailbox.Selection
        do {
            selection = try await s.selectMailbox(mailbox)
        } catch {
            throw IMAPClientError.fetchFailed(String(describing: error))
        }
        selectedMailbox = mailbox
        if let expected {
            let actual = UInt64(selection.uidValidity.value)
            if actual != expected {
                throw IMAPClientError.uidValidityChanged(expected: expected, actual: actual)
            }
        }
    }

    private func uidSet(from uids: [UInt32]) -> SwiftMail.UIDSet {
        var set = SwiftMail.UIDSet()
        for u in uids { set.insert(SwiftMail.UID(u)) }
        return set
    }

    /// Internal alias kept so call sites within this actor can use the
    /// short `Self.validateMailboxName(_:)` spelling. The real
    /// implementation lives on `IMAPMailboxName` so tests and UI sheets
    /// can reach it without `@testable import`.
    static func validateMailboxName(_ name: String) throws {
        try IMAPMailboxName.validate(name)
    }

    private func kind(for attrs: SwiftMail.Mailbox.Info.Attributes, name: String) -> Mailbox.Kind {
        // Primary signal: IMAP SPECIAL-USE attributes (RFC 6154). When the
        // server advertises them, they're authoritative.
        if attrs.contains(.inbox) || name.uppercased() == "INBOX" { return .inbox }
        if attrs.contains(.sent)    { return .sent }
        if attrs.contains(.drafts)  { return .drafts }
        if attrs.contains(.archive) { return .archive }
        if attrs.contains(.trash)   { return .trash }
        if attrs.contains(.junk)    { return .junk }

        // Fallback: many servers — iCloud Mail in particular, also older
        // Exchange and several shared-hosting setups — host the standard
        // folders but never set SPECIAL-USE on them. Without this fallback
        // we'd classify everything except INBOX as `.other`, which means
        // the Archive toolbar button stays disabled forever (it gates on
        // `archiveMailboxName != nil`) and the sent-folder reply detector
        // never finds the sent folder. Match on the leaf folder name
        // (case-insensitive) using the well-known spellings each major
        // provider uses.
        let leaf = leafName(name).lowercased()
        switch leaf {
        case "archive", "archives", "all mail":
            return .archive
        case "sent", "sent messages", "sent items":
            return .sent
        case "drafts", "draft":
            return .drafts
        case "trash", "deleted", "deleted messages", "deleted items", "bin":
            return .trash
        case "junk", "spam", "junk mail", "junk e-mail":
            return .junk
        default:
            return .other
        }
    }

    /// Strip an IMAP hierarchy prefix so "INBOX.Archive" / "[Gmail]/All Mail"
    /// resolve to "Archive" / "All Mail" for name-based matching. We don't
    /// always know the server's hierarchy delimiter at this layer, so we
    /// split on both common ones — they're the only delimiters anyone uses
    /// in practice.
    private func leafName(_ name: String) -> String {
        var leaf = name
        for delim: Character in ["/", "."] {
            if let last = leaf.split(separator: delim).last, last.count != leaf.count {
                leaf = String(last)
            }
        }
        return leaf
    }
}

/// Build a File13 MessageHeader from a SwiftMail MessageInfo. Returns nil when the message
/// doesn't have a UID — IMAP requires it for any subsequent server-side action.
private func makeMessageHeader(from info: SwiftMail.MessageInfo, accountId: UUID) -> MessageHeader? {
    guard let uid = info.uid else { return nil }
    let parsedFrom = parseFromHeader(info.from ?? "")
    let rawId = info.messageId.map(String.init(describing:)) ?? "uid-\(uid.value)"

    let extra = info.additionalFields ?? [:]
    let normalizedExtra = Dictionary(uniqueKeysWithValues: extra.map { ($0.key.lowercased(), $0.value) })

    let listUnsubscribe = normalizedExtra["list-unsubscribe"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let listUnsubscribePost = normalizedExtra["list-unsubscribe-post"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let listId = normalizedExtra["list-id"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let autoSubmittedRaw = normalizedExtra["auto-submitted"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    // Per RFC 3834, "no" / absent both mean "not auto-submitted"; anything else marks it auto.
    let isAutoSubmitted = (autoSubmittedRaw != nil && autoSubmittedRaw != "no")
    let inReplyTo = info.inReplyTo.map(String.init(describing:))
    let sizeBytes = info.size.flatMap { $0 > 0 ? UInt32(clamping: $0) : nil }

    let to = info.to.compactMap(extractAddress)
    let cc = info.cc.compactMap(extractAddress)

    return MessageHeader(
        rawMessageId: rawId,
        uid: uid.value,
        senderName: parsedFrom.name,
        senderAddress: parsedFrom.address,
        subject: info.subject ?? "",
        date: info.date ?? info.internalDate ?? Date(),
        accountId: accountId,
        isRead: info.flags.contains(.seen),
        toAddresses: to,
        ccAddresses: cc,
        listUnsubscribe: listUnsubscribe,
        listUnsubscribePost: listUnsubscribePost,
        listId: listId,
        isAutoSubmitted: isAutoSubmitted,
        inReplyTo: inReplyTo,
        sizeBytes: sizeBytes
    )
}

/// Pull the bare address from one of SwiftMail's `formatAddress` outputs ("Name <a@b.com>" or
/// "a@b.com"). Mirrors `parseFromHeader` but returns just the address part.
private func extractAddress(_ formatted: String) -> String? {
    let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let lt = trimmed.lastIndex(of: "<"),
       let gt = trimmed[lt...].firstIndex(of: ">"),
       lt < gt {
        return String(trimmed[trimmed.index(after: lt)..<gt])
            .trimmingCharacters(in: .whitespaces)
    }
    return trimmed
}

private func parseFromHeader(_ raw: String) -> (name: String, address: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ("", "") }

    if let lt = trimmed.lastIndex(of: "<"),
       let gt = trimmed[lt...].firstIndex(of: ">"),
       lt < gt {
        let address = String(trimmed[trimmed.index(after: lt)..<gt])
            .trimmingCharacters(in: .whitespaces)
        var name = String(trimmed[..<lt]).trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        return (name, address)
    }
    return ("", trimmed)
}
