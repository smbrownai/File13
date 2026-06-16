import Foundation
import Observation

/// Persistent map from account id → set of `rawMessageId`s the user has replied to.
@Observable
@MainActor
public final class RepliedMessagesStore {
    private static let storageKey = "File13.repliedMessages.v1"

    public private(set) var perAccount: [UUID: Set<String>] = [:]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = SharedDefaults.suite) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([UUID: Set<String>].self, from: data) {
            self.perAccount = decoded
        }
    }

    public func replies(forAccountId id: UUID) -> Set<String> {
        perAccount[id] ?? []
    }

    public func replace(_ replies: Set<String>, forAccountId id: UUID) {
        if replies.isEmpty {
            perAccount.removeValue(forKey: id)
        } else {
            perAccount[id] = replies
        }
        persist()
    }

    public func clear(accountId: UUID) {
        guard perAccount.removeValue(forKey: accountId) != nil else { return }
        persist()
    }

    public func clearAll() {
        perAccount.removeAll()
        persist()
    }

    /// Apply a JSON-encoded replied-messages map that arrived via iCloud
    /// sync, after the user approved it via
    /// `PendingRepliedMessagesChangesBanner`. `repliedMessages.v1` is
    /// in `SyncedSensitiveKeys` because `VIPDetector`'s reply path
    /// auto-promotes a sender to VIP after >=2 replies — a forged
    /// "user replied to them" record can elevate an attacker to VIP.
    /// Gating on explicit consent here is the security boundary.
    public func applySyncedState(from data: Data) {
        guard let decoded = try? JSONDecoder().decode([UUID: Set<String>].self, from: data) else { return }
        perAccount = decoded
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(perAccount) else { return }
        defaults.set(data, forKey: Self.storageKey)
        CloudKVSync.markDirty(Self.storageKey, defaults: defaults)
    }
}
