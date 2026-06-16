import Foundation

public struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) {
        self.state = seed == 0 ? 0xdead_beef_cafe_babe : seed
    }
    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

public enum MockInbox {
    public static let accountId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let accountAddress = "you@example.com"

    public static func generateHeaders(seed: UInt64 = 42) -> [MessageHeader] {
        var rng = SeededRNG(seed: seed)
        var out: [MessageHeader] = []
        for spec in MockSpecs.all {
            let count = Int.random(in: spec.range, using: &rng)
            for i in 0..<count {
                let daysBack = Int.random(in: 0...365 * 3, using: &rng)
                let date = Date().addingTimeInterval(-Double(daysBack) * 86400)
                let subject = spec.subjects.randomElement(using: &rng) ?? "Update"
                let isRead = Int.random(in: 0...10, using: &rng) > 1   // ~80% read
                out.append(MessageHeader(
                    rawMessageId: "\(spec.address)#\(i)",
                    uid: nil,
                    senderName: spec.name,
                    senderAddress: spec.address,
                    subject: subject,
                    date: date,
                    accountId: accountId,
                    isRead: isRead
                ))
            }
        }
        return out
    }

    public static func generate(seed: UInt64 = 42) -> [Sender] {
        generateHeaders(seed: seed).groupedBySender()
    }

    /// Synthetic large-fixture generator for perf regression tests. Built
    /// on top of the same `MockSpecs.all` shape, but instead of one
    /// sender per spec it tiles the spec list and appends a numeric
    /// suffix to each address so the result is a realistic spread of
    /// many senders × many messages instead of one giant sender.
    ///
    /// Returns *approximately* `targetCount` headers — the per-sender
    /// counts come from `spec.range` so the exact total varies with
    /// the seed. Tests should write generous bounds (e.g., assert ≤
    /// 500ms for a 50k fixture, not exactly 50k).
    ///
    /// **Not** for UI fixtures or demo data — the suffixed addresses
    /// (`messages-noreply@linkedin.com#7`) would read as junk to a
    /// human. Perf-test-only.
    public static func generateScaled(targetCount: Int, seed: UInt64 = 42) -> [MessageHeader] {
        guard targetCount > 0 else { return [] }
        var rng = SeededRNG(seed: seed)
        var out: [MessageHeader] = []
        out.reserveCapacity(targetCount)
        // Walk the spec list repeatedly, each pass producing one synthetic
        // sender per spec. Stop as soon as we cross the target. The mid-loop
        // break is fine for perf-test purposes — exact totals don't matter.
        var pass = 0
        outer: while out.count < targetCount {
            for spec in MockSpecs.all {
                let perSenderCount = Int.random(in: spec.range, using: &rng)
                let suffixedAddress = "\(spec.address)#\(pass)"
                for i in 0..<perSenderCount {
                    if out.count >= targetCount { break outer }
                    let daysBack = Int.random(in: 0...365 * 3, using: &rng)
                    let date = Date().addingTimeInterval(-Double(daysBack) * 86400)
                    let subject = spec.subjects.randomElement(using: &rng) ?? "Update"
                    let isRead = Int.random(in: 0...10, using: &rng) > 1
                    out.append(MessageHeader(
                        rawMessageId: "\(suffixedAddress)#\(i)",
                        uid: nil,
                        senderName: "\(spec.name) #\(pass)",
                        senderAddress: suffixedAddress,
                        subject: subject,
                        date: date,
                        accountId: accountId,
                        isRead: isRead
                    ))
                }
            }
            pass += 1
        }
        return out
    }
}

private struct MockSpec {
    let name: String
    let address: String
    let range: ClosedRange<Int>
    let subjects: [String]
}

private enum MockSpecs {
    static let all: [MockSpec] = [
        .init(name: "LinkedIn", address: "messages-noreply@linkedin.com", range: 800...1200,
              subjects: ["You have a new connection request", "Job alert: Senior Engineer", "Top jobs picked for you", "Someone viewed your profile"]),
        .init(name: "GitHub", address: "noreply@github.com", range: 600...900,
              subjects: ["[acme/api] PR opened", "[acme/web] Issue #1234", "Security alert for repository", "[acme/api] Build failed"]),
        .init(name: "Medium Daily Digest", address: "noreply@medium.com", range: 400...600,
              subjects: ["Today's top picks for you", "Stories you might like", "Trending in Programming"]),
        .init(name: "Stripe", address: "no-reply@stripe.com", range: 200...400,
              subjects: ["Payment received", "Invoice ready", "Weekly business summary"]),
        .init(name: "Apple", address: "no_reply@email.apple.com", range: 150...300,
              subjects: ["Your receipt from Apple", "App Store Connect — TestFlight", "Your subscription is renewing"]),
        .init(name: "Costco", address: "Costco@costco.com", range: 100...250,
              subjects: ["Members get more savings this week", "Final hours: Member Only Savings", "Your Executive Membership rewards"]),
        .init(name: "Doordash", address: "no-reply@doordash.com", range: 80...200,
              subjects: ["Your order receipt", "Get $10 off your next order", "Rate your recent delivery"]),
        .init(name: "The New York Times", address: "nytdirect@nytimes.com", range: 100...180,
              subjects: ["Morning Briefing", "Breaking News", "The Daily"]),
        .init(name: "Substack", address: "no-reply@substack.com", range: 60...140,
              subjects: ["New post from your subscriptions", "Weekly digest", "Recommended for you"]),
        .init(name: "Notion", address: "team@notion.so", range: 40...90,
              subjects: ["Weekly product updates", "What's new in Notion", "You were mentioned in a page"]),
        .init(name: "Calendly", address: "no-reply@calendly.com", range: 30...80,
              subjects: ["New event scheduled", "Reminder: meeting tomorrow", "Event canceled"]),
        .init(name: "Zoom", address: "no-reply@zoom.us", range: 30...70,
              subjects: ["Cloud recording is available", "Meeting summary", "Your account update"]),
        .init(name: "1Password", address: "support@1password.com", range: 5...20,
              subjects: ["Watchtower report", "New sign-in to your account", "Your subscription receipt"]),
        .init(name: "Hacker Newsletter", address: "kale@hackernewsletter.com", range: 20...60,
              subjects: ["Hacker Newsletter Issue #720", "Hacker Newsletter Issue #721"]),
        .init(name: "AWS Marketing", address: "aws-marketing-email-replies@amazon.com", range: 40...110,
              subjects: ["What's new in AWS this week", "Reminder: re:Invent registration", "AWS training opportunities"]),
        .init(name: "Nest", address: "noreply@nest.com", range: 10...30,
              subjects: ["Monthly home report", "Your camera saw something", "Software update available"]),
        .init(name: "United Airlines", address: "Receipts@united.com", range: 5...25,
              subjects: ["Your flight receipt", "Check in for your trip", "MileagePlus statement"]),
        .init(name: "Patagonia", address: "patagonia@e.patagonia.com", range: 30...80,
              subjects: ["New arrivals you'll love", "Worn Wear: gear with a story", "Final sale starts now"]),
        .init(name: "Mom", address: "mom@familymail.example", range: 1...8,
              subjects: ["Photos from the weekend", "Recipe", "Call me when you can"]),
        .init(name: "Your Bank", address: "alerts@yourbank.example", range: 100...250,
              subjects: ["Statement available", "Large transaction alert", "Direct deposit posted"]),
    ]
}
