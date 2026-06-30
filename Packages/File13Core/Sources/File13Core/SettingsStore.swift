import Foundation
import Observation
#if os(macOS)
import ServiceManagement
#endif
import SwiftUI

@Observable
@MainActor
public final class SettingsStore {
    public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        public var id: String { rawValue }
        public var label: String {
            switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" }
        }
        public var colorScheme: ColorScheme? {
            switch self { case .system: nil; case .light: .light; case .dark: .dark }
        }
    }

    /// Alternate app-icon choices. `.default` keeps the bundle icon — the
    /// blue radar-scope mark. `.vintage` is a Pro-gated alternate (the
    /// retro CRT-radar mark) that ships inside the app and gets applied at
    /// runtime: on iOS via `setAlternateIconName`, on macOS via
    /// `NSApp.applicationIconImage`.
    public enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
        case `default`, vintage

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .default:  "Default"
            case .vintage:  "Vintage"
            }
        }

        /// Asset name used by the macOS applier to set
        /// `NSApp.applicationIconImage`. The default is the bundle icon
        /// (`AppIcon` in the asset catalog); alternates are standalone image
        /// sets named `AppIcon.<Choice>` that ship inside the app.
        public var macAssetName: String {
            switch self {
            case .default:  "AppIcon"
            case .vintage:  "AppIcon.Vintage"
            }
        }

        /// Asset name for the picker thumbnail (loaded the same way on both
        /// platforms). App icons inside `.appiconset`s aren't reliably
        /// addressable via `UIImage(named:)`, so we ship a separate small
        /// preview image set per icon and use it in the picker UI only.
        public var previewAssetName: String {
            switch self {
            case .default:  "IconPreview.Default"
            case .vintage:  "IconPreview.Vintage"
            }
        }

        /// iOS alternate-icon identifier (matches `.appiconset` filename in
        /// the iOS asset catalog). `nil` for `.default` — passing `nil` to
        /// `setAlternateIconName(_:)` reverts to the primary bundle icon.
        public var iOSAlternateName: String? {
            switch self {
            case .default:  nil
            case .vintage:  "Vintage"
            }
        }

        /// True when this choice requires File13 Pro. `.default` is always
        /// available; the vintage alternate is a Pro perk.
        public var requiresPro: Bool {
            switch self {
            case .default:  false
            case .vintage:  true
            }
        }
    }

    public enum RefreshSchedule: String, CaseIterable, Identifiable, Sendable {
        case manual, every5Minutes, hourly, daily

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .manual:         "Manual only"
            case .every5Minutes:  "Every 5 minutes"
            case .hourly:         "Every hour"
            case .daily:          "Every day"
            }
        }

        public var interval: TimeInterval? {
            switch self {
            case .manual:         nil
            case .every5Minutes:  5 * 60
            case .hourly:         60 * 60
            case .daily:          24 * 60 * 60
            }
        }
    }

    public enum DefaultInboxScope: Hashable, Sendable {
        case unified
        case account(UUID)

        public var rawString: String {
            switch self {
            case .unified:           return "unified"
            case .account(let uuid): return "account:\(uuid.uuidString)"
            }
        }

        public init?(rawString: String) {
            if rawString == "unified" {
                self = .unified
            } else if rawString.hasPrefix("account:"),
                      let uuid = UUID(uuidString: String(rawString.dropFirst("account:".count))) {
                self = .account(uuid)
            } else {
                return nil
            }
        }
    }

    /// Accent palette options. Each palette is an ordered list of colors that the
    /// app cycles through for "iconography" positions (sidebar icons, etc.). The
    /// first color of the palette is also used as the single-color "primary" tint
    /// (toolbar tint, button accents, unread-count text, etc.).
    ///
    /// - `app`: the brand colors from the asset catalog (`AccentColor`, `SecondaryAccent`).
    /// - `colorful`: the original Apple logo colors in their original order
    ///   (green, yellow, orange, red, purple, blue).
    public enum AccentPalette: String, CaseIterable, Identifiable, Sendable {
        case app, colorful

        public var id: String { rawValue }
        public var label: String {
            switch self { case .app: "Default"; case .colorful: "Colorful" }
        }

        /// Ordered palette colors. Always non-empty.
        public var colors: [Color] {
            switch self {
            case .app:
                // Asset-catalog colors live in the main app bundle, not in this
                // package's `Bundle.module`. We must look them up explicitly.
                return [
                    Color("AccentColor", bundle: .main),
                    Color("SecondaryAccent", bundle: .main),
                ]
            case .colorful:
                return [.green, .yellow, .orange, .red, .purple, .blue]
            }
        }

        /// The single-color "primary" accent used wherever we want one tint —
        /// `.tint()`, toggles, switches, dialog buttons, unread badges, etc.
        ///
        /// For `.colorful`, this is **blue** (the calmest of the Apple-logo
        /// colors), not green — green is too saturated to live underneath
        /// every control. The cycling order in `colors` is unchanged so the
        /// sidebar icons still appear in original Apple-logo sequence.
        public var primary: Color {
            switch self {
            case .app:      Color("AccentColor", bundle: .main)
            case .colorful: .blue
            }
        }

        /// Cycles through the palette by position. Negative indices wrap.
        public func color(at index: Int) -> Color {
            let count = colors.count
            guard count > 0 else { return .accentColor }
            let normalized = ((index % count) + count) % count
            return colors[normalized]
        }
    }

    public var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            CloudKVSync.markDirty(Keys.appearance, defaults: defaults)
        }
    }
    public var refreshSchedule: RefreshSchedule {
        didSet {
            defaults.set(refreshSchedule.rawValue, forKey: Keys.refreshSchedule)
            CloudKVSync.markDirty(Keys.refreshSchedule, defaults: defaults)
        }
    }
    public var accentPalette: AccentPalette {
        didSet {
            defaults.set(accentPalette.rawValue, forKey: Keys.accentPalette)
            CloudKVSync.markDirty(Keys.accentPalette, defaults: defaults)
        }
    }
    /// User's chosen app icon. Persists across launches; syncs across devices
    /// via `CloudKVSync` (a Pro user picking Colorful on one Mac sees it on
    /// their iPhone). The applier checks `LicenseStore.tier` before honoring
    /// an alternate — if a synced-in choice arrives on a device without Pro,
    /// the apply is a no-op and the bundle icon stays.
    public var appIcon: AppIconChoice {
        didSet {
            defaults.set(appIcon.rawValue, forKey: Keys.appIcon)
            CloudKVSync.markDirty(Keys.appIcon, defaults: defaults)
        }
    }
    /// Allowed undo-buffer durations (seconds). Reflected by the settings
    /// Picker and used by the property's `didSet` to reject out-of-band
    /// values. `0` means "no undo, commit immediately." Kept short
    /// deliberately: the banner is meant for catching slip clicks, not
    /// extended second-guessing — longer windows just delay server work.
    public static let allowedUndoBufferSeconds: [Int] = [0, 3, 5, 10, 15, 20, 30]

    public var undoBufferSeconds: Int {
        didSet {
            let allowed = Self.allowedUndoBufferSeconds
            if !allowed.contains(undoBufferSeconds) {
                // Snap to the nearest allowed value rather than refusing —
                // a clamp-style guarantee keeps the property total even
                // when an iCloud mirror pushes a stale or hostile number.
                let snapped = allowed.min(by: {
                    abs($0 - undoBufferSeconds) < abs($1 - undoBufferSeconds)
                }) ?? 3
                undoBufferSeconds = snapped
                return
            }
            defaults.set(undoBufferSeconds, forKey: Keys.undoBufferSeconds)
            CloudKVSync.markDirty(Keys.undoBufferSeconds, defaults: defaults)
        }
    }
    public var confirmBeforeDelete: Bool {
        didSet {
            defaults.set(confirmBeforeDelete, forKey: Keys.confirmBeforeDelete)
            CloudKVSync.markDirty(Keys.confirmBeforeDelete, defaults: defaults)
        }
    }
    public var confirmBeforeUnsubscribe: Bool {
        didSet {
            defaults.set(confirmBeforeUnsubscribe, forKey: Keys.confirmBeforeUnsubscribe)
            CloudKVSync.markDirty(Keys.confirmBeforeUnsubscribe, defaults: defaults)
        }
    }
    public var dryRunMode: Bool {
        didSet {
            defaults.set(dryRunMode, forKey: Keys.dryRunMode)
            CloudKVSync.markDirty(Keys.dryRunMode, defaults: defaults)
        }
    }
    public var softDeleteToTrash: Bool {
        didSet {
            defaults.set(softDeleteToTrash, forKey: Keys.softDeleteToTrash)
            CloudKVSync.markDirty(Keys.softDeleteToTrash, defaults: defaults)
        }
    }
    public var protectTransactionalFromDeletion: Bool {
        didSet {
            defaults.set(protectTransactionalFromDeletion, forKey: Keys.protectTransactionalFromDeletion)
            CloudKVSync.markDirty(Keys.protectTransactionalFromDeletion, defaults: defaults)
        }
    }
    public var protectVIPsFromRules: Bool {
        didSet {
            defaults.set(protectVIPsFromRules, forKey: Keys.protectVIPsFromRules)
            CloudKVSync.markDirty(Keys.protectVIPsFromRules, defaults: defaults)
        }
    }
    public var aiProvider: AIProviderKind {
        didSet {
            defaults.set(aiProvider.rawValue, forKey: Keys.aiProvider)
            CloudKVSync.markDirty(Keys.aiProvider, defaults: defaults)
        }
    }
    public var aiModel: String {
        didSet {
            defaults.set(aiModel, forKey: Keys.aiModel)
            CloudKVSync.markDirty(Keys.aiModel, defaults: defaults)
        }
    }
    /// Per-feature tuning overrides — custom prompt suffix, temperature, max-token cap, and
    /// optional provider/model override. Stored as a single JSON blob; missing entries fall
    /// back to `AIFeatureTuning()` defaults (empty suffix, nil overrides).
    public var aiFeatureTuning: [String: AIFeatureTuning] {
        didSet {
            if let data = try? JSONEncoder().encode(aiFeatureTuning) {
                defaults.set(data, forKey: Keys.aiFeatureTuning)
                CloudKVSync.markDirty(Keys.aiFeatureTuning, defaults: defaults)
            }
        }
    }
    public var autoCategorizeNewSenders: Bool {
        didSet {
            defaults.set(autoCategorizeNewSenders, forKey: Keys.autoCategorizeNewSenders)
            CloudKVSync.markDirty(Keys.autoCategorizeNewSenders, defaults: defaults)
        }
    }

    public var preferredMailClientBundleId: String? {
        didSet {
            if let id = preferredMailClientBundleId, !id.isEmpty {
                defaults.set(id, forKey: Keys.preferredMailClientBundleId)
            } else {
                defaults.removeObject(forKey: Keys.preferredMailClientBundleId)
            }
            CloudKVSync.markDirty(Keys.preferredMailClientBundleId, defaults: defaults)
            _resolvedMailClientCache = nil
        }
    }

    @ObservationIgnored
    private var _resolvedMailClientCache: (id: String, url: URL?)?

    public var preferredMailClientAppURL: URL? {
        guard let id = preferredMailClientBundleId, !id.isEmpty else { return nil }
        if let cached = _resolvedMailClientCache, cached.id == id { return cached.url }
        let url = MailClientDirectory.client(forBundleId: id)?.appURL
        _resolvedMailClientCache = (id, url)
        return url
    }

    public var preferredBrowserBundleId: String? {
        didSet {
            if let id = preferredBrowserBundleId, !id.isEmpty {
                defaults.set(id, forKey: Keys.preferredBrowserBundleId)
            } else {
                defaults.removeObject(forKey: Keys.preferredBrowserBundleId)
            }
            CloudKVSync.markDirty(Keys.preferredBrowserBundleId, defaults: defaults)
            _resolvedBrowserCache = nil
        }
    }

    public var defaultInboxScope: DefaultInboxScope {
        didSet {
            defaults.set(defaultInboxScope.rawString, forKey: Keys.defaultInboxScope)
            CloudKVSync.markDirty(Keys.defaultInboxScope, defaults: defaults)
        }
    }

    public var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin()
        }
    }

    /// Sync settings (accounts without passwords, rules, AI preferences,
    /// triage state) across the user's Macs via `NSUbiquitousKeyValueStore`.
    ///
    /// Email headers, message contents, and the local SwiftData cache are
    /// **never** uploaded — see `CloudKVSync.allowlist` for the explicit set
    /// of keys that cross the iCloud boundary. The mirror is gated on this
    /// toggle so users on Apple Foundation Models who picked File13 for
    /// strict on-device behavior can keep iCloud disabled and the app
    /// behaves identically to before this feature existed.
    public var iCloudSyncEnabled: Bool {
        didSet {
            defaults.set(iCloudSyncEnabled, forKey: Keys.iCloudSyncEnabled)
            CloudKVSync.markDirty(Keys.iCloudSyncEnabled, defaults: defaults)
        }
    }

    /// Sync IMAP and AI API credentials across the user's Macs via Apple's
    /// **iCloud Keychain** (system-level), independent of File13's own
    /// settings-sync toggle. Default off — the most-private posture is for
    /// passwords to stay on one device.
    ///
    /// Per-device on purpose. We don't propagate this preference through
    /// `CloudKVSync` so the user can opt in on each Mac individually; iCloud
    /// Keychain itself must also be enabled in System Settings for sync to
    /// actually happen.
    public var iCloudKeychainSyncEnabled: Bool {
        didSet {
            defaults.set(iCloudKeychainSyncEnabled, forKey: Keys.iCloudKeychainSyncEnabled)
            KeychainStore.iCloudSyncEnabled = iCloudKeychainSyncEnabled
            iCloudKeychainSyncMigrator?(iCloudKeychainSyncEnabled)
        }
    }

    /// Closure invoked when `iCloudKeychainSyncEnabled` flips, so the app can
    /// rewrite already-stored credentials with the new sync mode. Set by
    /// `File13App` at launch; nil in tests where there's nothing to migrate.
    /// Sender is the new value of the toggle.
    @ObservationIgnored
    public var iCloudKeychainSyncMigrator: ((Bool) -> Void)?

    private func applyLaunchAtLogin() {
        #if os(macOS)
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            let actual = SMAppService.mainApp.status == .enabled
            if actual != launchAtLogin {
                defaults.set(actual, forKey: Keys.launchAtLogin)
                _launchAtLoginRollback = actual
            }
        }
        #endif
        // iOS / iPadOS: no user-controllable launch-at-login concept — the
        // property persists for cross-platform settings parity but is inert.
    }

    @ObservationIgnored
    private var _launchAtLoginRollback: Bool? {
        didSet {
            if let v = _launchAtLoginRollback {
                _launchAtLoginRollback = nil
                launchAtLogin = v
            }
        }
    }

    @ObservationIgnored
    private var _resolvedBrowserCache: (id: String, url: URL?)?

    public var preferredBrowserAppURL: URL? {
        guard let id = preferredBrowserBundleId, !id.isEmpty else { return nil }
        if let cached = _resolvedBrowserCache, cached.id == id { return cached.url }
        let url = BrowserDirectory.browser(forBundleId: id)?.appURL
        _resolvedBrowserCache = (id, url)
        return url
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = SharedDefaults.suite) {
        self.defaults = defaults
        self.appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "")
            ?? .system
        self.refreshSchedule = RefreshSchedule(rawValue: defaults.string(forKey: Keys.refreshSchedule) ?? "")
            ?? .manual
        self.accentPalette = AccentPalette(rawValue: defaults.string(forKey: Keys.accentPalette) ?? "")
            ?? .app
        self.appIcon = AppIconChoice(rawValue: defaults.string(forKey: Keys.appIcon) ?? "")
            ?? .default
        // The previous accent setting was a single-tone picker
        // (`File13.accentTone`). The new palette system supersedes it; clear
        // the old key so it doesn't linger forever in user defaults.
        defaults.removeObject(forKey: "File13.accentTone")
        // Default 3s: short enough that the user isn't waiting for server
        // commits to finish, long enough to catch a misclick. Existing
        // installs keep whatever value they had — we only fall through to
        // the default when the key has never been set.
        self.undoBufferSeconds = (defaults.object(forKey: Keys.undoBufferSeconds) as? Int) ?? 3
        self.confirmBeforeDelete = (defaults.object(forKey: Keys.confirmBeforeDelete) as? Bool) ?? true
        self.confirmBeforeUnsubscribe = (defaults.object(forKey: Keys.confirmBeforeUnsubscribe) as? Bool) ?? true
        self.dryRunMode = defaults.bool(forKey: Keys.dryRunMode)
        // Default to "Move to Trash". `\Deleted` + EXPUNGE on Gmail only
        // removes the message's label from the current folder — the message
        // stays in [Gmail]/All Mail and never appears in Trash, which makes
        // "where did my deletes go?" hard to answer. Routing through the
        // Trash folder gives every provider (Gmail included) the obvious
        // behavior: deleted mail lands in Trash and is recoverable until
        // the server clears it.
        self.softDeleteToTrash = (defaults.object(forKey: Keys.softDeleteToTrash) as? Bool) ?? true
        self.protectTransactionalFromDeletion =
            (defaults.object(forKey: Keys.protectTransactionalFromDeletion) as? Bool) ?? true
        self.protectVIPsFromRules =
            (defaults.object(forKey: Keys.protectVIPsFromRules) as? Bool) ?? true
        self.aiProvider = AIProviderKind(rawValue: defaults.string(forKey: Keys.aiProvider) ?? "")
            ?? .appleFoundation
        self.aiModel = defaults.string(forKey: Keys.aiModel) ?? ""
        self.autoCategorizeNewSenders =
            (defaults.object(forKey: Keys.autoCategorizeNewSenders) as? Bool) ?? false
        if let data = defaults.data(forKey: Keys.aiFeatureTuning),
           let decoded = try? JSONDecoder().decode([String: AIFeatureTuning].self, from: data) {
            self.aiFeatureTuning = decoded
        } else {
            self.aiFeatureTuning = [:]
        }
        self.preferredMailClientBundleId = defaults.string(forKey: Keys.preferredMailClientBundleId)
        self.preferredBrowserBundleId = defaults.string(forKey: Keys.preferredBrowserBundleId)
        self.defaultInboxScope = DefaultInboxScope(rawString: defaults.string(forKey: Keys.defaultInboxScope) ?? "")
            ?? .unified
        #if os(macOS)
        let registered = SMAppService.mainApp.status == .enabled
        let stored = (defaults.object(forKey: Keys.launchAtLogin) as? Bool) ?? false
        self.launchAtLogin = registered ? true : stored
        if !registered && stored {
            defaults.set(false, forKey: Keys.launchAtLogin)
        }
        #else
        // No SMAppService on iOS; the toggle is a no-op and persisted state alone wins.
        self.launchAtLogin = (defaults.object(forKey: Keys.launchAtLogin) as? Bool) ?? false
        #endif
        // iCloud sync is opt-in. Default off so users who installed File13
        // for its strict on-device privacy posture aren't surprised.
        self.iCloudSyncEnabled = defaults.bool(forKey: Keys.iCloudSyncEnabled)
        self.iCloudKeychainSyncEnabled = defaults.bool(forKey: Keys.iCloudKeychainSyncEnabled)
        // Mirror to KeychainStore so the very first write after launch — which
        // can happen before the user touches Settings — uses the right mode.
        KeychainStore.iCloudSyncEnabled = self.iCloudKeychainSyncEnabled
    }

    /// Clear the persisted general/behavior settings so they fall back to
    /// their built-in defaults, marking each key dirty so the reset
    /// propagates through iCloud settings sync. This is the set of keys
    /// `file13 config import/export` round-trips; AI config, triage state,
    /// accounts, and credentials are deliberately untouched.
    ///
    /// Clears the backing `UserDefaults` keys directly (the getters default
    /// on absence). Intended for the headless config-import `--mode replace`
    /// path, where the process re-reads state on next launch; an in-memory
    /// store should be re-initialized to reflect the reset.
    public func resetToDefaults() {
        let keys = [
            Keys.appearance, Keys.refreshSchedule, Keys.accentPalette,
            Keys.undoBufferSeconds, Keys.confirmBeforeDelete, Keys.confirmBeforeUnsubscribe,
            Keys.dryRunMode, Keys.softDeleteToTrash, Keys.protectTransactionalFromDeletion,
            Keys.protectVIPsFromRules, Keys.autoCategorizeNewSenders, Keys.launchAtLogin,
            Keys.defaultInboxScope, Keys.preferredMailClientBundleId, Keys.preferredBrowserBundleId,
        ]
        for key in keys {
            defaults.removeObject(forKey: key)
            CloudKVSync.markDirty(key, defaults: defaults)
        }
    }

    private enum Keys {
        static let appearance           = "File13.appearance"
        static let refreshSchedule      = "File13.refreshSchedule"
        static let accentPalette        = "File13.accentPalette"
        static let appIcon              = "File13.appIcon.v1"
        static let undoBufferSeconds    = "File13.undoBufferSeconds"
        static let confirmBeforeDelete  = "File13.confirmBeforeDelete"
        static let confirmBeforeUnsubscribe = "File13.confirmBeforeUnsubscribe"
        static let dryRunMode           = "File13.dryRunMode"
        static let softDeleteToTrash    = "File13.softDeleteToTrash"
        // The Swift property is `protectTransactionalFromDeletion`, but we keep the original
        // UserDefaults key so users who set this preference under the previous name keep it.
        static let protectTransactionalFromDeletion = "File13.protectTransactionalFromRules"
        static let protectVIPsFromRules = "File13.protectVIPsFromRules"
        static let aiProvider              = "File13.aiProvider"
        static let aiModel                 = "File13.aiModel"
        static let autoCategorizeNewSenders = "File13.autoCategorizeNewSenders"
        static let aiFeatureTuning             = "File13.aiFeatureTuning.v1"
        static let preferredMailClientBundleId = "File13.preferredMailClientBundleId"
        static let preferredBrowserBundleId    = "File13.preferredBrowserBundleId"
        static let defaultInboxScope           = "File13.defaultInboxScope"
        static let launchAtLogin               = "File13.launchAtLogin"
        static let iCloudSyncEnabled           = "File13.iCloudSyncEnabled"
        static let iCloudKeychainSyncEnabled   = "File13.iCloudKeychainSyncEnabled"
    }

    // MARK: - AI feature tuning

    /// Look up the tuning for a feature. Returns a fresh `AIFeatureTuning()` when the user
    /// hasn't touched the dials for this feature, so call sites never get nil.
    public func tuning(for feature: AIFeature) -> AIFeatureTuning {
        aiFeatureTuning[feature.rawValue] ?? AIFeatureTuning()
    }

    /// Persist tuning for a feature. Removes the entry entirely when `tuning.isDefault`, so
    /// the JSON blob doesn't accumulate empty rows for features the user never customized.
    public func setTuning(_ tuning: AIFeatureTuning, for feature: AIFeature) {
        var copy = aiFeatureTuning
        if tuning.isDefault {
            copy.removeValue(forKey: feature.rawValue)
        } else {
            copy[feature.rawValue] = tuning
        }
        aiFeatureTuning = copy
    }
}

// MARK: - Environment

private struct AccentPaletteKey: EnvironmentKey {
    static let defaultValue: SettingsStore.AccentPalette = .app
}

extension EnvironmentValues {
    /// The user's chosen accent palette. Views that color icons or badges should
    /// read this and call `palette.primary` (single tint) or `palette.color(at:)`
    /// (positional cycling for sidebar icons).
    public var accentPalette: SettingsStore.AccentPalette {
        get { self[AccentPaletteKey.self] }
        set { self[AccentPaletteKey.self] = newValue }
    }
}
