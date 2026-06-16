import Foundation

/// Keys whose remote (iCloud-pulled) changes are routed through the
/// pending-confirm flow instead of being applied directly to local
/// `UserDefaults`. These are the surfaces an iCloud-account compromise
/// could use to:
///
/// - re-route the user's AI traffic to a different provider, change the
///   model, or inject custom instructions (`aiProvider`, `aiModel`,
///   `aiFeatureTuning.v1`)
/// - **hijack an IMAP account by rewriting its `host` field**, so the
///   next refresh sends the user's password to the attacker's server
///   (`accounts.v1`)
/// - **inject a destructive rule** that mass-deletes mail at the next
///   scheduled run or app launch (`rules.v1`)
///
/// Everything else in `CloudKVSync.allowlist` (themes, triage state,
/// safety toggles, etc.) still syncs transparently — only the keys
/// listed here require explicit per-device approval.
///
/// Naming kept singular (`SyncedSensitiveKeys`) so the AI / accounts /
/// rules call sites share one source of truth — adding a new sensitive
/// key in the future is a one-line change here plus an apply path in the
/// receiving store.
public enum SyncedSensitiveKeys {
    public static let aiProvider     = "File13.aiProvider"
    public static let aiModel        = "File13.aiModel"
    public static let aiFeatureTuning = "File13.aiFeatureTuning.v1"
    public static let accounts       = "File13.accounts.v1"
    public static let rules          = "File13.rules.v1"

    // Actions & Safety toggles. An iCloud compromise could otherwise
    // silently weaken the guard rails that make rule execution safe —
    // e.g. flipping `protectVIPsFromRules` to false, dropping
    // `undoBufferSeconds` to 0, or turning off `confirmBeforeDelete`.
    // The destructive-rule banner already gates rule *content*; these
    // gate the *runtime guard rails*.
    public static let undoBufferSeconds          = "File13.undoBufferSeconds"
    public static let confirmBeforeDelete        = "File13.confirmBeforeDelete"
    public static let confirmBeforeUnsubscribe   = "File13.confirmBeforeUnsubscribe"
    public static let dryRunMode                 = "File13.dryRunMode"
    public static let softDeleteToTrash          = "File13.softDeleteToTrash"
    public static let protectVIPsFromRules       = "File13.protectVIPsFromRules"
    public static let protectTransactionalFromRules = "File13.protectTransactionalFromRules"

    // VIP set. A synced "remove from VIPs" or "add to excluded" change
    // bypasses VIP-protected-from-rules. The merge function previously
    // unioned remote additions — that lets an attacker exclude senders
    // from VIP-protection silently.
    public static let vipSenders     = "File13.vipSenders.v1"

    // Replied-messages map. `VIPDetector`'s reply path promotes a
    // sender to VIP after >=2 replies — a synced "user replied to
    // them" record forged from another device can elevate an attacker
    // to VIP. Gated on apply.
    public static let repliedMessages = "File13.repliedMessages.v1"

    // Sender categories. Category-conditional rules can route differently
    // when categories flip (e.g. `promotional → personal` exempts a
    // sender from a "delete promotional" rule). Lower-impact than VIPs /
    // replied because the user already reviews categories in the Activity
    // panel, but still worth gating.
    public static let senderCategories = "File13.senderCategories.v1"

    public static let all: Set<String> = [
        aiProvider, aiModel, aiFeatureTuning, accounts, rules,
        undoBufferSeconds, confirmBeforeDelete, confirmBeforeUnsubscribe,
        dryRunMode, softDeleteToTrash, protectVIPsFromRules,
        protectTransactionalFromRules,
        vipSenders, repliedMessages, senderCategories
    ]

    public static let aiKeys: Set<String> = [aiProvider, aiModel, aiFeatureTuning]
    public static let accountKeys: Set<String> = [accounts]
    public static let ruleKeys: Set<String> = [rules]

    public static let safetyKeys: Set<String> = [
        undoBufferSeconds, confirmBeforeDelete, confirmBeforeUnsubscribe,
        dryRunMode, softDeleteToTrash, protectVIPsFromRules,
        protectTransactionalFromRules
    ]
    public static let vipKeys: Set<String> = [vipSenders]
    public static let repliedKeys: Set<String> = [repliedMessages]
    public static let categoryKeys: Set<String> = [senderCategories]
}

/// Back-compat alias for the previous name. Remove once the call sites are
/// migrated; kept now so the store's internal references compile during
/// the rename.
@available(*, deprecated, renamed: "SyncedSensitiveKeys")
public enum SyncedAISensitiveKeys {
    public static var keys: Set<String> { SyncedSensitiveKeys.aiKeys }
}

/// Records iCloud-delivered changes to AI-sensitive settings until the
/// user explicitly approves them on this Mac. Stored in App Group
/// `UserDefaults` under a key that is **not** in `CloudKVSync.allowlist`
/// so the pending queue stays per-device.
///
/// Flow:
/// 1. `CloudKVSyncMirror.pull` for an AI-sensitive key sees a remote
///    value that differs from local — it calls `stash(...)` instead of
///    writing to defaults.
/// 2. UI (the AI settings tab + the AI-action sheets) reads
///    `loadAll(...)` to detect pending changes and surfaces a banner.
/// 3. The user either **applies** (the stashed values get written via
///    `SettingsStore`'s setters, triggering observation + remote re-push)
///    or **discards** (the local value is marked dirty for re-push, so
///    other devices roll back to it).
///
/// `@MainActor` so the `SharedDefaults.suite` default-parameter values
/// resolve without crossing isolation boundaries — same pattern
/// `CloudKVSync` uses.
/// Back-compat type alias for the previous AI-only name. Remove once the
/// call sites are migrated; kept now so this rename + extension can land
/// in one change.
@available(*, deprecated, renamed: "PendingSyncChangesStore")
public typealias PendingAIChangesStore = PendingSyncChangesStore

@MainActor
public enum PendingSyncChangesStore {
    /// Storage key kept as the original `aiTuning.pendingChanges.v1` so
    /// users who already had pending AI changes don't lose them when this
    /// type is generalized. The store now holds pending entries for
    /// accounts and rules too, but they're keyed by their UserDefaults
    /// key string so cross-talk is impossible.
    private static let storageKey = "File13.aiTuning.pendingChanges.v1"

    /// One pending change. The remote value is stored as plist data so
    /// any UserDefaults-compatible payload (String, Int, Data, Bool…)
    /// round-trips faithfully.
    public struct Pending: Codable, Equatable, Sendable {
        public let key: String
        public let encodedRemote: Data?
        public let receivedAt: Date

        public init(key: String, encodedRemote: Data?, receivedAt: Date) {
            self.key = key
            self.encodedRemote = encodedRemote
            self.receivedAt = receivedAt
        }

        /// Decode the stashed value back to a UserDefaults-compatible Any.
        /// Returns `nil` when the remote payload was nil (i.e. the
        /// remote device cleared the key — pending change is "delete").
        public func decodedRemote() -> Any? {
            guard let encodedRemote else { return nil }
            return try? PropertyListSerialization.propertyList(
                from: encodedRemote,
                format: nil
            )
        }
    }

    public static func stash(key: String, remote: Any?, defaults: UserDefaults = SharedDefaults.suite) {
        guard SyncedSensitiveKeys.all.contains(key) else { return }
        var current = loadAll(defaults: defaults)
        let data: Data?
        if let remote {
            data = try? PropertyListSerialization.data(
                fromPropertyList: remote,
                format: .binary,
                options: 0
            )
        } else {
            data = nil
        }
        current[key] = Pending(key: key, encodedRemote: data, receivedAt: .now)
        save(current, defaults: defaults)
    }

    public static func loadAll(defaults: UserDefaults = SharedDefaults.suite) -> [String: Pending] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Pending].self, from: data) else {
            return [:]
        }
        return decoded
    }

    public static func hasPending(defaults: UserDefaults = SharedDefaults.suite) -> Bool {
        defaults.data(forKey: storageKey) != nil
    }

    public static func clear(_ key: String, defaults: UserDefaults = SharedDefaults.suite) {
        var current = loadAll(defaults: defaults)
        current.removeValue(forKey: key)
        save(current, defaults: defaults)
    }

    public static func clearAll(defaults: UserDefaults = SharedDefaults.suite) {
        defaults.removeObject(forKey: storageKey)
    }

    private static func save(_ items: [String: Pending], defaults: UserDefaults) {
        if items.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

public extension Notification.Name {
    /// Posted whenever any sensitive synced key is stashed or removed. UI
    /// banners (AI, accounts, rules) observe this and re-filter to their
    /// own keys-of-interest set without polling.
    static let pendingSyncChangesUpdated = Notification.Name("File13.pendingSyncChangesUpdated")

    /// Back-compat alias for the previous AI-only notification name.
    @available(*, deprecated, renamed: "pendingSyncChangesUpdated")
    static var pendingAIChangesUpdated: Notification.Name { .pendingSyncChangesUpdated }
}
