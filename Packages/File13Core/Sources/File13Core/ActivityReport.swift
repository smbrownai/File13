import Foundation

/// Pre-computed stats about a set of `MessageHeader`s, used by the Activity dashboard. Built
/// from a single pass over the headers so the view doesn't repeat work per chart.
public struct ActivityReport: Sendable {
    // MARK: - Top-line summary

    public let totalMessages: Int
    public let readMessages: Int
    public let uniqueSenders: Int
    /// Earliest and latest message dates in the input. `nil` when the input is empty.
    public let dateRange: ClosedRange<Date>?

    // MARK: - Distribution buckets

    /// One entry per calendar day in the report window (last 30 calendar days, oldest first).
    public let volumeByDay: [DayBucket]
    /// 24 entries — index = hour (0–23, local time).
    public let volumeByHour: [HourBucket]
    /// 7 entries — `weekday` matches `Calendar.component(.weekday)` (1 = Sunday, 7 = Saturday).
    public let volumeByWeekday: [WeekdayBucket]

    // MARK: - Sender highlights

    public let topSendersByVolume: [SenderStat]
    public let topSendersByReadRate: [SenderStat]
    public let ghostSenders: [SenderStat]
    public let dormantSenders: [SenderStat]
    public let topRepliedSenders: [SenderStat]
    public let totalRepliedToCount: Int

    // MARK: - Mail-shape breakdown

    public let personalCount: Int
    public let broadcastCount: Int
    public let transactionalCount: Int
    public let otherCount: Int

    // MARK: - Convenience

    public var readRate: Double {
        guard totalMessages > 0 else { return 0 }
        return Double(readMessages) / Double(totalMessages)
    }

    public var isEmpty: Bool { totalMessages == 0 }

    public init(totalMessages: Int, readMessages: Int, uniqueSenders: Int,
                dateRange: ClosedRange<Date>?,
                volumeByDay: [DayBucket], volumeByHour: [HourBucket], volumeByWeekday: [WeekdayBucket],
                topSendersByVolume: [SenderStat], topSendersByReadRate: [SenderStat],
                ghostSenders: [SenderStat], dormantSenders: [SenderStat],
                topRepliedSenders: [SenderStat], totalRepliedToCount: Int,
                personalCount: Int, broadcastCount: Int, transactionalCount: Int, otherCount: Int) {
        self.totalMessages = totalMessages
        self.readMessages = readMessages
        self.uniqueSenders = uniqueSenders
        self.dateRange = dateRange
        self.volumeByDay = volumeByDay
        self.volumeByHour = volumeByHour
        self.volumeByWeekday = volumeByWeekday
        self.topSendersByVolume = topSendersByVolume
        self.topSendersByReadRate = topSendersByReadRate
        self.ghostSenders = ghostSenders
        self.dormantSenders = dormantSenders
        self.topRepliedSenders = topRepliedSenders
        self.totalRepliedToCount = totalRepliedToCount
        self.personalCount = personalCount
        self.broadcastCount = broadcastCount
        self.transactionalCount = transactionalCount
        self.otherCount = otherCount
    }

    public static let empty = ActivityReport(
        totalMessages: 0, readMessages: 0, uniqueSenders: 0,
        dateRange: nil,
        volumeByDay: [], volumeByHour: [], volumeByWeekday: [],
        topSendersByVolume: [], topSendersByReadRate: [],
        ghostSenders: [], dormantSenders: [],
        topRepliedSenders: [], totalRepliedToCount: 0,
        personalCount: 0, broadcastCount: 0, transactionalCount: 0, otherCount: 0
    )

    // MARK: - Nested types

    public struct DayBucket: Identifiable, Hashable, Sendable {
        public let date: Date
        public let count: Int
        public let readCount: Int
        public var id: Date { date }
        public init(date: Date, count: Int, readCount: Int) {
            self.date = date; self.count = count; self.readCount = readCount
        }
    }

    public struct HourBucket: Identifiable, Hashable, Sendable {
        public let hour: Int
        public let count: Int
        public var id: Int { hour }
        public init(hour: Int, count: Int) { self.hour = hour; self.count = count }
    }

    public struct WeekdayBucket: Identifiable, Hashable, Sendable {
        public let weekday: Int
        public let count: Int
        public var id: Int { weekday }
        public init(weekday: Int, count: Int) { self.weekday = weekday; self.count = count }
    }

    public struct SenderStat: Identifiable, Hashable, Sendable {
        public let address: String
        public let displayName: String
        public let messageCount: Int
        public let readCount: Int
        public let mostRecent: Date
        public let repliedCount: Int
        public var id: String { address }
        public var readRate: Double {
            guard messageCount > 0 else { return 0 }
            return Double(readCount) / Double(messageCount)
        }
        public var replyRate: Double {
            guard messageCount > 0 else { return 0 }
            return Double(repliedCount) / Double(messageCount)
        }
        public init(address: String, displayName: String, messageCount: Int, readCount: Int, mostRecent: Date, repliedCount: Int) {
            self.address = address
            self.displayName = displayName
            self.messageCount = messageCount
            self.readCount = readCount
            self.mostRecent = mostRecent
            self.repliedCount = repliedCount
        }
    }

    // MARK: - Tunables

    private static let topSenderListCap = 8
    private static let readRateMinVolume = 5
    private static let ghostMaxReadRate = 0.05
    private static let ghostMinVolume = 5
    private static let dormantThresholdDays = 90
    private static let dayWindowDays = 30
}

extension ActivityReport {
    /// Single-pass compute over the headers. `now` is injected for testability.
    public static func compute(
        from headers: [MessageHeader],
        repliedMessageIds: Set<String> = [],
        now: Date = .now
    ) -> ActivityReport {
        guard !headers.isEmpty else { return .empty }

        let calendar = Calendar.current
        let windowStart = calendar.date(byAdding: .day, value: -(dayWindowDays - 1), to: calendar.startOfDay(for: now))!
        let dormantCutoff = calendar.date(byAdding: .day, value: -dormantThresholdDays, to: now) ?? .distantPast

        var earliest = Date.distantFuture
        var latest = Date.distantPast
        var readCount = 0
        var totalReplied = 0

        var dayCounts: [Date: (count: Int, read: Int)] = [:]
        var hourCounts = [Int](repeating: 0, count: 24)
        var weekdayCounts = [Int](repeating: 0, count: 8)

        struct SenderAccum {
            var displayName: String
            var address: String
            var count: Int = 0
            var read: Int = 0
            var replied: Int = 0
            var mostRecent: Date = .distantPast
        }
        var senderById: [String: SenderAccum] = [:]

        var personal = 0
        var broadcast = 0
        var transactional = 0
        var other = 0

        for h in headers {
            if h.date < earliest { earliest = h.date }
            if h.date > latest { latest = h.date }
            if h.isRead { readCount += 1 }

            let day = calendar.startOfDay(for: h.date)
            if day >= windowStart && day <= calendar.startOfDay(for: now) {
                var bucket = dayCounts[day, default: (0, 0)]
                bucket.count += 1
                if h.isRead { bucket.read += 1 }
                dayCounts[day] = bucket
            }

            let hour = calendar.component(.hour, from: h.date)
            if (0..<24).contains(hour) { hourCounts[hour] += 1 }
            let weekday = calendar.component(.weekday, from: h.date)
            if (1...7).contains(weekday) { weekdayCounts[weekday] += 1 }

            let key = h.senderAddress.lowercased()
            var accum = senderById[key] ?? SenderAccum(
                displayName: h.senderName.isEmpty ? h.senderAddress : h.senderName,
                address: h.senderAddress
            )
            if accum.displayName.isEmpty, !h.senderName.isEmpty { accum.displayName = h.senderName }
            accum.count += 1
            if h.isRead { accum.read += 1 }
            if repliedMessageIds.contains(h.rawMessageId) {
                accum.replied += 1
                totalReplied += 1
            }
            if h.date > accum.mostRecent { accum.mostRecent = h.date }
            senderById[key] = accum

            if h.isLikelyTransactional {
                transactional += 1
            } else if h.isLikelyNewsletter {
                broadcast += 1
            } else if h.looksPersonal {
                personal += 1
            } else {
                other += 1
            }
        }

        var volumeByDay: [DayBucket] = []
        volumeByDay.reserveCapacity(dayWindowDays)
        for offset in 0..<dayWindowDays {
            let day = calendar.date(byAdding: .day, value: offset, to: windowStart) ?? windowStart
            let entry = dayCounts[day] ?? (0, 0)
            volumeByDay.append(DayBucket(date: day, count: entry.count, readCount: entry.read))
        }

        let volumeByHour = (0..<24).map { HourBucket(hour: $0, count: hourCounts[$0]) }
        let volumeByWeekday = (1...7).map { WeekdayBucket(weekday: $0, count: weekdayCounts[$0]) }

        let allSenders = senderById.values.map { accum in
            SenderStat(
                address: accum.address,
                displayName: accum.displayName,
                messageCount: accum.count,
                readCount: accum.read,
                mostRecent: accum.mostRecent,
                repliedCount: accum.replied
            )
        }

        let topByVolume = allSenders
            .sorted { $0.messageCount > $1.messageCount }
            .prefix(topSenderListCap)

        let topByReadRate = allSenders
            .lazy
            .filter { $0.messageCount >= readRateMinVolume }
            .sorted { lhs, rhs in
                if lhs.readRate != rhs.readRate { return lhs.readRate > rhs.readRate }
                return lhs.messageCount > rhs.messageCount
            }
            .prefix(topSenderListCap)

        let ghosts = allSenders
            .lazy
            .filter { $0.messageCount >= ghostMinVolume && $0.readRate <= ghostMaxReadRate }
            .sorted { $0.messageCount > $1.messageCount }
            .prefix(topSenderListCap)

        let dormant = allSenders
            .lazy
            .filter { $0.mostRecent < dormantCutoff }
            .sorted { $0.messageCount > $1.messageCount }
            .prefix(topSenderListCap)

        let topReplied = allSenders
            .lazy
            .filter { $0.repliedCount > 0 }
            .sorted { lhs, rhs in
                if lhs.repliedCount != rhs.repliedCount { return lhs.repliedCount > rhs.repliedCount }
                return lhs.replyRate > rhs.replyRate
            }
            .prefix(topSenderListCap)

        return ActivityReport(
            totalMessages: headers.count,
            readMessages: readCount,
            uniqueSenders: senderById.count,
            dateRange: earliest <= latest ? earliest...latest : nil,
            volumeByDay: volumeByDay,
            volumeByHour: volumeByHour,
            volumeByWeekday: volumeByWeekday,
            topSendersByVolume: Array(topByVolume),
            topSendersByReadRate: Array(topByReadRate),
            ghostSenders: Array(ghosts),
            dormantSenders: Array(dormant),
            topRepliedSenders: Array(topReplied),
            totalRepliedToCount: totalReplied,
            personalCount: personal,
            broadcastCount: broadcast,
            transactionalCount: transactional,
            otherCount: other
        )
    }
}
