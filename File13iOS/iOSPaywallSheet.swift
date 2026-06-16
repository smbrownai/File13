import File13Core
import SwiftUI

/// iOS counterpart to the macOS `PaywallSheet`. Same product and copy,
/// laid out for compact width. Always dismissible.
struct iOSPaywallSheet: View {
    @Bindable var license: LicenseStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    featureList
                    if let error = license.purchaseError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    Spacer(minLength: 0)
                    buttons
                }
                .padding(24)
            }
            .navigationTitle("Upgrade to Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            Text("File13 is free for one mailbox on Mac, iPhone, and iPad. Pro unlocks the rest — once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("envelope.badge", "Connect unlimited mailboxes")
            row("terminal.fill", "Bundled `file13` command-line tool")
            row("person.3.fill", "Family Sharing with up to 6 family members")
            row("arrow.uturn.backward.circle", "Full App Store refund window")
            row("hand.thumbsup.fill", "One-time payment, no subscription")
        }
    }

    private func row(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    await license.purchase()
                    if license.tier == .pro { dismiss() }
                }
            } label: {
                if license.isWorking {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Processing…")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                } else {
                    Text(license.displayPrice.map { "Upgrade to Pro — \($0)" } ?? "Upgrade to Pro")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(license.isWorking)

            Button {
                Task {
                    await license.restore()
                    if license.tier == .pro { dismiss() }
                }
            } label: {
                Text("Restore Purchase")
                    .frame(maxWidth: .infinity)
            }
            .disabled(license.isWorking)
        }
    }
}
