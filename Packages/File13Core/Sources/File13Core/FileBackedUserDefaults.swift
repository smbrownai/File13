import Foundation
import os

extension Notification.Name {
    /// Posted on the default `NotificationCenter` when `FileBackedUserDefaults`
    /// fails to persist a write — typically disk-full or a permission error
    /// on the App Group container. `userInfo["error"]` carries the localized
    /// description as a `String`. The macOS app's `File13App` observes
    /// this and pumps the message into `InboxStore.lastError` so the user
    /// sees a banner instead of losing settings silently.
    ///
    /// Before this signal existed, `persist()` matched cfprefsd's "drop
    /// invalid writes" behavior — fine for the value-not-plist-encodable
    /// case the comment originally referenced, much less fine for
    /// disk-full, where every subsequent settings change also vanishes.
    public static let fileBackedDefaultsWriteFailed = Notification.Name(
        "File13.fileBackedDefaultsWriteFailed"
    )
}

/// UserDefaults subclass backed by a single plist file on disk.
///
/// File13 ships in two binaries that need to see the same shared
/// state: the sandboxed GUI app (Mac App Store, has App Group +
/// keychain-access-groups entitlements) and the Homebrew-distributed
/// CLI (bare Mach-O, has no restricted entitlements — see
/// `cli/file13.entitlements` for why).
///
/// The natural mechanism is `UserDefaults(suiteName: "group.com…")`,
/// which on macOS routes through `cfprefsd`. **It silently doesn't work
/// for the CLI**: without the App Group entitlement, cfprefsd serves
/// the unentitled process from `~/Library/Preferences/<group-id>.plist`
/// — a separate file from
/// `~/Library/Group Containers/<group-id>/Library/Preferences/<group-id>.plist`
/// that the entitled GUI writes to. The init returns a UserDefaults
/// object successfully but every lookup misses, because the bytes
/// live in a file the unentitled process never sees.
///
/// File-backed defaults sidestep cfprefsd entirely. Both processes
/// read and write the same plist file at the App Group container
/// path. The GUI's writes are immediately visible to the CLI and
/// vice versa.
///
/// ## Read cost
///
/// Every read checks the file's mtime. If unchanged since the last
/// load, the in-memory dictionary is returned directly (microsecond-
/// level, same as cfprefsd's cache). If the mtime moved (the other
/// process wrote), the dictionary is re-read from disk first
/// (sub-millisecond for the ~80 KB plist we ship). No write
/// notifications are needed for cross-process freshness — the mtime
/// check covers it.
///
/// ## Write cost
///
/// Each write deserializes the cached dict, updates the key, then
/// re-serializes and writes atomically. ~1 ms on a current Mac. The
/// `UserDefaults.didChangeNotification` is posted manually so
/// CloudKVSyncMirror's "flush dirty keys on change" observer fires
/// the same way it would for a cfprefsd-backed write.
///
/// ## Limitations
///
/// - Plist-incompatible values (arbitrary Swift objects, closures,
///   …) fail to persist. We only store plist primitives (Bool, Int,
///   Double, String, Data, Date, Array, Dictionary) in practice —
///   same constraint cfprefsd has.
/// - Concurrent writes from two processes can lose one write if both
///   read-modify-write at the same instant. File13's GUI-vs-CLI
///   writes don't overlap in practice: mail-touching CLI commands
///   bail with exit 2 when the GUI is open, and the few writes that
///   can race (Pro tier cache, suggestion dismissals) are infrequent
///   enough that the chance of collision is negligible. A future
///   refinement could use `NSFileCoordinator` for stricter
///   guarantees.
public final class FileBackedUserDefaults: UserDefaults, @unchecked Sendable {
    private let fileURL: URL
    /// In-memory mirror of the plist. Re-read on demand whenever the
    /// file's mtime advances past `cachedMtime`.
    private var cached: NSMutableDictionary
    /// Modification date of the plist file at the time `cached` was
    /// loaded. `nil` until first successful load.
    private var cachedMtime: Date?
    /// Serialize concurrent reads/writes within the process. UserDefaults
    /// itself is documented as thread-safe; matching that contract.
    /// Cross-process safety is via atomic file writes + mtime checks,
    /// not this lock.
    private let lock = NSLock()

    public init(plistURL: URL) {
        self.fileURL = plistURL
        let initial = Self.loadDict(from: plistURL)
        self.cached = initial.dict
        self.cachedMtime = initial.mtime
        // Parent UserDefaults needs a non-nil suite to construct. Use a
        // process-unique throwaway domain so the parent's own storage
        // never collides with anything else — we override every read
        // and write to skip the parent's path anyway.
        super.init(suiteName: "FileBackedUserDefaults-\(UUID().uuidString)")!
    }

    // MARK: - Load / persist

    private static func loadDict(from url: URL) -> (dict: NSMutableDictionary, mtime: Date?) {
        guard let data = try? Data(contentsOf: url) else {
            return (NSMutableDictionary(), nil)
        }
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = (plist as? NSDictionary).map { ($0.mutableCopy() as? NSMutableDictionary) ?? NSMutableDictionary() }
            ?? NSMutableDictionary()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        return (dict, mtime)
    }

    /// Reload the in-memory dict iff the file's mtime has advanced past
    /// the snapshot we have. The common case (no external writes) is a
    /// single `stat` syscall plus a comparison.
    private func reloadIfFileChanged() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let mtime = attrs[.modificationDate] as? Date
        else { return }
        if let cachedMtime, mtime <= cachedMtime { return }
        let fresh = Self.loadDict(from: fileURL)
        cached = fresh.dict
        cachedMtime = fresh.mtime
    }

    private func persist() {
        // Make sure the container directory exists. First-write race
        // when no GUI has yet populated the App Group container.
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: cached,
                format: .binary,
                options: 0
            )
            try data.write(to: fileURL, options: .atomic)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let mtime = attrs[.modificationDate] as? Date {
                cachedMtime = mtime
            }
            // Notification is posted by callers (`set`, `removeObject`)
            // after they release the lock — observers can call back into
            // our methods, and posting inside `persist` would deadlock
            // any sync observer.
        } catch {
            // Best-effort write — but signal the failure so it doesn't
            // disappear into a black hole. cfprefsd silently drops
            // un-plist-encodable values; the more dangerous case is
            // disk-full / permission denied, where the user's settings
            // change vanishes and every subsequent edit will too until
            // they notice. Log to the unified system log (visible in
            // Console.app and sysdiagnose) and post a notification the
            // app layer can pick up to surface a banner.
            Self.log.error("FileBackedUserDefaults persist failed: \(error.localizedDescription, privacy: .public)")
            NotificationCenter.default.post(
                name: .fileBackedDefaultsWriteFailed,
                object: nil,
                userInfo: ["error": error.localizedDescription]
            )
        }
    }

    private static let log = Logger(
        subsystem: "com.shawnbrown.File13",
        category: "FileBackedUserDefaults"
    )

    // MARK: - Generic reads/writes (everything else flows through these)

    public override func object(forKey defaultName: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        reloadIfFileChanged()
        return cached[defaultName]
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        reloadIfFileChanged()
        if let value {
            cached[defaultName] = value
        } else {
            cached.removeObject(forKey: defaultName)
        }
        persist()
        lock.unlock()
        // Post outside the lock — observers may call back into us.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    public override func removeObject(forKey defaultName: String) {
        lock.lock()
        reloadIfFileChanged()
        cached.removeObject(forKey: defaultName)
        persist()
        lock.unlock()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    public override func dictionaryRepresentation() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        reloadIfFileChanged()
        return (cached as? [String: Any]) ?? [:]
    }

    // MARK: - Typed convenience accessors
    // These each flow through `object(forKey:)` so they pick up the
    // mtime check + cache automatically. Overriding them explicitly is
    // necessary because the parent class's implementations go through
    // its own internal storage, not our `object(forKey:)` override.

    public override func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    public override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    public override func array(forKey defaultName: String) -> [Any]? {
        object(forKey: defaultName) as? [Any]
    }

    public override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }

    public override func stringArray(forKey defaultName: String) -> [String]? {
        object(forKey: defaultName) as? [String]
    }

    public override func integer(forKey defaultName: String) -> Int {
        if let n = object(forKey: defaultName) as? Int { return n }
        if let n = object(forKey: defaultName) as? NSNumber { return n.intValue }
        return 0
    }

    public override func float(forKey defaultName: String) -> Float {
        if let n = object(forKey: defaultName) as? Float { return n }
        if let n = object(forKey: defaultName) as? NSNumber { return n.floatValue }
        return 0
    }

    public override func double(forKey defaultName: String) -> Double {
        if let n = object(forKey: defaultName) as? Double { return n }
        if let n = object(forKey: defaultName) as? NSNumber { return n.doubleValue }
        return 0
    }

    public override func bool(forKey defaultName: String) -> Bool {
        if let b = object(forKey: defaultName) as? Bool { return b }
        if let n = object(forKey: defaultName) as? NSNumber { return n.boolValue }
        return false
    }

    public override func url(forKey defaultName: String) -> URL? {
        if let s = object(forKey: defaultName) as? String { return URL(string: s) }
        if let d = object(forKey: defaultName) as? Data {
            // Match UserDefaults' historic NSKeyedArchiver-encoded
            // URL fallback. Best-effort: most callers store strings.
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: d) as URL?
        }
        return nil
    }

    // MARK: - Typed setters
    // The bare `set(_:Any?, forKey:)` overload covers these, but
    // overriding the primitive setters explicitly avoids any
    // UserDefaults-internal shortcut that would skip `set(_:forKey:)`.

    public override func set(_ value: Int, forKey defaultName: String) {
        set(value as Any?, forKey: defaultName)
    }

    public override func set(_ value: Float, forKey defaultName: String) {
        set(value as Any?, forKey: defaultName)
    }

    public override func set(_ value: Double, forKey defaultName: String) {
        set(value as Any?, forKey: defaultName)
    }

    public override func set(_ value: Bool, forKey defaultName: String) {
        set(value as Any?, forKey: defaultName)
    }

    public override func set(_ url: URL?, forKey defaultName: String) {
        set(url?.absoluteString as Any?, forKey: defaultName)
    }

    // MARK: - No-op synchronize
    // UserDefaults.synchronize() is deprecated and a hint to cfprefsd
    // to flush. With a file-backed store, every write is already
    // synchronous and atomic.

    public override func synchronize() -> Bool { true }
}
