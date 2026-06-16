import File13Core
import SwiftUI

/// The single paywall surface, presented when the user tries a Pro-only
/// action (today: adding a second mailbox; running the `file13` CLI).
/// Always dismissible — File13 is fully functional on the free tier and
/// the user should never be cornered.
struct PaywallSheet: View {
    @Bindable var license: LicenseStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            featureList
            if let error = license.purchaseError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .lineLimit(3, reservesSpace: false)
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(24)
        .frame(width: 460)
        .frame(minHeight: 420)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Upgrade to File13 Pro")
                    .font(.title2).bold()
                Text("File13 is free for one mailbox on Mac, iPhone, and iPad. Pro unlocks the rest — once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("envelope.badge", "Connect unlimited mailboxes")
            row("terminal.fill", "Bundled `file13` command-line tool")
            row("person.3.fill", "Family Sharing with up to 6 family members")
            row("arrow.uturn.backward.circle", "Full App Store refund window if you change your mind")
            row("hand.thumbsup.fill", "One-time payment, no subscription, no recurring charge")
        }
        .padding(.vertical, 4)
    }

    private func row(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 22, alignment: .center)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    await license.purchase()
                    if license.tier == .pro {
                        dismiss()
                    }
                }
            } label: {
                if license.isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Processing…")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                } else {
                    Text(license.displayPrice.map { "Upgrade to Pro — \($0)" } ?? "Upgrade to Pro")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(license.isWorking)

            HStack {
                Button {
                    Task {
                        await license.restore()
                        if license.tier == .pro {
                            dismiss()
                        }
                    }
                } label: {
                    Text("Restore Purchase")
                        .frame(maxWidth: .infinity)
                }
                .disabled(license.isWorking)
                Button("Not now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
