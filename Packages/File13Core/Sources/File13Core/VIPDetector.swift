import Foundation

/// Heuristic VIP classifier — surfaces senders the user actually engages with so the activity
/// dashboard, sender rows, and (later) rule evaluator can treat them carefully. Pure metadata,
/// no AI; relies on the existing read/reply data plus AI categories when available.
public enum VIPDetector {
    /// Tunables. Kept here rather than scattered through call sites so it's obvious where the
    /// VIP-ness threshold lives.
    public static let minimumVolume: Int = 3
    /// "You replied at least this many times to this sender" — strongest engagement signal.
    public static let replyVIPMinReplies: Int = 2
    /// Read-rate fallback when there's no reply data. Higher bar because read-rate is noisier.
    public static let readVIPMinVolume: Int = 5
    public static let readVIPMinReadRate: Double = 0.9

    /// Categories that are excluded from VIP regardless of engagement — broadcast-y by nature
    /// and a VIP designation there would be misleading.
    public static let excludedCategories: Set<SenderCategory> = [
        .news, .promotional, .notifications, .social
    ]

    /// Run detection over the given senders. Returns the set of sender ids the heuristic
    /// considers VIPs *based on engagement data alone*. Callers union this with the user's
    /// pinned overrides via `VIPStore` to get the effective list.
    public static func detect(
        senders: [Sender],
        repliedMessageIds: Set<String>,
        categoryFor: (String) -> SenderCategory? = { _ in nil }
    ) -> Set<String> {
        var ids: Set<String> = []
        for sender in senders where isVIP(
            sender: sender,
            repliedMessageIds: repliedMessageIds,
            category: categoryFor(sender.id)
        ) {
            ids.insert(sender.id)
        }
        return ids
    }

    /// Per-sender check. Two paths:
    /// 1. **Reply path** — if the user has replied to this sender ≥ `replyVIPMinReplies` times
    ///    and the volume is non-trivial. Cleanest signal we can compute.
    /// 2. **Read-rate path** — fallback for senders with no reply data at all (reply detection
    ///    not yet run, or it's a sender you don't reply to but always read). Bar is set high
    ///    because read-rate has more false positives than reply-rate.
    public static func isVIP(
        sender: Sender,
        repliedMessageIds: Set<String>,
        category: SenderCategory?
    ) -> Bool {
        // Disqualifiers first — broadcast-y senders are never VIPs no matter how engaged.
        if sender.isLikelyNewsletter { return false }
        if let category, excludedCategories.contains(category) { return false }
        guard sender.messageCount >= minimumVolume else { return false }

        // Reply path
        let replyCount = sender.messages.lazy.filter {
            repliedMessageIds.contains($0.rawMessageId)
        }.count
        if replyCount >= replyVIPMinReplies { return true }

        // Read-rate fallback
        guard sender.messageCount >= readVIPMinVolume else { return false }
        let readCount = sender.messageCount - sender.unreadCount
        let readRate = Double(readCount) / Double(sender.messageCount)
        return readRate >= readVIPMinReadRate
    }
}
