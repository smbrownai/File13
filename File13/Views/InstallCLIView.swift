import AppKit
import File13Core
import Foundation
import SwiftUI

extension Notification.Name {
    /// Broadcast when the user picks **Edit → Install File13 CLI…**.
    /// `ContentView` listens and flips its sheet-presented state. Posted
    /// from a `.commands` closure in `File13App`, which can't reach the
    /// ContentView state directly.
    static let installFile13CLI = Notification.Name("installFile13CLI")
}

/// Sheet that points the user at the Homebrew tap for the `file13` CLI.
/// The MAS bundle does **not** ship the CLI binary — that was the previous
/// strategy and it ran headfirst into the App Store sandbox-requires-on-
/// every-embedded-binary rule, which made the binary unrunnable from a
/// Terminal symlink (sandbox-claiming binary outside its host bundle gets
/// SIGTRAPed at launch). The CLI now lives in a separate Apple Developer
/// ID-signed + notarized binary, distributed via Homebrew.
///
/// Pro-gated: free-tier users see an Upgrade panel instead of the install
/// command. The body re-renders if the StoreKit observer flips `tier` to
/// `.pro` while the sheet is open, so a successful purchase converts the
/// sheet in place.
struct InstallCLIView: View {
    @Bindable var license: LicenseStore
    @Environment(\.dismiss) private var dismiss

    /// One-line shell invocation users can paste into Terminal. Pinned to
    /// the `smbrownai/file13` tap so a user can install without
    /// remembering the tap name first; `brew install` auto-taps when the
    /// formula is referenced by its fully-qualified name.
    private let brewCommand = "brew install smbrownai/file13/file13"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if license.tier == .pro {
                proContent
            } else {
                lockedContent
            }
        }
        .padding(20)
        .frame(width: 540)
        .frame(minHeight: 360)
    }

    // MARK: - Pro content

    @ViewBuilder
    private var proContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Install the File13 CLI").font(.title3).bold()
                Text("The `file13` command-line tool ships as a separate Homebrew formula so it can run as a normal Terminal binary. Run this once and `file13 --help` works in any shell.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Install command").font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(brewCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                Button {
                    copyToClipboard(brewCommand)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy command")
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Label("Re-add your mailbox(es) via `file13 accounts add`", systemImage: "key.fill")
                .font(.callout)
                .foregroundStyle(.primary)
            Text("The CLI cannot read the GUI app's Keychain entries — that's a sandbox boundary Homebrew binaries can't cross. Settings, rules, and your Pro license carry over automatically; just re-enter the IMAP password once per mailbox in Terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

        Text("Don't have Homebrew? Install it from [brew.sh](https://brew.sh), then run the command above. After install, `file13 doctor` confirms the App Group container is reachable.")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

        Spacer(minLength: 0)
        HStack {
            Spacer()
            Button("Open Homebrew Site") {
                if let url = URL(string: "https://brew.sh") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Locked content

    @ViewBuilder
    private var lockedContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("File13 CLI is a Pro feature").font(.title3).bold()
                Text("The `file13` command-line tool unlocks with File13 Pro. Use it to add mailboxes, run rules, and triage from your shell or in scripts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            featureRow("envelope.badge", "Add mailboxes from the command line")
            featureRow("playpause.fill", "Run rules on demand or from cron / Shortcuts")
            featureRow("text.magnifyingglass", "Search and filter headers without launching the GUI")
            featureRow("hand.thumbsup.fill", "One-time purchase, no subscription")
        }
        .padding(.vertical, 4)

        if let error = license.purchaseError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .lineLimit(3, reservesSpace: false)
        }

        Spacer(minLength: 0)
        HStack {
            Button("Maybe Later") { dismiss() }
            Spacer()
            Button("Restore Purchase") {
                Task { await license.restore() }
            }
            .disabled(license.isWorking)
            Button {
                Task { await license.purchase() }
            } label: {
                if license.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Upgrade to Pro")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(license.isWorking)
        }
    }

    private func featureRow(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 22, alignment: .center)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyToClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
