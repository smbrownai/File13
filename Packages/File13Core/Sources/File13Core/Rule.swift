import Foundation

public struct Rule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var conditions: Conditions
    public var outcome: Outcome
    /// Which mailbox(es) the rule should run against. Persisted as optional so
    /// existing rules decode unchanged — nil resolves to `.currentMailbox`,
    /// the legacy behavior.
    public var scope: RuleScope?
    public var createdAt: Date

    /// Effective scope, with the legacy default applied.
    public var effectiveScope: RuleScope { scope ?? .currentMailbox }

    public init(id: UUID = UUID(),
         name: String = "",
         enabled: Bool = true,
         conditions: Conditions = Conditions(),
         outcome: Outcome = .delete,
         scope: RuleScope? = nil,
         createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.conditions = conditions
        self.outcome = outcome
        self.scope = scope
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, conditions, outcome, scope, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id          = try c.decode(UUID.self,       forKey: .id)
        self.name        = try c.decode(String.self,     forKey: .name)
        self.enabled     = try c.decode(Bool.self,       forKey: .enabled)
        self.conditions  = try c.decode(Conditions.self, forKey: .conditions)
        self.outcome     = try c.decode(Outcome.self,    forKey: .outcome)
        self.scope       = try c.decodeIfPresent(RuleScope.self, forKey: .scope)
        self.createdAt   = try c.decode(Date.self,       forKey: .createdAt)
    }

    public struct Conditions: Codable, Hashable, Sendable {
        public var fromAddressOrDomain: String?
        public var subjectContains: String?
        public var olderThanDays: Int?
        /// `nil` ignores read state, `true` matches unread only, `false` matches read only.
        public var isUnread: Bool?
        /// Match only senders the AI categorizer has assigned to this category. `nil` ignores
        /// category. Senders that haven't been categorized are non-matches when this is set.
        public var category: SenderCategory?
        /// Match only messages whose sender domain appears in the bundled
        /// disposable-email-domains blocklist (see `DisposableSenderDetector`). `nil` ignores
        /// the signal; `true` requires a disposable-domain match; `false` requires the sender
        /// NOT be on the list. Stored optional so JSON-decoded rules from older clients keep
        /// behaving identically (no change in match set).
        public var senderDomainIsDisposable: Bool?

        public init(fromAddressOrDomain: String? = nil, subjectContains: String? = nil, olderThanDays: Int? = nil, isUnread: Bool? = nil, category: SenderCategory? = nil, senderDomainIsDisposable: Bool? = nil) {
            self.fromAddressOrDomain = fromAddressOrDomain
            self.subjectContains = subjectContains
            self.olderThanDays = olderThanDays
            self.isUnread = isUnread
            self.category = category
            self.senderDomainIsDisposable = senderDomainIsDisposable
        }

        public var isEmpty: Bool {
            (fromAddressOrDomain?.isEmpty ?? true)
                && (subjectContains?.isEmpty ?? true)
                && olderThanDays == nil
                && isUnread == nil
                && category == nil
                && senderDomainIsDisposable == nil
        }

        public var summary: String {
            var parts: [String] = []
            if let f = fromAddressOrDomain, !f.isEmpty { parts.append("from \(f)") }
            if let s = subjectContains,    !s.isEmpty { parts.append("subject contains \"\(s)\"") }
            if let d = olderThanDays                  { parts.append("older than \(d) days") }
            if let u = isUnread                       { parts.append(u ? "unread" : "read") }
            if let c = category                       { parts.append("category: \(c.label.lowercased())") }
            if let d = senderDomainIsDisposable       { parts.append(d ? "disposable sender domain" : "non-disposable sender domain") }
            return parts.isEmpty ? "no conditions" : parts.joined(separator: " · ")
        }
    }

    public enum Outcome: Codable, Hashable, Sendable {
        case delete
        case archive
        case moveToFolder(String)
        case unsubscribe

        public var label: String {
            switch self {
            case .delete:               "Delete"
            case .archive:              "Archive"
            case .moveToFolder(let f):  "Move to \(f)"
            case .unsubscribe:          "Unsubscribe"
            }
        }

        public var symbol: String {
            switch self {
            case .delete:        "trash"
            case .archive:       "archivebox"
            case .moveToFolder:  "folder"
            case .unsubscribe:   "envelope.badge"
            }
        }

        public var isSupported: Bool {
            switch self {
            case .unsubscribe: false
            default: true
            }
        }
    }
}

/// Where a rule should run. Independent of the rule's match conditions —
/// a rule with `subjectContains: "receipt"` and scope `.allFolders` matches
/// "receipt"-subject messages across every cached folder, not just the
/// active one.
public enum RuleScope: Codable, Hashable, Sendable {
    /// Apply against whatever mailbox is currently being processed (active
    /// mailbox in the GUI; current per-account mailbox in the CLI). This is
    /// the default and matches behavior before the scope field existed.
    case currentMailbox
    /// Apply against this exact mailbox name in every account. Headers are
    /// loaded from the local cache; accounts that don't have this mailbox
    /// cached are skipped.
    case folder(String)
    /// Apply against every cached mailbox in every account.
    case allFolders

    public var summary: String {
        switch self {
        case .currentMailbox:     "Current mailbox"
        case .folder(let name):   name
        case .allFolders:         "All folders"
        }
    }
}

public enum RuleEvaluator {
    /// - Parameter categoryFor: lookup from sender id (lowercased address) to its AI-assigned
    ///   category. Pass `{ _ in nil }` if you don't have categorization data — rules with a
    ///   `category` condition will simply not match in that case.
    public static func matches(
        _ message: MessageHeader,
        rule: Rule,
        categoryFor: (String) -> SenderCategory? = { _ in nil },
        now: Date = .now
    ) -> Bool {
        guard rule.enabled, !rule.conditions.isEmpty else { return false }
        let c = rule.conditions

        if let from = c.fromAddressOrDomain, !from.isEmpty {
            // Split on commas so a user can list multiple addresses or
            // domains in one field — the rule-from-selection flow prefills
            // this when N senders are picked, and a hand-edited rule should
            // accept the same shape. Each token is OR'd: the message
            // matches if its sender hits any of them. A single token
            // (no commas) collapses to the original single-needle path.
            let address = message.senderAddress.lowercased()
            let needles = from
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            let matched = needles.contains { needle in
                address == needle
                    || address.hasSuffix("@\(needle)")
                    || address.contains(needle)
            }
            if !matched { return false }
        }
        if let subject = c.subjectContains, !subject.isEmpty {
            if !message.subject.localizedCaseInsensitiveContains(subject) {
                return false
            }
        }
        if let days = c.olderThanDays, days > 0 {
            let threshold = now.addingTimeInterval(-Double(days) * 86_400)
            if message.date >= threshold { return false }
        }
        if let isUnread = c.isUnread {
            if isUnread && message.isRead { return false }
            if !isUnread && !message.isRead { return false }
        }
        if let category = c.category {
            let senderId = message.senderAddress.lowercased()
            guard categoryFor(senderId) == category else { return false }
        }
        if let isDisposable = c.senderDomainIsDisposable {
            // Read the memoized flag set at `MessageHeader.init` (which calls
            // `DisposableSenderDetector.isDisposable`). Avoids re-scanning the 5k-entry
            // domain set per rule evaluation.
            if isDisposable != message.isFromDisposableDomain { return false }
        }
        return true
    }
}
