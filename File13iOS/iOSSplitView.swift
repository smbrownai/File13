import File13Core
import SwiftUI

/// Two-column layout for iPad regular width: accounts + Settings in the
/// sidebar, the selected item's content in the detail column. The whole
/// `iOSRootView` switches between this and the iPhone `TabView` based on
/// `horizontalSizeClass`, so a user dragging the app into Split View with
/// another iPad app gets the compact UI as soon as the size class flips.
struct iOSSplitView: View {
    @Bindable var accountStore: AccountStore
    @Bindable var settings: SettingsStore
    @Bindable var ruleStore: RuleStore
    @Bindable var categoryStore: SenderCategoryStore
    @Bindable var vipStore: VIPStore
    @Bindable var suggestionDismissals: SuggestionDismissalStore
    @Bindable var inbox: InboxStore
    let accountConnector: AccountConnector
    @Bindable var license: LicenseStore

    @State private var selection: SidebarItem? = nil
    @State private var showAddAccount = false
    @State private var showSoftPaywall = false

    enum SidebarItem: Hashable {
        case account(UUID)
        case rules
        case settings
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $showAddAccount) {
            iOSAddAccountSheet(accountStore: accountStore)
        }
        .sheet(isPresented: $showSoftPaywall) {
            iOSPaywallSheet(license: license)
        }
        // Default selection on first launch: the first account, if any.
        // Otherwise nil so the detail column shows the placeholder + add-CTA.
        .task {
            if selection == nil, let first = accountStore.accounts.first {
                selection = .account(first.id)
            }
        }
        // If the user deletes the currently-selected account, drop the
        // selection so the detail column doesn't keep rendering against a
        // stale id.
        .onChange(of: accountStore.accounts.map(\.id)) { _, ids in
            if case .account(let selected) = selection, !ids.contains(selected) {
                selection = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Mailboxes") {
                if accountStore.accounts.isEmpty {
                    Text("None yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(accountStore.accounts) { account in
                        accountRow(account)
                            .tag(SidebarItem.account(account.id))
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let id = accountStore.accounts[index].id
                            Task { await inbox.disconnect(accountId: id) }
                            accountStore.remove(id)
                        }
                    }
                }
            }
            Section {
                Label("Rules", systemImage: "wand.and.stars")
                    .tag(SidebarItem.rules)
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
        }
        .navigationTitle("File13")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if license.canAddAccount(currentCount: accountStore.accounts.count) {
                        showAddAccount = true
                    } else {
                        showSoftPaywall = true
                    }
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.displayName)
                .font(.headline)
            Text(account.address)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .account(let id):
            if let account = accountStore.accounts.first(where: { $0.id == id }) {
                NavigationStack {
                    iOSMessageListView(
                        account: account,
                        inbox: inbox,
                        settings: settings,
                        categoryStore: categoryStore,
                        accountConnector: accountConnector
                    )
                }
                // Re-render on account switch so the message list's `.task`
                // fires again for the new account.
                .id(id)
            } else {
                placeholder
            }
        case .rules:
            iOSRulesTab(
                ruleStore: ruleStore,
                inbox: inbox,
                settings: settings,
                categoryStore: categoryStore,
                vipStore: vipStore,
                suggestionDismissals: suggestionDismissals
            )
        case .settings:
            iOSSettingsTab(
                settings: settings,
                accountStore: accountStore,
                inbox: inbox,
                license: license
            )
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("Select a mailbox", systemImage: "tray.full")
        } description: {
            if accountStore.accounts.isEmpty {
                Text("Add your first mailbox to start triaging. File13 fetches headers only — never message bodies.")
                    .multilineTextAlignment(.center)
            } else {
                Text("Pick a mailbox from the sidebar.")
            }
        } actions: {
            if accountStore.accounts.isEmpty {
                Button("Add Mailbox") {
                    showAddAccount = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
