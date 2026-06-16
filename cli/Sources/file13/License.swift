import ArgumentParser
import File13Core
import Foundation

/// Read-only view of the GUI's license state, used by CLI write commands to
/// honor the same paywall as the GUI.
///
/// The CLI never writes here — it can't purchase (no StoreKit in a
/// command-line tool) and can't claim the platform marker (the GUI owns
/// that). When the gate trips we tell the user to install / launch the
/// Mac App Store app, which handles purchase and writes the cached tier
/// to App Group `UserDefaults`. Next CLI invocation reads it and lets the
/// command through.
///
/// Threat-model note: a determined user could write
/// `File13.license.cachedTier` to App Group defaults manually and bypass
/// this. Same indifference applies as in the GUI — see CLAUDE.md.
enum CLILicenseReader {
    /// Mirror of `LicenseStore.Tier`. Redeclared here so the CLI doesn't
    /// pull in StoreKit / AppKit through the GUI's `LicenseStore` type.
    enum Tier: String { case free, pro }

    private static let cachedTierKey = "File13.license.cachedTier"

    /// `SharedDefaults.suite` is `@MainActor`-isolated; mark this method
    /// the same so it's safe to call from the CLI's `@MainActor func run()`
    /// command bodies. (All CLI subcommands annotate `run` with @MainActor
    /// already to talk to the rest of File13Core's main-actor stores.)
    @MainActor
    static var tier: Tier {
        guard let raw = SharedDefaults.suite.string(forKey: cachedTierKey) else {
            return .free
        }
        return Tier(rawValue: raw) ?? .free
    }

    /// Gate every CLI subcommand on Pro. The bundled `file13` binary is
    /// a Pro feature in its entirety; non-Pro users still get `version`
    /// and `doctor` so they can confirm install and provider availability
    /// before purchasing. Every other command calls this first and exits
    /// 4 on `.free`.
    @MainActor
    static func requirePro() throws {
        guard tier != .pro else { return }
        try failProRequired()
    }

    /// Print the standard "Pro required" message and exit 4 — the reserved
    /// CLI exit code for "this action requires a paid license."
    /// Shell scripts can branch on `$? == 4` to surface the upgrade path.
    static func failProRequired() throws -> Never {
        let message = """
        The file13 CLI requires File13 Pro.

        Install the Mac App Store version (search "File13"), launch the
        app once and tap Upgrade — your purchase activates on this Apple ID
        and the CLI picks it up automatically.

        Already purchased on another device? Open File13, choose
        Help → Restore Purchases, then re-run this command.
        """
        FileHandle.standardError.write(Data((message + "\n").utf8))
        throw ExitCode(4)
    }
}
