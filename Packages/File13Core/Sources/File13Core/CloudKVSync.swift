import Foundation

/// The single source of truth for which `UserDefaults` keys are eligible to be
/// mirrored to iCloud via `NSUbiquitousKeyValueStore`. Anything not in this
/// allowlist never crosses the iCloud boundary.
///
/// Used by:
/// - The GUI app's `CloudKVSyncMirror` to decide what to push/pull.
/// - The CLI (and any non-GUI process) to mark keys "dirty" so the GUI can
///   push them on its next runloop. The CLI itself can't talk to iCloud — it
///   ships without the `ubiquity-kvstore-identifier` entitlement — but it
///   shares the App Group `UserDefaults` container with the GUI, so changes
///   it writes locally are picked up by the GUI mirror the next time the GUI
///   is running. Dirty flags make that hand-off reliable: a write that
///   landed while the GUI was closed still gets pushed when the GUI opens.
///
/// **Privacy contract — load-bearing.** The allowlist deliberately excludes:
/// - SwiftData / `MessageCache` (lives in its own store, not `UserDefaults`).
///   The `ModelConfiguration` is initialized without `cloudKitDatabase`, so
///   it can never sync. Don't add it.
/// - UID-validity entries (per-(account, mailbox) IMAP identifiers). They're
///   server-side state that doesn't map cross-device meaningfully and would
///   leak which mailboxes the user has cached.
/// - Migration sentinels, fetch progress, ephemeral connection state.
///
/// Add new keys here only when they're part of the user's *configuration* —
/// settings, rules, accounts (without passwords), AI preferences, triage
/// state (categories / VIPs / dismissals / replied-message ids). Email
/// headers and contents never appear here, by construction.
@MainActor
public enum CloudKVSync {
    /// Explicit allowlist. The string is the `UserDefaults` key; the iCloud
    /// KV-store uses the same name so reasoning across both sides is easy.
    public static let allowlist: Set<String> = [
        // SettingsStore
        "File13.appearance",
        "File13.refreshSchedule",
        "File13.accentPalette",
        "File13.appIcon.v1",
        "File13.undoBufferSeconds",
        "File13.confirmBeforeDelete",
        "File13.confirmBeforeUnsubscribe",
        "File13.dryRunMode",
        "File13.softDeleteToTrash",
        // The Swift property is `protectTransactionalFromDeletion`; the
        // UserDefaults key kept the older spelling for back-compat.
        "File13.protectTransactionalFromRules",
        "File13.protectVIPsFromRules",
        "File13.aiProvider",
        "File13.aiModel",
        "File13.autoCategorizeNewSenders",
        "File13.aiFeatureTuning.v1",
        "File13.preferredMailClientBundleId",
        "File13.preferredBrowserBundleId",
        "File13.defaultInboxScope",
        // `File13.launchAtLogin` deliberately NOT synced — it's system
        // state (`SMAppService.mainApp.status`) that has to be set per-Mac.

        // AccountStore — host/port/username/displayName per account.
        // Passwords are NOT here; they ride iCloud Keychain via
        // `kSecAttrSynchronizable` on the Keychain items themselves.
        "File13.accounts.v1",

        // RuleStore — schedule + the rules array (moved from file to defaults
        // so iCloud sync covers it).
        "File13.rulesSchedule",
        "File13.rules.v1",

        // Triage state
        "File13.senderCategories.v1",
        "File13.senderCategories.v1.lastRunAt",
        "File13.vipSenders.v1",
        "File13.dismissedSuggestions.v1",
        "File13.repliedMessages.v1",

        // The toggle itself — so enabling sync on one Mac shows up enabled
        // on the others. (Pulling this down causes the receiving Mac's
        // mirror to start mirroring; idempotent.)
        "File13.iCloudSyncEnabled",
    ]

    /// Returns true if a key is on the allowlist and should be mirrored.
    public static func isSynced(_ key: String) -> Bool {
        allowlist.contains(key)
    }

    // MARK: - Dirty flags

    /// Single UserDefaults key holding the set of allowlisted keys that have
    /// changed locally and need to be pushed to iCloud. The GUI consumes and
    /// clears this on each push.
    private static let dirtyFlagsKey = "File13.iCloudSync.dirty"

    /// Mark a key as needing to be pushed to iCloud. No-op if the key isn't
    /// on the allowlist (so CLI code calling this for a non-synced key
    /// doesn't accidentally leak it later) or if the user has iCloud sync
    /// turned off. Both the GUI and the CLI hit this path; the shared App
    /// Group `UserDefaults` makes the toggle visible to both.
    public static func markDirty(_ key: String, defaults: UserDefaults = SharedDefaults.suite) {
        guard allowlist.contains(key) else { return }
        // Don't accumulate dirty flags while sync is off — the user can
        // toggle sync back on later and `CloudKVSyncMirror.start()` does a
        // full push of all allowlisted keys to cover the catch-up case.
        guard defaults.bool(forKey: "File13.iCloudSyncEnabled") else { return }
        var set = Set(defaults.stringArray(forKey: dirtyFlagsKey) ?? [])
        set.insert(key)
        defaults.set(Array(set), forKey: dirtyFlagsKey)
    }

    /// Returns the set of currently-dirty allowlisted keys.
    public static func dirtyKeys(defaults: UserDefaults = SharedDefaults.suite) -> Set<String> {
        Set(defaults.stringArray(forKey: dirtyFlagsKey) ?? [])
    }

    /// Clear a key from the dirty set (call after successfully pushing it).
    public static func clearDirty(_ key: String, defaults: UserDefaults = SharedDefaults.suite) {
        var set = Set(defaults.stringArray(forKey: dirtyFlagsKey) ?? [])
        guard set.contains(key) else { return }
        set.remove(key)
        if set.isEmpty {
            defaults.removeObject(forKey: dirtyFlagsKey)
        } else {
            defaults.set(Array(set), forKey: dirtyFlagsKey)
        }
    }

    /// Clear every dirty flag at once.
    public static func clearAllDirty(defaults: UserDefaults = SharedDefaults.suite) {
        defaults.removeObject(forKey: dirtyFlagsKey)
    }
}
