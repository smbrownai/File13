import File13Core
import SwiftUI

/// Mailbox tab — connected accounts on top, per-account message list on tap.
/// Multi-select + Delete / Archive live on the message list view itself; this
/// tab is just navigation + paywall enforcement on add-account.
///
/// Honors `settings.defaultInboxScope` once at launch: if the user picked a
/// specific account in Settings → General → Default Mailbox, we push that
/// account onto the navigation stack on first appearance so they land
/// straight on its messages instead of the account-list screen.
struct iOSMailboxesTab: View {
    @Bindable var accountStore: AccountStore
    @Bindable var settings: SettingsStore
    @Bindable var categoryStore: SenderCategoryStore
    @Bindable var inbox: InboxStore
    let accountConnector: AccountConnector
    @Bindable var license: LicenseStore

    @State private var showAddAccount = false
    @State private var showSoftPaywall = false
    @State private var path = NavigationPath()
    @State private var hasAppliedDefaultScope = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if accountStore.accounts.isEmpty {
                    emptyState
                } else {
                    accountList
                }
            }
            .navigationTitle("Mailboxes")
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
            .navigationDestination(for: Account.self) { account in
                iOSMessageListView(
                    account: account,
                    inbox: inbox,
                    settings: settings,
                    categoryStore: categoryStore,
                    accountConnector: accountConnector
                )
            }
            .sheet(isPresented: $showAddAccount) {
                iOSAddAccountSheet(accountStore: accountStore)
            }
            .sheet(isPresented: $showSoftPaywall) {
                iOSPaywallSheet(license: license)
            }
            .task {
                applyDefaultInboxScope()
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No mailboxes yet", systemImage: "tray")
        } description: {
            Text("Add your first mailbox to start triaging. File13 fetches headers only — never message bodies.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        } actions: {
            Button("Add Mailbox") {
                showAddAccount = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var accountList: some View {
        List {
            ForEach(accountStore.accounts) { account in
                NavigationLink(value: account) {
                    accountRow(account)
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

    /// One-shot at launch: push the user's default account onto the nav
    /// stack if Settings → General → Default Mailbox names a specific
    /// account that still exists. Falls back to the account list (the
    /// `.unified` case) otherwise. We guard with `hasAppliedDefaultScope`
    /// so a manual back-out doesn't bounce the user right back in.
    private func applyDefaultInboxScope() {
        guard !hasAppliedDefaultScope else { return }
        hasAppliedDefaultScope = true
        if case .account(let id) = settings.defaultInboxScope,
           let account = accountStore.accounts.first(where: { $0.id == id }) {
            path.append(account)
        }
    }
}
