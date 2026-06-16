import Foundation
import Observation

/// Persistent store for VIP senders. Three independent sets so the user's manual pins survive
/// a re-detection (and the user's manual exclusions don't get re-added by it):
///
/// - `autoDetected` — populated by `VIPDetector.detect`. Replaced on each detection run.
/// - `pinned` — manually added by the user; never cleared by detection.
/// - `excluded` — manually removed by the user; suppressed even if detection re-adds them.
///
/// The "effective" VIP set is `(autoDetected − excluded) ∪ pinned`.
@Observable
@MainActor
public final class VIPStore {
    private static let storageKey = "File13.vipSenders.v1"

    public private(set) var autoDetected: Set<String> = []
    public private(set) var pinned: Set<String> = []
    public private(set) var excluded: Set<String> = []
    /// Last detection run timestamp, surfaced by the activity dashboard.
    public private(set) var lastDetectionAt: Date?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = SharedDefaults.suite) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(StoredState.self, from: data) {
            self.autoDetected = decoded.autoDetected
            self.pinned = decoded.pinned
            self.excluded = decoded.excluded
            self.lastDetectionAt = decoded.lastDetectionAt
        }
    }

    /// The set callers should use for "is this a VIP?" decisions.
    public var effective: Set<String> {
        autoDetected.subtracting(excluded).union(pinned)
    }

    public func isVIP(senderId: String) -> Bool {
        effective.contains(senderId.lowercased())
    }

    /// Mark a sender as VIP regardless of detection. Removes any prior exclusion so the user's
    /// intent ("yes, this is a VIP") wins.
    public func pin(senderId: String) {
        let id = senderId.lowercased()
        pinned.insert(id)
        excluded.remove(id)
        persist()
    }

    /// Reverse of `pin`. If the sender was auto-detected, we add to `excluded` so the next
    /// detection run respects the user's intent. If the sender was only pinned (not auto),
    /// we just drop the pin.
    public func unpin(senderId: String) {
        let id = senderId.lowercased()
        if pinned.contains(id) {
            pinned.remove(id)
        }
        if autoDetected.contains(id) {
            excluded.insert(id)
        }
        persist()
    }

    /// Replace the auto-detected set after a detection run. Pins/exclusions are unaffected.
    public func updateAutoDetected(_ ids: Set<String>) {
        autoDetected = ids
        lastDetectionAt = .now
        persist()
    }

    public func clearAll() {
        autoDetected.removeAll()
        pinned.removeAll()
        excluded.removeAll()
        lastDetectionAt = nil
        persist()
    }

    /// Apply a JSON-encoded VIP state that arrived via iCloud sync, after
    /// the user approved it via `PendingVIPChangesBanner`. `vipSenders.v1`
    /// is in the `SyncedSensitiveKeys` set because a remote change can
    /// silently broaden the `excluded` set (suppressing VIP-protected-from-
    /// rules for those senders) or drop entries from `pinned`. The merge
    /// path that previously unioned these values lived in `CloudKVMerge`;
    /// gating on explicit consent here is the security boundary.
    ///
    /// Writes through the same persist path as user-driven edits so the
    /// accepted state pushes back to iCloud on the next flush — matches
    /// what `AccountStore.applySyncedAccounts` / `RuleStore.applySyncedRules`
    /// do for their sensitive payloads.
    public func applySyncedState(from data: Data) {
        guard let decoded = try? JSONDecoder().decode(StoredState.self, from: data) else { return }
        autoDetected = decoded.autoDetected
        pinned = decoded.pinned
        excluded = decoded.excluded
        lastDetectionAt = decoded.lastDetectionAt
        persist()
    }

    private func persist() {
        let state = StoredState(
            autoDetected: autoDetected,
            pinned: pinned,
            excluded: excluded,
            lastDetectionAt: lastDetectionAt
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.storageKey)
            CloudKVSync.markDirty(Self.storageKey, defaults: defaults)
        }
    }

    private struct StoredState: Codable {
        var autoDetected: Set<String>
        var pinned: Set<String>
        var excluded: Set<String>
        var lastDetectionAt: Date?
    }
}
