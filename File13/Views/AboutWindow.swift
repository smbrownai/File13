import SwiftUI
import AppKit
import File13Core

/// Scene identifier for the About window.
let AboutWindowID = "file13.about"

private let GitHubURL = URL.verified("https://github.com/smbrownai/file13")
private let SupportURL = URL.verified("mailto:dev@snxt.ai")
private let PrivacyPolicyURL = URL.verified("https://github.com/smbrownai/file13/blob/main/docs/privacy.html")
private let LicenseURL = URL.verified("https://github.com/smbrownai/file13/blob/main/LICENSE")

/// Replaces the default macOS About menu item with one that opens our
/// custom window instead of AppKit's panel. Lives in its own `Commands`
/// struct so it can read `@Environment(\.openWindow)`.
struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About File13") {
                openWindow(id: AboutWindowID)
            }
        }
    }
}

struct AboutWindowView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }

    private var copyright: String {
        (Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String)
            ?? "Copyright © 2026 Shawn M. Brown. MIT License."
    }

    var body: some View {
        VStack(spacing: 16) {
            appIcon
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("File13")
                    .font(.system(size: 26, weight: .bold))
                Text("Version \(version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("File13 is an email cleaner. File13 doesn't replace your email app. It gives you control over it.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Privacy is paramount")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Your email is yours, not ours.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(
                Capsule().fill(Color.green.opacity(0.08))
            )
            .overlay(
                Capsule().stroke(Color.green.opacity(0.25))
            )

            HStack(spacing: 16) {
                Link("Privacy Policy", destination: PrivacyPolicyURL)
                Text("·").foregroundStyle(.tertiary)
                Link("License", destination: LicenseURL)
                Text("·").foregroundStyle(.tertiary)
                Link("Support", destination: SupportURL)
                Text("·").foregroundStyle(.tertiary)
                Link("GitHub", destination: GitHubURL)
            }
            .font(.system(size: 12))

            Text(copyright)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(AboutWindowChrome())
    }

    @ViewBuilder private var appIcon: some View {
        if let image = NSImage(named: "AppIcon") {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "envelope.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.tint)
        }
    }
}

/// Strips the title bar text and turns on full-size content so the About
/// window looks like a panel rather than a document window. Also pins it
/// to center on every open — same trick the Settings window uses.
private struct AboutWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.setFrameAutosaveName("")
            window.center()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
