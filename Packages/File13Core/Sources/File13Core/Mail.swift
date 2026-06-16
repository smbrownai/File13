import Foundation

public struct Account: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var displayName: String
    public var address: String
    public var host: String
    public var port: Int
    public var username: String
    public var provider: Provider
    /// How File13 authenticates this account. Defaults to `.password` for
    /// accounts persisted before OAuth landed (see `init(from:)`); new Gmail
    /// or Microsoft accounts created through the sign-in flow are stored as
    /// `.oauth2Gmail` / `.oauth2Microsoft`.
    public var authKind: AuthKind

    public enum Provider: String, Hashable, Codable, Sendable {
        case gmail, outlook, icloud, yahoo, aol, imap
    }

    public enum AuthKind: String, Hashable, Codable, Sendable {
        case password
        // OAuth cases lived here for Gmail (gone — Google CASA audit is
        // unviable) and Microsoft (gone — Microsoft Publisher Verification
        // requires a paid Azure tenant or work account). Re-add a case here
        // if a viable third-party OAuth provider becomes available; the
        // surrounding scaffolding (`AccountCredentials.auth`, XOAUTH2 in
        // `SwiftMailIMAPClient`, `OAuth2Client` / `OAuthFlow`,
        // `KeychainStore.OAuthTokens`) is intentionally still in place.
    }

    public init(id: UUID = UUID(), displayName: String, address: String, host: String, port: Int, username: String, provider: Provider, authKind: AuthKind = .password) {
        self.id = id
        self.displayName = displayName
        self.address = address
        self.host = host
        self.port = port
        self.username = username
        self.provider = provider
        self.authKind = authKind
    }

    // Pre-OAuth account records on disk have no `authKind` key. Decode them
    // as `.password` so existing installs keep working without a forced
    // re-add. Encode is synthesized so new writes always include the key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.address = try c.decode(String.self, forKey: .address)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decode(Int.self, forKey: .port)
        self.username = try c.decode(String.self, forKey: .username)
        self.provider = try c.decode(Provider.self, forKey: .provider)
        self.authKind = try c.decodeIfPresent(AuthKind.self, forKey: .authKind) ?? .password
    }
}

public struct MessageHeader: Identifiable, Hashable, Sendable {
    /// Globally unique within File13: `"<accountId>|<rawMessageId>"`.
    public let id: String
    /// Server-side Message-ID (or our synthesized fallback) without the account prefix.
    public let rawMessageId: String
    public let uid: UInt32?
    public let senderName: String
    public let senderAddress: String
    public let subject: String
    public let date: Date
    public let accountId: UUID
    /// Read state from the IMAP `\Seen` flag. We never write this back to the server.
    public let isRead: Bool

    // Triage-oriented metadata (populated from ENVELOPE + a tiny set of named header fields).
    // No body content is ever stored.
    public let toAddresses: [String]
    public let ccAddresses: [String]
    /// Raw `List-Unsubscribe` header value — typically a `<mailto:…>` and/or `<https://…>` token.
    public let listUnsubscribe: String?
    /// Raw `List-Unsubscribe-Post` header (RFC 8058). When this contains `List-Unsubscribe=One-Click`,
    /// the HTTPS URL in `listUnsubscribe` can be POSTed to without further user confirmation.
    public let listUnsubscribePost: String?
    /// `List-ID` header value (RFC 2919) — strong signal of a list/newsletter sender.
    public let listId: String?
    /// Whether the `Auto-Submitted` header indicates a non-personal, machine-generated message.
    public let isAutoSubmitted: Bool
    /// Message-ID of the message this one replied to, when threaded.
    public let inReplyTo: String?
    /// RFC822.SIZE of the message in bytes, when the server supplied it.
    public let sizeBytes: UInt32?
    /// Whether the message carries at least one attachment, computed from BODYSTRUCTURE when
    /// available. `nil` ⇒ unknown (the slim fetch path doesn't request BODYSTRUCTURE so the
    /// data isn't present on every row yet). The bool itself is the only thing we ever store;
    /// attachment filenames, MIME types, and body bytes are not read, not parsed beyond the
    /// presence check, and not persisted.
    public let hasAttachments: Bool?

    /// Cached output of `TransactionalDetector` so repeated reads don't re-scan the subject
    /// against the keyword list. Computed once at init, immutable thereafter.
    public let isLikelyTransactional: Bool

    /// True when the sender's domain appears in the bundled disposable-email-domains
    /// blocklist (`DisposableSenderDetector`). Memoized at init for the same reason
    /// `isLikelyTransactional` is — every row body in the sender table reads this, and the
    /// underlying `Set.contains` lookup is cheap but still worth caching.
    public let isFromDisposableDomain: Bool

    public init(rawMessageId: String,
         uid: UInt32?,
         senderName: String,
         senderAddress: String,
         subject: String,
         date: Date,
         accountId: UUID,
         isRead: Bool = false,
         toAddresses: [String] = [],
         ccAddresses: [String] = [],
         listUnsubscribe: String? = nil,
         listUnsubscribePost: String? = nil,
         listId: String? = nil,
         isAutoSubmitted: Bool = false,
         inReplyTo: String? = nil,
         sizeBytes: UInt32? = nil,
         hasAttachments: Bool? = nil) {
        self.rawMessageId = rawMessageId
        self.uid = uid
        // Strip BiDi formatting controls from sender-controlled display
        // text at the cache boundary, so every consumer (the sender table,
        // the inspector, AI prompts, the CLI listing) sees the clean form.
        // A hostile sender can set their display name to `paypal.com<U+202E>moc.evil`
        // which renders as `paypal.commolla.com` — a homograph attack on
        // the user's visual identification of who sent a message. We strip
        // at construction, not at rendering, so no consumer can forget.
        // `senderAddress` is left untouched because rule matching and
        // dedup keys depend on byte-for-byte equality with what the
        // server stored.
        self.senderName = DisplaySanitizer.sanitizeForDisplay(senderName)
        self.senderAddress = senderAddress
        self.subject = DisplaySanitizer.sanitizeForDisplay(subject)
        self.date = date
        self.accountId = accountId
        self.isRead = isRead
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
        self.listId = listId
        self.isAutoSubmitted = isAutoSubmitted
        self.inReplyTo = inReplyTo
        self.sizeBytes = sizeBytes
        self.hasAttachments = hasAttachments
        self.id = "\(accountId.uuidString)|\(rawMessageId)"
        // Memoize the transactional classification so per-render reads (selection counts,
        // confirm dialogs, rule evaluation) don't repeat ~36 substring scans per header.
        let isLikelyNewsletter = listUnsubscribe != nil || listId != nil || isAutoSubmitted
        self.isLikelyTransactional = TransactionalDetector.matches(
            subject: subject,
            isLikelyNewsletter: isLikelyNewsletter
        )
        // Same idea for the disposable-domain check — a `Set.contains` against a 5k-entry
        // domain set is fast, but it's read on every row body, so cache it.
        self.isFromDisposableDomain = DisposableSenderDetector.isDisposable(address: senderAddress)
    }

    /// Return a copy of this header with `isRead` replaced and every other field forwarded
    /// unchanged. Used by `AccountSession`'s reconcile pass when the IMAP server reports a
    /// new `\Seen` flag on an existing message: we can't mutate the struct in place because
    /// the properties are `let`, but we also can't afford to drop the rest of the metadata
    /// (newsletter/list signals, size, reply linkage, attachment presence) on every flag
    /// flip. Keep this helper exhaustive — any new field added to `MessageHeader` must be
    /// forwarded here too, or it'll silently zero out on the next read-state reconcile.
    public func withRead(_ newIsRead: Bool) -> MessageHeader {
        MessageHeader(
            rawMessageId: rawMessageId,
            uid: uid,
            senderName: senderName,
            senderAddress: senderAddress,
            subject: subject,
            date: date,
            accountId: accountId,
            isRead: newIsRead,
            toAddresses: toAddresses,
            ccAddresses: ccAddresses,
            listUnsubscribe: listUnsubscribe,
            listUnsubscribePost: listUnsubscribePost,
            listId: listId,
            isAutoSubmitted: isAutoSubmitted,
            inReplyTo: inReplyTo,
            sizeBytes: sizeBytes,
            hasAttachments: hasAttachments
        )
    }

    public var senderId: String { senderAddress.lowercased() }

    /// Heuristic: explicit list/auto-mail headers strongly suggest a newsletter or system mail.
    public var isLikelyNewsletter: Bool {
        listUnsubscribe != nil || listId != nil || isAutoSubmitted
    }

    /// Whether this looks like personal correspondence (1:1 or small To list, no list headers).
    /// Heuristic — useful for AI prompts that want to weight personal mail higher.
    public var looksPersonal: Bool {
        guard !isLikelyNewsletter else { return false }
        return toAddresses.count <= 3 && ccAddresses.count <= 3
    }
}

public struct Sender: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var address: String
    public var messages: [MessageHeader]
    /// Cached count of unread messages, computed once at construction. Read on every
    /// SwiftUI row body and bulk-bar render, so the previous `messages.filter` scan
    /// per-access was an O(N) tax on every redraw.
    public let unreadCount: Int
    /// Cached newest-message date. Callers pre-sort `messages` newest-first
    /// (`groupedBySender()` does), so the primary init reads `messages.first?.date`
    /// instead of allocating a `[Date]` for `.max()`.
    public let mostRecent: Date

    /// Primary init. Trusts the caller for the cached `unreadCount` and
    /// `mostRecent` — `groupedBySender()` accumulates them in lockstep with
    /// the messages array, so passing them in is free.
    public init(
        id: String,
        name: String,
        address: String,
        messages: [MessageHeader],
        unreadCount: Int,
        mostRecent: Date
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.messages = messages
        self.unreadCount = unreadCount
        self.mostRecent = mostRecent
    }

    /// Convenience init for call sites that don't already know the derived
    /// values (tests, mocks). Computes them once from `messages`. Production
    /// hot paths route through the primary init.
    public init(id: String, name: String, address: String, messages: [MessageHeader]) {
        var unread = 0
        var latest: Date = .distantPast
        for m in messages {
            if !m.isRead { unread += 1 }
            if m.date > latest { latest = m.date }
        }
        self.init(
            id: id,
            name: name,
            address: address,
            messages: messages,
            unreadCount: unread,
            mostRecent: latest
        )
    }

    public var messageCount: Int { messages.count }

    /// True if any of this sender's messages carries newsletter/auto-mail headers.
    public var isLikelyNewsletter: Bool {
        messages.contains { $0.isLikelyNewsletter }
    }

    /// The most recent message that has an unsubscribe header — the one we should target when
    /// the user clicks Unsubscribe on this sender.
    public var unsubscribeAnchor: MessageHeader? {
        messages
            .lazy
            .filter { $0.listUnsubscribe != nil }
            .max(by: { $0.date < $1.date })
    }

    /// Highest-priority unsubscribe mechanism available across all of this sender's messages.
    /// Scans every message's `List-Unsubscribe` (+ `List-Unsubscribe-Post`) headers, runs them
    /// through `UnsubscribeParser`, and picks the strongest result (one-click > web > mailto).
    /// Different messages from the same sender can advertise different mechanisms; we prefer the
    /// best one because that's the path the user actually wants offered.
    ///
    /// Returns `nil` when no message has a usable `List-Unsubscribe` header.
    public var bestUnsubscribeMechanism: UnsubscribeMechanism? {
        var best: UnsubscribeMechanism?
        for message in messages {
            guard let raw = message.listUnsubscribe else { continue }
            for mechanism in UnsubscribeParser.parse(
                listUnsubscribe: raw,
                listUnsubscribePost: message.listUnsubscribePost
            ) {
                if best == nil || mechanism.groupPriority < best!.groupPriority {
                    best = mechanism
                }
                if case .oneClick = mechanism { return mechanism }
            }
        }
        return best
    }

    /// Classification used by the "Newsletters" view to group senders by the kind of unsubscribe
    /// they expose. Derived from `bestUnsubscribeMechanism` so the grouping always matches the
    /// action `UnsubscribeService` would take.
    public var unsubscribeGroup: UnsubscribeGroup {
        switch bestUnsubscribeMechanism {
        case .oneClick: return .oneClick
        case .web:      return .web
        case .mailto:   return .email
        case .none:     return .none
        }
    }
}

/// Bucket that the Newsletters view groups senders into, based on the strongest
/// `UnsubscribeMechanism` they expose. Order matches priority: one-click is the most
/// actionable and lands first.
public enum UnsubscribeGroup: Int, Hashable, Sendable, CaseIterable, Comparable {
    case oneClick = 0
    case web = 1
    case email = 2
    case none = 3

    public static func < (lhs: UnsubscribeGroup, rhs: UnsubscribeGroup) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Section title for the grouped Newsletters view.
    public var title: String {
        switch self {
        case .oneClick: return "One-Click Unsubscribe"
        case .web:      return "Website Unsubscribe"
        case .email:    return "Email Unsubscribe"
        case .none:     return "No Unsubscribe Link"
        }
    }

    /// Short caption shown under the section title — explains what tapping
    /// Unsubscribe will actually do for senders in this bucket.
    public var caption: String {
        switch self {
        case .oneClick: return "Unsubscribes in place via RFC 8058 POST. Safe for bulk action."
        case .web:      return "Opens the sender's unsubscribe page in your browser."
        case .email:    return "Opens your mail client to send the unsubscribe message."
        case .none:     return "No List-Unsubscribe header — handle via your mail client."
        }
    }
}

extension UnsubscribeMechanism {
    /// Lower number = stronger / more preferred. Used by `Sender.bestUnsubscribeMechanism` so the
    /// comparison stays in one place if we ever add a new mechanism kind.
    fileprivate var groupPriority: Int {
        switch self {
        case .oneClick: return 0
        case .web:      return 1
        case .mailto:   return 2
        }
    }
}

/// One row-group in the Newsletters-view grouped table. The grouping is presentational only —
/// `senders` is a slice of `InboxStore.displaySenders` in the same sort order, and selecting a
/// sender from any group routes through the same `UnsubscribeService` path it would otherwise.
public struct SenderGroupSection: Hashable, Sendable, Identifiable {
    public let group: UnsubscribeGroup
    public let senders: [Sender]

    public var id: UnsubscribeGroup { group }
    public var count: Int { senders.count }

    public init(group: UnsubscribeGroup, senders: [Sender]) {
        self.group = group
        self.senders = senders
    }
}

public struct Mailbox: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let kind: Kind
    public let hierarchyDelimiter: String?
    /// `false` for IMAP `\Noselect` containers — Gmail's bare `[Gmail]`
    /// parent is the canonical example: it exists only to nest the special
    /// folders (`[Gmail]/Trash`, `[Gmail]/All Mail`, etc.) and STATUS /
    /// SELECT against it always errors. We still surface the row in the
    /// sidebar so the visual hierarchy stays intact, but counts and
    /// mailbox-status sweeps skip it.
    public let isSelectable: Bool
    public var messageCount: Int?
    /// Unseen-flag count from the last `STATUS (UNSEEN)` round-trip, or
    /// `nil` if we haven't run one yet. Populated by
    /// `AccountSession.refreshMailboxStatuses()` after the initial mailbox
    /// listing. Lets sidebar / mailbox-picker UI show the right badge for
    /// mailboxes the user hasn't opened yet (otherwise the unread number
    /// derives from cached headers, which are empty for never-visited
    /// folders).
    public var unseenCount: Int?

    public init(
        name: String,
        kind: Kind,
        hierarchyDelimiter: String?,
        isSelectable: Bool = true,
        messageCount: Int? = nil,
        unseenCount: Int? = nil
    ) {
        self.name = name
        self.kind = kind
        self.hierarchyDelimiter = hierarchyDelimiter
        self.isSelectable = isSelectable
        self.messageCount = messageCount
        self.unseenCount = unseenCount
    }

    public enum Kind: Int, Hashable, Comparable, Sendable {
        case inbox = 0, sent, drafts, archive, trash, junk, other
        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var isSystem: Bool {
        switch kind { case .other: false; default: true }
    }

    public var displayName: String {
        if name.uppercased() == "INBOX" { return "Inbox" }
        if let delim = hierarchyDelimiter, let last = name.split(separator: delim).last {
            return String(last)
        }
        return name
    }

    public var systemIcon: String {
        switch kind {
        case .inbox:   "tray"
        case .sent:    "paperplane"
        case .drafts:  "doc.text"
        case .archive: "archivebox"
        case .trash:   "trash"
        case .junk:    "exclamationmark.octagon"
        case .other:   "folder"
        }
    }
}

public struct MailboxStatus: Sendable {
    public let messageCount: Int?
    public let unseenCount: Int?

    public init(messageCount: Int?, unseenCount: Int?) {
        self.messageCount = messageCount
        self.unseenCount = unseenCount
    }
}

extension Array where Element == MessageHeader {
    /// Group headers by canonical sender address, producing a Sender for each.
    /// The display name is taken from the most recently seen header that carried one.
    /// Messages within each sender are sorted newest-first so the expanded row's
    /// `MessageList` view doesn't have to re-sort on every render.
    ///
    /// Accumulates derived counts (`unreadCount`, `mostRecent`) inline so the
    /// constructed `Sender` doesn't have to re-scan its own messages. Uses
    /// `Dictionary[key, default:]` inout-subscript access — `var entry =
    /// byKey[key]` / `byKey[key] = entry` copies the whole `messages` array
    /// out of the dictionary's storage and back on every append, which is
    /// quadratic-in-batch-size CoW thrash for senders with many messages.
    public func groupedBySender() -> [Sender] {
        var byKey: [String: SenderAccumulator] = [:]
        byKey.reserveCapacity(Swift.min(count, 1024))
        for m in self {
            byKey[
                m.senderId,
                default: SenderAccumulator(address: m.senderAddress)
            ].ingest(m)
        }
        return byKey.values.map { $0.finish() }
    }
}

/// Per-sender accumulator used by `groupedBySender()`. Lives at file scope
/// (not nested in the function) so the `Dictionary[default:]` autoclosure
/// can construct it without dragging in the enclosing method's captures.
///
/// Why this exists: the previous implementation copied an entire
/// `(name, address, messages)` tuple out of the dictionary on every append
/// (`var entry = byKey[key]; entry.messages.append(m); byKey[key] = entry`),
/// which is quadratic-in-cluster-size CoW thrash. `Dictionary[default:]` +
/// a mutating `ingest` does the append in place via the dictionary's modify
/// accessor, and accumulates `unreadCount` / `mostRecent` inline so the
/// resulting `Sender` doesn't have to re-scan its own messages.
/// Shared with `Array<MessageHeader>.groupedForDisplay()` in `Grouping.swift`,
/// which fuses sender/subject/date accumulation into a single pass.
struct SenderAccumulator {
    var name: String = ""
    let address: String
    var messages: [MessageHeader] = []
    var unreadCount: Int = 0
    var mostRecent: Date = .distantPast

    mutating func ingest(_ m: MessageHeader) {
        messages.append(m)
        if name.isEmpty && !m.senderName.isEmpty { name = m.senderName }
        if !m.isRead { unreadCount += 1 }
        if m.date > mostRecent { mostRecent = m.date }
    }

    func finish() -> Sender {
        let sorted = messages.sorted { $0.date > $1.date }
        return Sender(
            id: address.lowercased(),
            name: name,
            address: address,
            messages: sorted,
            unreadCount: unreadCount,
            mostRecent: mostRecent
        )
    }
}
