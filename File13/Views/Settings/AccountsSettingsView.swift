import File13Core
import SwiftUI

struct AccountsSettingsView: View {
    @Bindable var accountStore: AccountStore
    @Bindable var inbox: InboxStore
    @Bindable var license: LicenseStore

    @State private var showAddSheet = false
    @State private var pendingRemoval: Account?
    @State private var editingAccount: Account?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pending-sync banner: shown if iCloud delivered a change to
            // the account list that hasn't been approved on this Mac.
            // Defends against `host` hijack via iCloud-account compromise
            // — see `PendingAccountChangesBanner` for the threat model.
            PendingAccountChangesBanner(accountStore: accountStore)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            if accountStore.accounts.isEmpty {
                // `maxWidth: .infinity` is the load-bearing bit — the
                // wrapping VStack uses `.leading` alignment for the
                // banner above, which would otherwise pin
                // ContentUnavailableView to the left edge. Letting it
                // claim full width lets its own internal centering
                // place the icon + text in the middle of the pane.
                ContentUnavailableView(
                    "No accounts connected",
                    systemImage: "tray",
                    description: Text("Connect an IMAP account to start cleaning your inbox.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(accountStore.accounts) { account in
                        AccountRow(
                            account: account,
                            inbox: inbox,
                            onEdit: { editingAccount = account },
                            onRemove: { pendingRemoval = account }
                        )
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Account…", systemImage: "plus")
                }
            }
            .padding(12)
        }
        .sheet(isPresented: $showAddSheet) {
            AddAccountSheet(accountStore: accountStore, inbox: inbox, license: license)
        }
        .sheet(item: $editingAccount) { account in
            EditAccountSheet(accountStore: accountStore, inbox: inbox, account: account)
        }
        .confirmationDialog(
            "Remove this account?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { account in
            Button("Remove", role: .destructive) {
                Task { await remove(account) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { account in
            Text("File13 will forget the credentials for \(account.address) and clear its cached headers. The account itself isn't touched on the mail server.")
        }
    }

    private func remove(_ account: Account) async {
        await inbox.disconnect(accountId: account.id)
        accountStore.remove(account.id)
        inbox.forgetCachedMessages(accountId: account.id)
    }
}

private struct AccountRow: View {
    let account: Account
    @Bindable var inbox: InboxStore
    let onEdit: () -> Void
    let onRemove: () -> Void

    private var isConnected: Bool {
        inbox.sessions.first { $0.id == account.id }?.connectionState == .connected
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: providerIcon)
                .font(.title3)
                .frame(width: 28, height: 28)
                .foregroundStyle(.tint)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.displayName).font(.headline)
                    if isConnected {
                        Text("Connected")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.2), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(account.address)
                    .font(.callout).foregroundStyle(.secondary)
                Text("\(account.host):\(account.port)")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                Task { await inbox.resyncFromScratch(accountId: account.id) }
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }
            .buttonStyle(.borderless)
            .help("Re-sync from scratch — clears cached headers and re-fetches everything. Useful after File13 updates that add new metadata fields.")
            .disabled(!isConnected)

            Button(action: onEdit) {
                Image(systemName: "pencil.circle")
            }
            .buttonStyle(.borderless)
            .help("Edit account details")

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove account")
        }
        .padding(.vertical, 4)
    }

    private var providerIcon: String {
        switch account.provider {
        case .gmail:   "envelope"
        case .outlook: "envelope.badge"
        case .icloud:  "icloud"
        case .yahoo:   "envelope.open"
        case .aol:     "envelope.open.fill"
        case .imap:    "envelope.circle"
        }
    }
}
