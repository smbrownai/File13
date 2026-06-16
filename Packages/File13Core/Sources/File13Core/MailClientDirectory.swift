import Foundation
#if os(macOS)
import AppKit
#endif

/// One installed app that registered itself with Launch Services as a handler for some URL
/// scheme — used for both the `mailto:` mail-client picker and the `https:` browser picker.
///
/// The struct itself is cross-platform; only the `AppHandlerDirectory` lookups below depend
/// on `NSWorkspace` and are gated behind `#if os(macOS)`. On iOS, the same data structures
/// exist (Open-in pickers / Universal Links could populate them in a future iOS pass), but
/// the auto-discovery surface is macOS-only.
public struct OpenableApp: Identifiable, Hashable, Sendable {
    /// Bundle identifier — stable across launches and what we persist in settings.
    public let bundleIdentifier: String
    public let displayName: String
    public let appURL: URL

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, displayName: String, appURL: URL) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.appURL = appURL
    }
}

#if os(macOS)
/// Generic Launch Services helper.
@MainActor
public enum AppHandlerDirectory {
    public static func handlers(for url: URL) -> [OpenableApp] {
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: url)
        var seen: Set<String> = []
        var apps: [OpenableApp] = []
        for url in appURLs {
            guard let app = makeApp(at: url) else { continue }
            if seen.insert(app.bundleIdentifier).inserted { apps.append(app) }
        }
        return apps.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    public static func defaultHandler(for url: URL) -> OpenableApp? {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return makeApp(at: appURL)
    }

    private static func makeApp(at url: URL) -> OpenableApp? {
        guard let bundle = Bundle(url: url),
              let bid = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return OpenableApp(bundleIdentifier: bid, displayName: name, appURL: url)
    }
}

/// Apps that handle `mailto:` — Mail, Spark, Airmail, etc.
@MainActor
public enum MailClientDirectory {
    private static let probe = URL.verified("mailto:")

    public static func installedClients() -> [OpenableApp] { AppHandlerDirectory.handlers(for: probe) }
    public static func systemDefault() -> OpenableApp? { AppHandlerDirectory.defaultHandler(for: probe) }
    public static func client(forBundleId id: String) -> OpenableApp? {
        installedClients().first { $0.bundleIdentifier == id }
    }
}

/// Apps that handle `https:` — Safari, Chrome, Arc, Firefox, etc.
@MainActor
public enum BrowserDirectory {
    private static let probe = URL.verified("https://example.com")

    public static func installedBrowsers() -> [OpenableApp] { AppHandlerDirectory.handlers(for: probe) }
    public static func systemDefault() -> OpenableApp? { AppHandlerDirectory.defaultHandler(for: probe) }
    public static func browser(forBundleId id: String) -> OpenableApp? {
        installedBrowsers().first { $0.bundleIdentifier == id }
    }
}
#else
// iOS / iPadOS: Launch Services-style enumeration isn't available. The system "Open in…"
// sheet is the user-facing analog. We stub the directories so call sites can still compile
// — callers wrap usage in `#if os(macOS)` or fall back gracefully when the lists are empty.
@MainActor
public enum AppHandlerDirectory {
    public static func handlers(for url: URL) -> [OpenableApp] { [] }
    public static func defaultHandler(for url: URL) -> OpenableApp? { nil }
}

@MainActor
public enum MailClientDirectory {
    public static func installedClients() -> [OpenableApp] { [] }
    public static func systemDefault() -> OpenableApp? { nil }
    public static func client(forBundleId id: String) -> OpenableApp? { nil }
}

@MainActor
public enum BrowserDirectory {
    public static func installedBrowsers() -> [OpenableApp] { [] }
    public static func systemDefault() -> OpenableApp? { nil }
    public static func browser(forBundleId id: String) -> OpenableApp? { nil }
}
#endif
