import File13Core
import SwiftUI

/// License & purchase status tab. Three pieces of information matter to
/// the user here: which tier they're on, which Apple platform their free
/// tier is bound to (if they're on free), and how to upgrade or restore.
struct LicenseSettingsView: View {
    @Bindable var license: LicenseStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Current tier") {
                    tierBadge
                }
            } header: {
                Text("License").font(.headline)
            } footer: {
                Text("File13 is free for one mailbox on Mac, iPhone, and iPad. Pro unlocks unlimited mailboxes and the bundled command-line tool, with one lifetime purchase and no subscription.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if license.tier == .free {
                Section {
                    Button {
                        Task {
                            await license.purchase()
                        }
                    } label: {
                        if license.isWorking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Processing…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text(license.displayPrice.map { "Upgrade to Pro — \($0)" } ?? "Upgrade to Pro")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(license.isWorking)

                    Button {
                        Task { await license.restore() }
                    } label: {
                        Text("Restore Purchase").frame(maxWidth: .infinity)
                    }
                    .disabled(license.isWorking)
                } header: {
                    Text("Upgrade").font(.headline)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let error = license.purchaseError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Refunds are handled by Apple. Request within 90 days from your purchase history on the App Store.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            } else {
                Section {
                    Button {
                        Task { await license.restore() }
                    } label: {
                        Text("Refresh Purchase Status").frame(maxWidth: .infinity)
                    }
                    .disabled(license.isWorking)
                } header: {
                    Text("Manage").font(.headline)
                } footer: {
                    Text("File13 Pro is active on this Apple ID. Family Sharing is enabled, so up to six family members can use Pro on their own devices.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }

    private var tierBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: license.tier == .pro ? "checkmark.seal.fill" : "circle.dotted")
                .foregroundStyle(license.tier == .pro ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(license.tier == .pro ? "Pro" : "Free")
                .fontWeight(.semibold)
        }
    }
}
