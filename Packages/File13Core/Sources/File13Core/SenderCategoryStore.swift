import Foundation
import Observation

/// Persisted map from sender id (lowercased address) → AI-assigned `SenderCategory`. The map is
/// authoritative — if a sender isn't in here, it hasn't been categorized yet.
@Observable
@MainActor
public final class SenderCategoryStore {
    private static let storageKey = "File13.senderCategories.v1"

    public private(set) var categories: [String: SenderCategory] = [:]
    /// ISO 8601 timestamp of the last batch categorization run, for the "categorized N senders
    /// {time ago}" disclosure in the activity dashboard.
    public private(set) var lastRunAt: Date?
    private static let lastRunKey = "File13.senderCategories.v1.lastRunAt"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = SharedDefaults.suite) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: SenderCategory].self, from: data) {
            self.categories = decoded
        }
        self.lastRunAt = defaults.object(forKey: Self.lastRunKey) as? Date
    }

    public func category(for senderId: String) -> SenderCategory? {
        categories[senderId.lowercased()]
    }

    /// Apply a single sender's categorization. Used when the user manually overrides the AI
    /// (e.g. picks a different category from a context menu).
    public func set(_ category: SenderCategory, for senderId: String) {
        categories[senderId.lowercased()] = category
        persist()
    }

    /// Bulk apply — used by the LLM categorizer after a batch completes.
    public func merge(_ map: [String: SenderCategory], runAt: Date = .now) {
        for (key, value) in map { categories[key.lowercased()] = value }
        lastRunAt = runAt
        persist()
        defaults.set(runAt, forKey: Self.lastRunKey)
        CloudKVSync.markDirty(Self.lastRunKey, defaults: defaults)
    }

    /// Forget a sender's category. Useful when the address comes back with very different
    /// content and we want the next categorize pass to re-evaluate.
    public func clear(senderId: String) {
        categories.removeValue(forKey: senderId.lowercased())
        persist()
    }

    public func clearAll() {
        categories.removeAll()
        lastRunAt = nil
        persist()
        defaults.removeObject(forKey: Self.lastRunKey)
    }

    /// Sender ids that haven't been categorized yet. Used by the activity dashboard to drive
    /// the "categorize uncategorized" CTA without re-running on senders we already labeled.
    public func uncategorized(amongSenderIds ids: [String]) -> [String] {
        ids.filter { categories[$0.lowercased()] == nil }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(categories) else { return }
        defaults.set(data, forKey: Self.storageKey)
        CloudKVSync.markDirty(Self.storageKey, defaults: defaults)
    }

    /// Apply a JSON-encoded category map that arrived via iCloud sync,
    /// after the user has approved the change via the pending-sync
    /// banner. `senderCategories.v1` is in `SyncedSensitiveKeys` because
    /// category-conditional rules can be routed differently if categories
    /// are flipped (e.g., promotional → personal).
    public func applySyncedState(from data: Data) {
        guard let decoded = try? JSONDecoder().decode([String: SenderCategory].self, from: data) else { return }
        self.categories = decoded
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Public accessor for the snapshot diff in the pending-sync banner —
    /// the banner needs to compute "added / changed / removed" against the
    /// current state without going through the live `categories` property
    /// (whose observation would trigger view churn during the diff render).
    public static func decodeSnapshot(_ data: Data) -> [String: SenderCategory]? {
        try? JSONDecoder().decode([String: SenderCategory].self, from: data)
    }
}
