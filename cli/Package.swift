// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "file13",
    platforms: [
        // Matches the GUI app's deployment target. Apple Foundation Models'
        // round-trip API surface for `String` requires the macOS 26 SDK.
        .macOS(.v26)
    ],
    products: [
        .executable(name: "file13", targets: ["file13"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // Local path dependency — the same Swift Package the GUI app imports. Keeps the CLI
        // and GUI on a single source of truth for stores, AI, and IMAP types.
        .package(path: "../Packages/File13Core")
    ],
    targets: [
        .executableTarget(
            name: "file13",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "File13Core", package: "File13Core")
            ],
            swiftSettings: [
                // Matches File13Core's setting. Strict-concurrency
                // checking surfaces data-race hazards (cross-actor
                // mutable state, missing Sendable conformances) at
                // compile time. The CLI's subcommands are mostly
                // @MainActor and short-lived, but the strict pass
                // protects against drift as more async work lands.
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "file13Tests",
            dependencies: ["file13"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
