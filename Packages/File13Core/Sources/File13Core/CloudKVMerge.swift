import Foundation

/// Conflict resolution for the non-sensitive, multi-entry stores that live
/// in `NSUbiquitousKeyValueStore`. By default the iCloud KV bridge in
/// `CloudKVSyncMirror` does last-writer-wins — when a remote change lands,
/// the mirror overwrites the local value wholesale. That loses entries when
/// two devices edit the same store between syncs (e.g. each adds a sender
/// to VIPs, or each accumulates dismissed suggestions).
///
/// This module gives the mirror a per-key merge function. The rules:
///
/// - **Sets** (`dismissedSuggestions`) → pure union. Two devices each adding
///   never lose data.
/// - **Dictionaries of values** (`senderCategories`) → union of disjoint
///   keys, remote-wins on overlapping keys. Disjoint additions are kept;
///   for the same sender categorized differently on two devices, we trust
///   the most recently-pushed remote (matches NSUbiquitousKeyValueStore's
///   own last-writer-wins for non-merged keys).
/// - **Dictionaries of sets** (`repliedMessages`) → per-key set union.
/// - **VIP triple** (`vipSenders`) → `pinned` and `excluded` are pure
///   unions; the `(autoDetected, lastDetectionAt)` pair is taken as a unit
///   from whichever device ran detection more recently.
/// - **Standalone dates** (`senderCategories.v1.lastRunAt`) → max.
///
/// **Note (2026-05-16):** `senderCategories.v1`, `vipSenders.v1`, and
/// `repliedMessages.v1` are now in `SyncedSensitiveKeys` and routed through
/// `PendingSyncChangesStore` before they reach this merge layer. The merge
/// functions below are kept because the data-shape definitions are still
/// useful (e.g. `VIPStoredStateShim`), and because the pull path falls back
/// to merge for non-sensitive allowlist keys — but for those three keys
/// specifically, the merge code is no longer reached from `pull()`.
///
/// Sensitive keys (`SyncedSensitiveKeys.all` — accounts, rules, AI config)
/// deliberately do NOT merge here; they flow through
/// `PendingSyncChangesStore` instead so the user has to approve incoming
/// changes. That's a security boundary — an iCloud-compromised attacker
/// could rewrite a rule's outcome to `.delete` with broad conditions and
/// have us auto-fire it. Merging by id would silently union the attacker's
/// rule onto the legitimate set.
///
/// **Convergence.** When a pull produces a merged value with `pushBack`
/// set, the mirror marks the key dirty so this device pushes back to
/// iCloud. The other device(s) then pull the merged value; their own
/// merge produces no new local-only entries, so `pushBack` is false and
/// the cycle terminates. Merge functions must therefore be **idempotent**
/// on their own output and **commutative** between devices.
public enum CloudKVMerge {
    /// Shared default encoder for the three merge paths — avoids allocating
    /// a fresh `JSONEncoder` per merge. `JSONEncoder` is `Sendable`, so a
    /// plain static is concurrency-safe even though this enum is not
    /// actor-isolated.
    private static let encoder = JSONEncoder()

    /// Result of a per-key merge. `merged` is what should be written to
    /// `UserDefaults`; `pushBack` is true when the merged value adds
    /// entries the remote doesn't yet have (so the mirror should mark the
    /// key dirty and re-push, propagating those entries to other devices).
    public struct Result {
        public let merged: Any?
        public let pushBack: Bool

        public init(merged: Any?, pushBack: Bool) {
            self.merged = merged
            self.pushBack = pushBack
        }
    }

    /// Returns a merged value for `key` when the key has merge semantics,
    /// otherwise `nil`. The caller should fall back to last-writer-wins
    /// (or its own pending-changes flow for sensitive keys) when this
    /// returns nil.
    public static func merge(key: String, local: Any?, remote: Any?) -> Result? {
        switch key {
        case "File13.senderCategories.v1":
            return mergeCategoriesData(local: local, remote: remote)
        case "File13.senderCategories.v1.lastRunAt":
            return mergeLatestDate(local: local, remote: remote)
        case "File13.dismissedSuggestions.v1":
            return mergeDismissalsArray(local: local, remote: remote)
        // `File13.vipSenders.v1` and `File13.repliedMessages.v1` were
        // previously merged here. Both moved to `SyncedSensitiveKeys` so a
        // remote change is stashed in `PendingSyncChangesStore` and gated
        // behind explicit user approval (protects against VIP-bypass and
        // forged-reply-record VIP elevation). `mergeVIPsData` /
        // `mergeRepliedData` are kept below as private helpers so a future
        // policy change ("merge but show a banner") can re-add them with
        // one line; they're unreferenced as of this change.
        default:
            return nil
        }
    }

    // MARK: - Per-key implementations

    /// `[String: SenderCategory]` JSON-encoded as `Data`.
    /// Disjoint keys unioned; overlapping keys take the remote value.
    private static func mergeCategoriesData(local: Any?, remote: Any?) -> Result {
        let localDict: [String: SenderCategory] = decodeJSONData(local) ?? [:]
        let remoteDict: [String: SenderCategory] = decodeJSONData(remote) ?? [:]
        // Start from local, then overwrite with remote — remote-wins on
        // overlap, disjoint keys from both sides survive.
        var merged = localDict
        for (k, v) in remoteDict { merged[k] = v }
        let pushBack = localDict.keys.contains { remoteDict[$0] == nil }
        let mergedData = (try? Self.encoder.encode(merged)) ?? (remote as? Data) ?? Data()
        return Result(merged: mergedData, pushBack: pushBack)
    }

    /// `Date` stored directly on `NSUbiquitousKeyValueStore` /
    /// `UserDefaults`. Take the latest.
    private static func mergeLatestDate(local: Any?, remote: Any?) -> Result {
        let localDate = local as? Date
        let remoteDate = remote as? Date
        switch (localDate, remoteDate) {
        case (nil, nil): return Result(merged: nil, pushBack: false)
        case (.some(let l), nil): return Result(merged: l, pushBack: true)
        case (nil, .some(let r)): return Result(merged: r, pushBack: false)
        case (.some(let l), .some(let r)):
            if l > r { return Result(merged: l, pushBack: true) }
            return Result(merged: r, pushBack: false)
        }
    }

    /// `[String]` array of dismissal fingerprints (Set semantics on disk).
    /// Pure union; encoded back as a sorted array so the on-disk bytes are
    /// stable and a no-op merge doesn't bounce back to iCloud.
    private static func mergeDismissalsArray(local: Any?, remote: Any?) -> Result {
        let localSet: Set<String> = Set((local as? [String]) ?? [])
        let remoteSet: Set<String> = Set((remote as? [String]) ?? [])
        let merged = localSet.union(remoteSet)
        let pushBack = !localSet.subtracting(remoteSet).isEmpty
        let sortedArray = merged.sorted()
        return Result(merged: sortedArray, pushBack: pushBack)
    }

    /// `[UUID: Set<String>]` JSON-encoded as `Data`. Per-account union of
    /// the inner sets. Disjoint accounts retained from both sides.
    private static func mergeRepliedData(local: Any?, remote: Any?) -> Result {
        let localDict: [UUID: Set<String>] = decodeJSONData(local) ?? [:]
        let remoteDict: [UUID: Set<String>] = decodeJSONData(remote) ?? [:]
        var merged = remoteDict
        var pushBack = false
        for (account, localReplies) in localDict {
            let remoteReplies = merged[account] ?? []
            let unioned = remoteReplies.union(localReplies)
            if unioned.count > remoteReplies.count {
                pushBack = true
            }
            if !unioned.isEmpty {
                merged[account] = unioned
            }
        }
        let mergedData = (try? Self.encoder.encode(merged)) ?? (remote as? Data) ?? Data()
        return Result(merged: mergedData, pushBack: pushBack)
    }

    /// VIPStore's `StoredState`: `(autoDetected, pinned, excluded,
    /// lastDetectionAt)`. Pin / exclude are pure unions (user intent on
    /// either device is preserved); `(autoDetected, lastDetectionAt)` is
    /// taken as a unit from whichever side detected more recently.
    private static func mergeVIPsData(local: Any?, remote: Any?) -> Result {
        let localState: VIPStoredStateShim = decodeJSONData(local) ?? .empty
        let remoteState: VIPStoredStateShim = decodeJSONData(remote) ?? .empty

        let pinned = localState.pinned.union(remoteState.pinned)
        let excluded = localState.excluded.union(remoteState.excluded)

        // Pair `autoDetected` with `lastDetectionAt` — the snapshot only
        // makes sense alongside the run that produced it.
        let pickLocalDetection: Bool
        switch (localState.lastDetectionAt, remoteState.lastDetectionAt) {
        case (nil, nil):                                pickLocalDetection = !localState.autoDetected.isEmpty
        case (.some, nil):                              pickLocalDetection = true
        case (nil, .some):                              pickLocalDetection = false
        case (.some(let l), .some(let r)):              pickLocalDetection = l > r
        }
        let autoDetected = pickLocalDetection ? localState.autoDetected : remoteState.autoDetected
        let lastDetectionAt = pickLocalDetection ? localState.lastDetectionAt : remoteState.lastDetectionAt

        let merged = VIPStoredStateShim(
            autoDetected: autoDetected,
            pinned: pinned,
            excluded: excluded,
            lastDetectionAt: lastDetectionAt
        )

        let pushBack =
            !localState.pinned.subtracting(remoteState.pinned).isEmpty ||
            !localState.excluded.subtracting(remoteState.excluded).isEmpty ||
            pickLocalDetection && merged != remoteState

        let mergedData = (try? Self.encoder.encode(merged)) ?? (remote as? Data) ?? Data()
        return Result(merged: mergedData, pushBack: pushBack)
    }

    // MARK: - Helpers

    private static func decodeJSONData<T: Decodable>(_ value: Any?) -> T? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Internal mirror of `VIPStore.StoredState`. Kept here (instead of made
/// `Codable` on `VIPStore`) so the merge function doesn't have to reach
/// into the store's private nested type. The JSON shape must match
/// `VIPStore.StoredState` exactly — keys are alphabetical via Swift's
/// default `Codable` synthesis, which matches the encoder both sides use.
struct VIPStoredStateShim: Codable, Equatable {
    var autoDetected: Set<String>
    var pinned: Set<String>
    var excluded: Set<String>
    var lastDetectionAt: Date?

    static let empty = VIPStoredStateShim(
        autoDetected: [], pinned: [], excluded: [], lastDetectionAt: nil
    )
}
