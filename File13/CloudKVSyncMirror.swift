import File13Core
import Foundation
import Observation

/// Bidirectional bridge between App Group `UserDefaults` and
/// `NSUbiquitousKeyValueStore` for the allowlisted keys in
/// `CloudKVSync.allowlist`.
///
/// Lifecycle:
/// 1. `start()` — installs `NSUbiquitousKeyValueStore` external-change
///    observer, runs an initial reconcile (pull-then-push), and from then on
///    pushes dirty keys whenever `flush()` is called.
/// 2. `stop()` — removes the observer. Leaves UserDefaults state alone.
///
/// Conflict policy: NSUbiquitousKeyValueStore stamps every change with a
/// timestamp and resolves conflicts itself. From our side we simply mirror —
/// when iCloud says a value changed externally we write it to defaults; when
/// the dirty-flag set says a value changed locally we write it to iCloud.
/// "Externally-changed" notifications carry the changed keys, so we never
/// have to push everything.
///
/// The mirror runs only inside the GUI app. The CLI doesn't carry the
/// `ubiquity-kvstore-identifier` entitlement, so it touches local defaults
/// only — its writes get picked up via the dirty-flag set the next time the
/// GUI is running.
@MainActor
@Observable
final class CloudKVSyncMirror {
    /// True while the observer is installed and `flush()` will push.
    private(set) var isRunning = false

    /// Last reconcile outcome, surfaced in the Settings UI so users can tell
    /// whether iCloud is actually responding. Cleared on `start()`.
    private(set) var lastStatus: Status = .idle

    enum Status: Sendable, Equatable {
        case idle
        case running
        case error(String)
    }

    private let defaults: UserDefaults
    private let store: NSUbiquitousKeyValueStore
    private var observer: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = SharedDefaults.suite,
         store: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.store = store
    }

    /// Begin mirroring. Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastStatus = .running

        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in
                self.handleRemoteChange(note: note)
            }
        }

        // Whenever any UserDefaults write happens, opportunistically flush
        // dirty keys. The dirty-set check inside `flush` short-circuits when
        // there's nothing to push, so writes outside the allowlist are free.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.flush()
            }
        }

        // Ask iCloud to deliver any pending remote state. The first sync
        // after app launch usually fires `didChangeExternally` within a few
        // seconds; until it does, `store.object(forKey:)` returns whatever
        // iCloud last cached on disk (which may be empty or stale).
        _ = store.synchronize()

        // Initial seed: the first time the user turns sync on *on this Mac*,
        // push every locally-set allowlisted key whose remote slot is empty.
        // We deliberately do NOT overwrite remote values that already exist —
        // those belong to whichever device started syncing first. Subsequent
        // local edits propagate normally via dirty-flag + `flush()`.
        if !defaults.bool(forKey: Self.didSeedKey) {
            for key in CloudKVSync.allowlist {
                guard let local = defaults.object(forKey: key) else { continue }
                if store.object(forKey: key) == nil {
                    store.set(local, forKey: key)
                }
            }
            defaults.set(true, forKey: Self.didSeedKey)
        }

        // Push any keys that picked up dirty flags between sessions (e.g. the
        // CLI made changes while the GUI was closed).
        flush()
    }

    /// Per-Mac sentinel: set after the first successful seed. Stored in
    /// UserDefaults (NOT in the synced allowlist), so each Mac runs its own
    /// one-shot seed on the first enable.
    private static let didSeedKey = "File13.iCloudSync.didSeed"

    /// Stop observing and stop pushing. Doesn't undo any state that's
    /// already been mirrored — it just freezes the mirror in place.
    func stop() {
        guard isRunning else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        isRunning = false
        lastStatus = .idle
    }

    /// Push every currently-dirty allowlisted key to iCloud. Safe to call
    /// repeatedly — keys not in the dirty set are skipped, so the work is
    /// proportional to "what changed since last push."
    func flush() {
        guard isRunning else { return }
        let dirty = CloudKVSync.dirtyKeys(defaults: defaults)
        guard !dirty.isEmpty else { return }
        for key in dirty {
            guard CloudKVSync.isSynced(key) else {
                // Belt-and-suspenders: never push a non-allowlisted key even
                // if a stray dirty flag somehow snuck in.
                CloudKVSync.clearDirty(key, defaults: defaults)
                continue
            }
            push(key: key)
            CloudKVSync.clearDirty(key, defaults: defaults)
        }
        _ = store.synchronize()
    }

    // MARK: - Push / pull

    /// Push one key from defaults → iCloud. Encodes whatever the value is
    /// using a small, type-preserving union so the receiving end can write
    /// it back to the right defaults type.
    private func push(key: String) {
        let value = defaults.object(forKey: key)
        if let value {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    /// Pull from iCloud → defaults for one key. Called for each key the
    /// remote-change notification names. Doesn't clear dirty flags — local
    /// pending pushes (if any) get reconciled by `flush()`.
    ///
    /// **Sensitive synced keys** (`SyncedSensitiveKeys.all`) bypass the
    /// direct write and instead stash the incoming value as a *pending
    /// change* in `PendingSyncChangesStore`. The user has to approve the
    /// change in the relevant Settings tab before it takes effect
    /// locally. Covers three attack surfaces an iCloud-account
    /// compromise would otherwise expose:
    ///
    /// - AI configuration (silent provider re-routing, malicious custom
    ///   instructions)
    /// - **Account records** — rewriting `host` in an existing IMAP
    ///   account would exfiltrate the user's password to an attacker
    ///   server on the next refresh
    /// - **Rules** — an injected `enabled: true, outcome: .delete` rule
    ///   with broad conditions auto-fires at the next scheduled run
    ///
    /// Everything else in the allowlist applies transparently.
    ///
    /// Loosened from `private` to `internal` for test access — the
    /// CloudKVSyncMirror dispatch is the security boundary the
    /// pending-confirm banners depend on, and direct test coverage is
    /// the only reliable way to catch a regression that turns a
    /// sensitive key into a mergeable or LWW one without anyone
    /// noticing. Don't call from production paths — the surrounding
    /// `start()` / `handleRemoteChange()` flow is the only one that
    /// integrates with `NSUbiquitousKeyValueStore` correctly.
    internal func pull(key: String) {
        guard CloudKVSync.isSynced(key) else { return }
        let remoteValue = store.object(forKey: key)

        if SyncedSensitiveKeys.all.contains(key) {
            let localValue = defaults.object(forKey: key)
            if !objectsEqualForSync(localValue, remoteValue) {
                PendingSyncChangesStore.stash(key: key, remote: remoteValue, defaults: defaults)
                NotificationCenter.default.post(name: .pendingSyncChangesUpdated, object: nil)
            }
            return
        }

        // Mergeable keys (categories, VIPs, dismissals, replies, …) go
        // through `CloudKVMerge` so concurrent edits on two devices don't
        // clobber each other. When the merged value adds entries the
        // remote doesn't yet know about, mark the key dirty so this Mac
        // re-pushes it; the cycle terminates as soon as both sides converge.
        let localValue = defaults.object(forKey: key)
        if let mergeResult = CloudKVMerge.merge(key: key, local: localValue, remote: remoteValue) {
            if let merged = mergeResult.merged {
                defaults.set(merged, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            if mergeResult.pushBack {
                CloudKVSync.markDirty(key, defaults: defaults)
            }
            return
        }

        // Fall back to last-writer-wins for non-merged allowlist entries
        // (primitives, simple preferences). `object(forKey:)` returns nil
        // if iCloud doesn't have a value; we mirror absence by clearing
        // the local key.
        if let value = remoteValue {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// `UserDefaults` and `NSUbiquitousKeyValueStore` both return `Any?`,
    /// and the values can be primitives (String / Int / Bool / Date) or
    /// `Data` / `[String: Any]` / `[Any]`. Plist serialization gives us a
    /// canonical byte form we can compare with `==`, and that's exactly
    /// the same encoding `PendingAIChangesStore.stash` uses, so this
    /// comparison won't false-negative on legitimately-identical values.
    private func objectsEqualForSync(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some, nil), (nil, .some): return false
        case (.some(let l), .some(let r)):
            let ld = try? PropertyListSerialization.data(fromPropertyList: l, format: .binary, options: 0)
            let rd = try? PropertyListSerialization.data(fromPropertyList: r, format: .binary, options: 0)
            return ld == rd
        }
    }

    // MARK: - Remote-change handling

    private func handleRemoteChange(note: Notification) {
        guard let userInfo = note.userInfo else { return }
        guard let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else { return }
        // Server-driven conflict resolution: `Initial` means we just got
        // first-sync state; `ServerChange` means a remote write; both flow
        // through `pull` identically. The `QuotaViolationChange` and
        // `AccountChange` reason codes deserve user-visible surfacing.
        let reason = (userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int) ?? -1
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            lastStatus = .error("iCloud sync is over quota — some changes won't sync until you free space.")
        } else if reason == NSUbiquitousKeyValueStoreAccountChange {
            lastStatus = .error("iCloud account changed — sign in again in System Settings to resume sync.")
        } else {
            lastStatus = .running
        }
        for key in changedKeys {
            pull(key: key)
        }
    }
}
