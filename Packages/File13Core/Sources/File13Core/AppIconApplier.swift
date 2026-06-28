import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Applies the user's `SettingsStore.AppIconChoice` to the running app.
///
/// Platform behavior:
/// - **iOS**: calls `UIApplication.shared.setAlternateIconName(_:)`. The
///   system swaps the Home Screen / App Library / Settings icon and shows
///   its own (unavoidable) confirmation alert. Passing `nil` reverts to the
///   primary bundle icon — that's how `.default` is implemented.
/// - **macOS**: assigns an `NSImage` to `NSApp.applicationIconImage`. This
///   updates the Dock tile, app switcher, About panel, and notification
///   icon for the running session. The Finder bundle icon never changes
///   (Apple doesn't allow apps to rewrite their own bundle resources, and
///   we've deliberately accepted that limitation).
///
/// Pro gate: the applier honors `LicenseStore.tier`. If the user picks an
/// alternate on Pro and then their license lapses, the next bootstrap (or
/// any subsequent apply call) silently reverts to the default — preventing
/// a synced-in choice from a Pro device leaking to a free device, and
/// covering refunds / family-sharing revocations.
@MainActor
public enum AppIconApplier {
    /// Apply `choice` if the user is licensed to use it; otherwise revert to
    /// the default bundle icon. Safe to call from app bootstrap or in
    /// response to a picker change.
    public static func apply(_ choice: SettingsStore.AppIconChoice, tier: LicenseStore.Tier) {
        let effective: SettingsStore.AppIconChoice = (choice.requiresPro && tier != .pro)
            ? .default
            : choice
        applyResolved(effective)
    }

    // MARK: - Platform-specific implementations

    #if canImport(UIKit)
    private static func applyResolved(_ choice: SettingsStore.AppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let target = choice.iOSAlternateName
        // Skip the system alert when the running icon already matches —
        // setAlternateIconName always shows the modal, even for a no-op
        // change, so we guard explicitly.
        if UIApplication.shared.alternateIconName == target { return }
        UIApplication.shared.setAlternateIconName(target) { _ in
            // Failure is non-fatal. The most common cause is calling
            // before the scene is active, in which case the next launch
            // will pick the value back up via the bootstrap path.
        }
    }
    #elseif canImport(AppKit)
    private static func applyResolved(_ choice: SettingsStore.AppIconChoice) {
        switch choice {
        case .default:
            // nil restores the bundle's canonical icon.
            NSApp.applicationIconImage = nil
        case .vintage:
            if let image = NSImage(named: choice.macAssetName) {
                NSApp.applicationIconImage = image
            } else {
                NSApp.applicationIconImage = nil
            }
        }
    }
    #else
    private static func applyResolved(_ choice: SettingsStore.AppIconChoice) {
        // Unsupported platform — no-op. File13 only ships on macOS and iOS.
    }
    #endif
}
