// swift-tools-version: 6.2
import PackageDescription

/// Shared library used by every File13 binary — the macOS GUI app, the iPhone/iPad
/// app, and the headless `file13` CLI.
///
/// What's in scope for this package: every type that needs to exist in *both* binaries —
/// stores, AI providers, IMAP layer, models, helpers. Anything SwiftUI- or AppKit-rendered
/// stays in the GUI app target. Code that is fundamentally platform-specific (Launch
/// Services / `NSWorkspace` handlers, etc.) is guarded with `#if os(macOS)` so the iOS
/// build still links.
///
/// The package is consumed three ways:
///   - The File13 macOS Xcode app target adds it as a Local Package dependency.
///   - The File13 iOS Xcode app target adds it the same way.
///   - The cli/Package.swift declares a `path:` dependency on `../Packages/File13Core`.
let package = Package(
    name: "File13Core",
    platforms: [
        // Mirrors the GUI app's deployment target (Apple Foundation Models + macOS 26 SDK).
        .macOS(.v26),
        // iOS app target — iPhone + iPad. Same Foundation Models / SwiftData baseline.
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "File13Core",
            targets: ["File13Core"]
        )
    ],
    dependencies: [
        // Vendored IMAP client (NIO-based). Same package the GUI app already links.
        // Path is relative to this Package.swift.
        .package(path: "../../Vendor/SwiftMail")
    ],
    targets: [
        .target(
            name: "File13Core",
            dependencies: [
                .product(name: "SwiftMail", package: "SwiftMail")
            ],
            resources: [
                // Vendored from disposable-email-domains/disposable-email-domains (CC0).
                // Loaded lazily by `DisposableSenderDetector` and consulted only locally —
                // sender domains are never sent off-device for this check. Refresh via
                // `scripts/update-disposable-domains.sh`.
                .copy("Resources/disposable_email_blocklist.conf")
            ],
            swiftSettings: [
                // Swift 6 strict-concurrency checking. Catches data-race
                // hazards (cross-actor reads of mutable state, missing
                // Sendable conformances, etc.) at compile time rather
                // than at runtime under load.
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
