import Foundation

/// Resolves the `UserDefaults` instance every persistent store reads and writes through.
///
/// File13's GUI app and the headless `file13` CLI both need to see the same accounts,
/// settings, rules, and AI tuning. The mechanism is the App Group shared container —
/// `UserDefaults(suiteName: "group.com.shawnbrown.File13")` resolves to the same plist
/// file inside `~/Library/Group Containers/<group>/` for any binary that holds the entitlement.
///
/// On macOS the suite is created lazily on first write. We pin a single instance here so we
/// don't allocate a fresh one per call and so all stores in a process see consistent state.
@MainActor
public enum SharedDefaults {
    /// App Group identifier — must match the entitlement on both binaries (case-sensitive).
    /// Compile-time constant; nonisolated so non-main-actor callers (CLI doctor checks,
    /// command-line plumbing) can read it without hopping actors.
    public nonisolated static let appGroupId = "group.com.shawnbrown.File13"

    /// The shared suite. File-backed: both the GUI app and the Homebrew
    /// CLI read and write the same plist file at the App Group container
    /// path, bypassing cfprefsd. Why not `UserDefaults(suiteName:)`:
    ///
    /// On macOS, `UserDefaults(suiteName:)` routes through cfprefsd. For
    /// an unentitled process (the bare-Mach-O CLI, which can't claim
    /// `com.apple.security.application-groups` without an embedded
    /// provisioning profile), cfprefsd silently serves the suite name
    /// from `~/Library/Preferences/<group-id>.plist` — a separate file
    /// from the App Group container plist the entitled GUI writes to.
    /// The init returns a valid object, every lookup misses, and every
    /// store appears empty. License gate, settings reads, account list
    /// — all broken without any error. See FileBackedUserDefaults for
    /// the workaround.
    ///
    /// The GUI also uses this same file-backed path so both binaries
    /// stay in lockstep. Cost: one stat + plist parse per read on mtime
    /// change, well under cfprefsd's own caching. Benefit: the GUI sees
    /// CLI writes immediately and vice versa, no cfprefsd cache
    /// coherency headaches.
    ///
    /// Falls back to `.standard` if the App Group container directory
    /// can't be resolved (truly broken setup, e.g. an OS that doesn't
    /// support App Groups). `usingSharedSuite` and `file13 doctor`
    /// both surface that case.
    public static let suite: UserDefaults = {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else {
            return .standard
        }
        let plistURL = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(appGroupId).plist")
        return FileBackedUserDefaults(plistURL: plistURL)
    }()

    /// True iff the resolved suite is the actual App Group suite (i.e., the entitlement
    /// resolved correctly), false if we fell back to `.standard`. Both binaries report this
    /// via their respective UIs (GUI: settings tab; CLI: `file13 doctor`).
    public static var usingSharedSuite: Bool { suite !== UserDefaults.standard }

    // MARK: - Migration

    /// Sentinel key written into the suite once the one-time migration from `.standard` has
    /// completed. Stored in the suite (not standard) so a corrupted suite re-runs migration.
    private static let migrationCompletedKey = "File13.migration.suiteV1.complete"

    /// Copy every `File13.*` key from `.standard` into the suite, exactly once. Idempotent:
    /// the second call is a no-op. Conservative: never overwrites a key that already exists in
    /// the suite (so re-running after the user has set values in the suite directly is safe).
    ///
    /// Call this from `File13App.init` BEFORE constructing any store. The CLI calls it too,
    /// but on a CLI-first install the standard defaults are empty so it's a no-op.
    ///
    /// Returns the number of keys copied (0 if no migration was needed).
    @discardableResult
    public static func migrateFromStandardIfNeeded() -> Int {
        // If the destination is .standard (entitlement missing fallback), there's nothing to do.
        guard usingSharedSuite else { return 0 }
        guard !suite.bool(forKey: migrationCompletedKey) else { return 0 }

        let standard = UserDefaults.standard
        let prefix = "File13."
        var copied = 0
        for (key, value) in standard.dictionaryRepresentation() where key.hasPrefix(prefix) {
            // Don't clobber values the user may have set in the suite already.
            if suite.object(forKey: key) == nil {
                suite.set(value, forKey: key)
                copied += 1
            }
        }
        suite.set(true, forKey: migrationCompletedKey)
        return copied
    }
}
