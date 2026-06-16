import File13Core
import SwiftUI

/// Settings tab — iOS counterpart to the Mac app's Settings window. Sub-pages
/// mirror the Mac tab structure (General / Actions & Safety / AI Assistant);
/// account list, license, and About stay inline at the root.
struct iOSSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var accountStore: AccountStore
    @Bindable var inbox: InboxStore
    @Bindable var license: LicenseStore

    @State private var showPaywall = false
    @State private var showAddAccount = false

    var body: some View {
        NavigationStack {
            Form {
                accountsSection
                settingsLinksSection
                licenseSection
                aboutSection
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showPaywall) {
                iOSPaywallSheet(license: license)
            }
            .sheet(isPresented: $showAddAccount) {
                iOSAddAccountSheet(accountStore: accountStore)
            }
        }
    }

    private var accountsSection: some View {
        Section {
            if accountStore.accounts.isEmpty {
                Text("No mailboxes added yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accountStore.accounts) { account in
                    NavigationLink {
                        iOSAccountDetailView(
                            accountStore: accountStore,
                            inbox: inbox,
                            accountId: account.id
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                            Text(account.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let id = accountStore.accounts[index].id
                        Task { await inbox.disconnect(accountId: id) }
                        accountStore.remove(id)
                    }
                }
            }

            Button {
                if license.canAddAccount(currentCount: accountStore.accounts.count) {
                    showAddAccount = true
                } else {
                    showPaywall = true
                }
            } label: {
                Label("Add Mailbox", systemImage: "plus")
            }
        } header: {
            Text("Mailboxes")
        } footer: {
            if !accountStore.accounts.isEmpty {
                Text("Swipe a mailbox to remove it. Removing disconnects the account and clears its cached headers from this device. Your messages on the server are untouched.")
            }
        }
    }

    private var settingsLinksSection: some View {
        Section {
            NavigationLink {
                iOSGeneralSettingsView(settings: settings, accountStore: accountStore, license: license)
            } label: {
                Label("General", systemImage: "gearshape")
            }
            NavigationLink {
                iOSActionsSafetySettingsView(settings: settings)
            } label: {
                Label("Actions & Safety", systemImage: "shield.lefthalf.filled")
            }
            NavigationLink {
                iOSAISettingsView(settings: settings)
            } label: {
                Label("AI Assistant", systemImage: "sparkles")
            }
        }
    }

    private var licenseSection: some View {
        Section {
            HStack {
                Text("Plan")
                Spacer()
                Text(license.tier == .pro ? "File13 Pro" : "Free")
                    .foregroundStyle(.secondary)
            }
            if license.tier != .pro {
                Button("Upgrade to Pro") { showPaywall = true }
            }
            Button {
                Task { await license.restore() }
            } label: {
                if license.isWorking {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Restoring…")
                    }
                } else {
                    Text("Restore Purchase")
                }
            }
            .disabled(license.isWorking)
            if let error = license.purchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("License")
        } footer: {
            Text("One-time purchase, Universal across Mac, iPhone, and iPad. Family Sharing supported.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: marketingVersion)
        }
    }

    private var marketingVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
