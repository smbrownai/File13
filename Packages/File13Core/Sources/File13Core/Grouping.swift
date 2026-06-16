import Foundation

// MARK: Subject clustering

public struct SubjectCluster: Identifiable, Hashable, Sendable {
    public let id: String                  // the normalized subject (cluster key)
    public let representative: String      // the original subject we'll show in the row
    public let messages: [MessageHeader]
    /// Cached count of unread messages in this cluster. See `Sender.unreadCount`
    /// for rationale — these accessors are read from view bodies on every
    /// observable mutation, so caching at construction time pays for itself
    /// many times over per redraw.
    public let unreadCount: Int
    /// Cached newest-message date. `clusteredBySubject()` pre-sorts messages
    /// newest-first, so this is just `messages.first?.date`.
    public let mostRecent: Date
    /// Cached unique-sender count. Building this requires walking `messages`
    /// once, which we already do in the grouping pass — no reason to do it
    /// again from a view body.
    public let uniqueSenderCount: Int

    /// Primary init. Trusts the caller for the cached derived counts —
    /// `clusteredBySubject()` accumulates them as it walks the input.
    public init(
        id: String,
        representative: String,
        messages: [MessageHeader],
        unreadCount: Int,
        mostRecent: Date,
        uniqueSenderCount: Int
    ) {
        self.id = id
        self.representative = representative
        self.messages = messages
        self.unreadCount = unreadCount
        self.mostRecent = mostRecent
        self.uniqueSenderCount = uniqueSenderCount
    }

    /// Convenience init for test / mock construction. Computes derived counts
    /// once from `messages`. Production hot paths use the primary init.
    public init(id: String, representative: String, messages: [MessageHeader]) {
        var unread = 0
        var latest: Date = .distantPast
        var senders: Set<String> = []
        for m in messages {
            if !m.isRead { unread += 1 }
            if m.date > latest { latest = m.date }
            senders.insert(m.senderAddress.lowercased())
        }
        self.init(
            id: id,
            representative: representative,
            messages: messages,
            unreadCount: unread,
            mostRecent: latest,
            uniqueSenderCount: senders.count
        )
    }

    public var messageCount: Int { messages.count }
}

public enum SubjectNormalizer {
    private static let prefixPattern = try! NSRegularExpression(
        pattern: #"^(re|fwd?|aw|wg|tr):\s*"#,
        options: [.caseInsensitive]
    )
    private static let listPrefixPattern = try! NSRegularExpression(
        pattern: #"^\[[^\]]+\]\s*"#,
        options: []
    )
    private static let trailingIdPattern = try! NSRegularExpression(
        pattern: #"\s*#?\d+\s*$"#,
        options: []
    )
    private static let trailingParenPattern = try! NSRegularExpression(
        pattern: #"\s*\([0-9/.\-]+\)\s*$"#,
        options: []
    )
    private static let whitespacePattern = try! NSRegularExpression(
        pattern: #"\s+"#,
        options: []
    )

    /// Upper bound on subject length the normalizer will scan. Each pass
    /// of `canonical` runs ~6 NSRegularExpression patterns; on
    /// pathologically-constructed inputs (e.g. long alternations of
    /// `re:re:re:…` prefixes, or deeply-nested `[list-name]` brackets)
    /// per-pattern matching could climb into super-linear territory.
    /// Real subjects are well under 200 chars; 1 KiB is a comfortable cap
    /// that doesn't truncate any RFC 5322 subject we'd see in the wild
    /// while bounding the worst-case regex work to a constant.
    private static let maxSubjectChars = 1024

    /// Hard cap on iterations of the prefix-stripping loop. Each iteration
    /// must strip at least one character; a bounded subject (above) can't
    /// have more than `maxSubjectChars` strip-able prefix tokens, but the
    /// counter is independent defense in case a future pattern is added
    /// that could match zero-width.
    private static let maxPrefixIterations = 64

    public static func canonical(_ raw: String) -> String {
        var s = raw.lowercased()
        // Bound the regex-input length before any pattern runs. This
        // collapses the worst-case scan from "depends on subject length"
        // to "constant time" for every later step.
        if s.count > Self.maxSubjectChars {
            s = String(s.prefix(Self.maxSubjectChars))
        }

        var changed = true
        var iterations = 0
        while changed && iterations < Self.maxPrefixIterations {
            iterations += 1
            changed = false
            let r = NSRange(s.startIndex..., in: s)
            if let m = prefixPattern.firstMatch(in: s, options: [], range: r),
               let range = Range(m.range, in: s) {
                s.removeSubrange(range)
                changed = true
                continue
            }
            if let m = listPrefixPattern.firstMatch(in: s, options: [], range: r),
               let range = Range(m.range, in: s) {
                s.removeSubrange(range)
                changed = true
            }
        }

        s = trailingIdPattern.stringByReplacingMatches(
            in: s, options: [],
            range: NSRange(s.startIndex..., in: s),
            withTemplate: ""
        )
        s = trailingParenPattern.stringByReplacingMatches(
            in: s, options: [],
            range: NSRange(s.startIndex..., in: s),
            withTemplate: ""
        )
        s = whitespacePattern.stringByReplacingMatches(
            in: s, options: [],
            range: NSRange(s.startIndex..., in: s),
            withTemplate: " "
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Array where Element == MessageHeader {
    public func clusteredBySubject() -> [SubjectCluster] {
        var byKey: [String: SubjectAccumulator] = [:]
        byKey.reserveCapacity(Swift.min(count, 512))
        for m in self {
            let normalized = SubjectNormalizer.canonical(m.subject)
            let displayKey = normalized.isEmpty ? "(no subject)" : normalized
            byKey[
                displayKey,
                default: SubjectAccumulator(
                    representative: m.subject.isEmpty ? "(no subject)" : m.subject
                )
            ].ingest(m)
        }
        return byKey.map { (key, value) in value.finish(id: key) }
    }
}

/// Per-cluster accumulator. Mirrors `SenderAccumulator` — same CoW rationale.
/// Tracks `uniqueSenderCount` inline via a `Set<String>` so the constructed
/// `SubjectCluster` doesn't have to re-scan its own messages from a view body.
struct SubjectAccumulator {
    let representative: String
    var messages: [MessageHeader] = []
    var unreadCount: Int = 0
    var mostRecent: Date = .distantPast
    var uniqueSenders: Set<String> = []

    mutating func ingest(_ m: MessageHeader) {
        messages.append(m)
        if !m.isRead { unreadCount += 1 }
        if m.date > mostRecent { mostRecent = m.date }
        uniqueSenders.insert(m.senderAddress.lowercased())
    }

    func finish(id: String) -> SubjectCluster {
        let sorted = messages.sorted { $0.date > $1.date }
        return SubjectCluster(
            id: id,
            representative: representative,
            messages: sorted,
            unreadCount: unreadCount,
            mostRecent: mostRecent,
            uniqueSenderCount: uniqueSenders.count
        )
    }
}

// MARK: Date bucketing

public enum DateBucketKind: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case last6Months = 0
    case sixMonthsToYear
    case oneToThreeYears
    case olderThan3Years

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .last6Months:       "Last 6 months"
        case .sixMonthsToYear:   "6 months – 1 year"
        case .oneToThreeYears:   "1–3 years"
        case .olderThan3Years:   "Older than 3 years"
        }
    }

    public var symbol: String {
        switch self {
        case .last6Months:       "calendar"
        case .sixMonthsToYear:   "calendar.badge.minus"
        case .oneToThreeYears:   "clock.arrow.circlepath"
        case .olderThan3Years:   "archivebox"
        }
    }

    public static func kind(for date: Date, now: Date = .now) -> DateBucketKind {
        let interval = now.timeIntervalSince(date)
        let day: TimeInterval = 86_400
        let halfYear: TimeInterval = day * 182.5
        let year: TimeInterval = day * 365
        let threeYears: TimeInterval = year * 3
        if interval < halfYear { return .last6Months }
        if interval < year     { return .sixMonthsToYear }
        if interval < threeYears { return .oneToThreeYears }
        return .olderThan3Years
    }
}

/// Tiny sender-summary used by `DateBucket.topSenders` to render the
/// "who's in this bucket" breakdown without re-grouping on every expand.
/// Carries just enough fields for the row body — no `messages` slice, so
/// it costs O(1) per entry instead of duplicating headers under each sender.
public struct DateBucketSenderSummary: Identifiable, Hashable, Sendable {
    /// Lowercased sender address; matches `Sender.id`.
    public let id: String
    public let name: String
    public let address: String
    public let messageCount: Int

    public init(id: String, name: String, address: String, messageCount: Int) {
        self.id = id
        self.name = name
        self.address = address
        self.messageCount = messageCount
    }
}

public struct DateBucket: Identifiable, Hashable, Sendable {
    /// Number of top-sender summaries each bucket precomputes. Matches the
    /// row count `SenderBreakdown` shows when a bucket is expanded.
    public static let topSenderLimit = 15

    public let kind: DateBucketKind
    public let messages: [MessageHeader]
    /// Cached unread count — see `Sender.unreadCount` for rationale.
    public let unreadCount: Int
    /// Cached newest-message date in this bucket. `nil` for an empty bucket.
    public let mostRecent: Date?
    /// Top senders by message count within this bucket, precomputed at
    /// finalize time. SwiftUI re-runs the bucket row body whenever the user
    /// toggles expansion, so doing the grouping here (once per cache miss)
    /// keeps drill-down expand/collapse cheap.
    public let topSenders: [DateBucketSenderSummary]
    /// Number of senders contributing to this bucket. When this exceeds
    /// `topSenders.count`, the breakdown view shows an "…and more" footer.
    public let distinctSenderCount: Int

    public var id: DateBucketKind { kind }
    public var messageCount: Int { messages.count }

    /// Primary init. Trusts the caller for the cached derived values —
    /// `bucketedByDate()` accumulates them in lockstep with the messages list.
    public init(
        kind: DateBucketKind,
        messages: [MessageHeader],
        unreadCount: Int,
        mostRecent: Date?,
        topSenders: [DateBucketSenderSummary] = [],
        distinctSenderCount: Int = 0
    ) {
        self.kind = kind
        self.messages = messages
        self.unreadCount = unreadCount
        self.mostRecent = mostRecent
        self.topSenders = topSenders
        self.distinctSenderCount = distinctSenderCount
    }

    /// Convenience init for tests / fixtures. Computes derived values once
    /// from `messages`.
    public init(kind: DateBucketKind, messages: [MessageHeader]) {
        var unread = 0
        var latest: Date?
        for m in messages {
            if !m.isRead { unread += 1 }
            if latest.map({ m.date > $0 }) ?? true { latest = m.date }
        }
        let (top, distinct) = DateBucket.computeTopSenders(from: messages)
        self.init(
            kind: kind,
            messages: messages,
            unreadCount: unread,
            mostRecent: latest,
            topSenders: top,
            distinctSenderCount: distinct
        )
    }

    /// Reusable top-sender summarizer. Used by the convenience init above and
    /// by `DateBucketAccumulator.finish`. Returns the top N senders by message
    /// count (ties broken by display name) plus the total distinct sender
    /// count so callers can decide whether to render an "…and more" affordance.
    static func computeTopSenders(
        from messages: [MessageHeader],
        limit: Int = DateBucket.topSenderLimit
    ) -> (top: [DateBucketSenderSummary], distinctCount: Int) {
        guard !messages.isEmpty else { return ([], 0) }
        struct Acc {
            var name: String
            var address: String
            var count: Int
        }
        var accs: [String: Acc] = [:]
        accs.reserveCapacity(Swift.min(messages.count, 128))
        for m in messages {
            let key = m.senderId
            if var existing = accs[key] {
                existing.count += 1
                // Prefer a non-empty display name if a later message provides one.
                if existing.name.isEmpty, !m.senderName.isEmpty {
                    existing.name = m.senderName
                }
                accs[key] = existing
            } else {
                accs[key] = Acc(
                    name: m.senderName,
                    address: m.senderAddress,
                    count: 1
                )
            }
        }
        let distinct = accs.count
        let sorted = accs.lazy
            .map { (key, value) in
                DateBucketSenderSummary(
                    id: key,
                    name: value.name,
                    address: value.address,
                    messageCount: value.count
                )
            }
            .sorted { lhs, rhs in
                if lhs.messageCount != rhs.messageCount {
                    return lhs.messageCount > rhs.messageCount
                }
                let lhsLabel = lhs.name.isEmpty ? lhs.address : lhs.name
                let rhsLabel = rhs.name.isEmpty ? rhs.address : rhs.name
                return lhsLabel.localizedCaseInsensitiveCompare(rhsLabel) == .orderedAscending
            }
        return (Array(sorted.prefix(limit)), distinct)
    }
}

extension Array where Element == MessageHeader {
    public func bucketedByDate(now: Date = .now) -> [DateBucket] {
        var groups: [DateBucketKind: DateBucketAccumulator] = [:]
        for m in self {
            let kind = DateBucketKind.kind(for: m.date, now: now)
            groups[kind, default: DateBucketAccumulator()].ingest(m)
        }
        return DateBucketKind.allCases.map { kind in
            groups[kind]?.finish(kind: kind) ?? DateBucket(
                kind: kind,
                messages: [],
                unreadCount: 0,
                mostRecent: nil
            )
        }
    }
}

/// Per-bucket accumulator. Same shape as `SenderAccumulator` and
/// `SubjectAccumulator`; collects `unreadCount` and `mostRecent` inline so
/// the final `DateBucket` doesn't have to re-scan.
struct DateBucketAccumulator {
    var messages: [MessageHeader] = []
    var unreadCount: Int = 0
    var mostRecent: Date?

    mutating func ingest(_ m: MessageHeader) {
        messages.append(m)
        if !m.isRead { unreadCount += 1 }
        if mostRecent.map({ m.date > $0 }) ?? true { mostRecent = m.date }
    }

    func finish(kind: DateBucketKind) -> DateBucket {
        let (top, distinct) = DateBucket.computeTopSenders(from: messages)
        return DateBucket(
            kind: kind,
            messages: messages,
            unreadCount: unreadCount,
            mostRecent: mostRecent,
            topSenders: top,
            distinctSenderCount: distinct
        )
    }
}

// MARK: - Fused single-pass grouping

/// Bundle of every derived collection `InboxStore` needs to render the three
/// list views plus its rule-evaluation gates. Produced by `groupedForDisplay`
/// in a single walk over the headers.
public struct AggregateGrouping: Sendable {
    public let allHeaders: [MessageHeader]
    public let senders: [Sender]
    public let subjectClusters: [SubjectCluster]
    public let dateBuckets: [DateBucket]
    public let transactionalIds: Set<String>

    public init(
        allHeaders: [MessageHeader],
        senders: [Sender],
        subjectClusters: [SubjectCluster],
        dateBuckets: [DateBucket],
        transactionalIds: Set<String>
    ) {
        self.allHeaders = allHeaders
        self.senders = senders
        self.subjectClusters = subjectClusters
        self.dateBuckets = dateBuckets
        self.transactionalIds = transactionalIds
    }
}

extension Array where Element == MessageHeader {
    /// Fused version of `filter + groupedBySender + clusteredBySubject +
    /// bucketedByDate + transactional-id scan`. One walk over `self`, three
    /// accumulator dictionaries built in lockstep, then finalized in O(group
    /// count) at the end.
    ///
    /// Replaces six separate passes in `InboxStore.ensureAggregateCache` —
    /// for a unified inbox of ~50k messages that's roughly 5× fewer
    /// element visits and one fifth the allocations per cache miss. SwiftUI
    /// row bodies still hit the cached aggregates, so this only fires when
    /// the input fingerprint actually changes.
    ///
    /// - Parameters:
    ///   - newslettersOnly: when `true`, skip messages where
    ///     `isLikelyNewsletter` is false. Applied inline so the filter
    ///     doesn't allocate a separate filtered array.
    ///   - now: clock used for date-bucket placement; defaults to `.now`.
    ///     Exposed for deterministic tests.
    public func groupedForDisplay(
        newslettersOnly: Bool = false,
        now: Date = .now
    ) -> AggregateGrouping {
        var senderAcc: [String: SenderAccumulator] = [:]
        var subjectAcc: [String: SubjectAccumulator] = [:]
        var bucketAcc: [DateBucketKind: DateBucketAccumulator] = [:]
        var transactionalIds: Set<String> = []
        var kept: [MessageHeader] = []
        senderAcc.reserveCapacity(Swift.min(count, 1024))
        subjectAcc.reserveCapacity(Swift.min(count, 512))
        kept.reserveCapacity(count)

        for m in self {
            if newslettersOnly && !m.isLikelyNewsletter { continue }
            kept.append(m)

            senderAcc[
                m.senderId,
                default: SenderAccumulator(address: m.senderAddress)
            ].ingest(m)

            let normalized = SubjectNormalizer.canonical(m.subject)
            let subjectKey = normalized.isEmpty ? "(no subject)" : normalized
            subjectAcc[
                subjectKey,
                default: SubjectAccumulator(
                    representative: m.subject.isEmpty ? "(no subject)" : m.subject
                )
            ].ingest(m)

            let kind = DateBucketKind.kind(for: m.date, now: now)
            bucketAcc[kind, default: DateBucketAccumulator()].ingest(m)

            if m.isLikelyTransactional { transactionalIds.insert(m.id) }
        }

        let senders = senderAcc.values.map { $0.finish() }
        let clusters = subjectAcc.map { (key, value) in value.finish(id: key) }
        let buckets = DateBucketKind.allCases.map { kind in
            bucketAcc[kind]?.finish(kind: kind)
                ?? DateBucket(kind: kind, messages: [], unreadCount: 0, mostRecent: nil)
        }

        return AggregateGrouping(
            allHeaders: kept,
            senders: senders,
            subjectClusters: clusters,
            dateBuckets: buckets,
            transactionalIds: transactionalIds
        )
    }
}
