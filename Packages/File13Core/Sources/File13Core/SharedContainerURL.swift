import Foundation

/// Resolves filesystem paths for files that need to be visible to both the GUI app and
/// the headless CLI. The mechanism is the App Group container — a directory at
/// `~/Library/Group Containers/<group-id>/` that any binary entitled to the group can
/// read and write.
///
/// Without this, each binary's `URL.applicationSupportDirectory` resolves to its own
/// sandbox (or to `~/Library/Application Support` for the unsandboxed CLI), and the
/// SwiftData store the GUI populates is invisible to the CLI.
public enum SharedContainerURL {
    /// Root of the App Group container. Falls back to `applicationSupportDirectory` when
    /// the entitlement is missing — both binaries report this via their `doctor`-style
    /// surfaces, so a misconfigured environment shows up loudly rather than silently
    /// degrading data sharing.
    public static func root() -> URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedDefaults.appGroupId)
            ?? URL.applicationSupportDirectory
    }

    /// Directory under the container where File13-owned files live (rules JSON, the
    /// SwiftData store, future log files). Created on first call if absent.
    public static func file13Directory() -> URL {
        let dir = root().appendingPathComponent("Library/Application Support/File13", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// SwiftData store URL. Both binaries open this exact file via `ModelConfiguration`.
    public static func swiftDataStore() -> URL {
        file13Directory().appendingPathComponent("default.store")
    }
}
