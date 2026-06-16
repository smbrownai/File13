import File13Core
import SwiftUI

/// Per-mailbox settings page. Reached from `iOSSettingsTab` by tapping a
/// row in the Mailboxes section. Lets the user rename, change IMAP host /
/// port / username, change the password, or remove the account. Mirrors
/// the macOS Account inspector, condensed for iOS.
///
/// Field edits are buffered locally and committed on Save (or on
/// `onDisappear` if Save was tapped). Password is treated separately —
/// it's written through `KeychainStore` directly, never persisted in
/// view state across navigation pops.
struct iOSAccountDetailView: View {
    @Bindable var accountStore: AccountStore
    @Bindable var inbox: InboxStore
    let accountId: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var address: String = ""
    @State private var host: String = ""
    @State private var port: String = "993"
    @State private var username: String = ""

    @State private var newPassword: String = ""
    @State private var passwordTouched = false

    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var showRemoveConfirm = false

    private var account: Account? {
        accountStore.accounts.first { $0.id == accountId }
    }

    private var portInt: Int? {
        let p = Int(port)
        return p.flatMap { (1..<65536).contains($0) ? $0 : nil }
    }

    private var hasUnsavedFieldChanges: Bool {
        guard let account else { return false }
        return displayName != account.displayName
            || address != account.address
            || host != account.host
            || (portInt ?? -1) != account.port
            || username != account.username
    }

    private var canSave: Bool {
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty,
              !host.trimmingCharacters(in: .whitespaces).isEmpty,
              !username.trimmingCharacters(in: .whitespaces).isEmpty,
              portInt != nil
        else { return false }
        return hasUnsavedFieldChanges || (passwordTouched && !newPassword.isEmpty)
    }

    var body: some View {
        Group {
            if let account {
                Form {
                    Section("Identity") {
                        TextField("Display name", text: $displayName)
                            .autocorrectionDisabled()
                        TextField("Email address", text: $address)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section("IMAP server") {
                        TextField("Host", text: $host)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", text: $port)
                            .keyboardType(.numberPad)
                    }

                    Section {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Change password", text: $newPassword)
                            .textContentType(.password)
                            .onChange(of: newPassword) { _, _ in passwordTouched = true }
                    } header: {
                        Text("Credentials")
                    } footer: {
                        Text(passwordTouched
                             ? "Saving will replace the stored password and reconnect this mailbox."
                             : "Leave blank to keep the current password.")
                    }

                    if let info = ProviderPasswordCalloutInfo.forHost(host) {
                        Section {
                            iOSProviderPasswordCallout(info: info)
                                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        }
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            showRemoveConfirm = true
                        } label: {
                            Label("Remove Mailbox", systemImage: "trash")
                        }
                    } footer: {
                        Text("Disconnects the account and clears its cached headers from this device. Your messages on the server are untouched.")
                    }
                }
                .navigationTitle(account.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                            .disabled(!canSave)
                    }
                }
                .confirmationDialog(
                    "Remove \(account.displayName)?",
                    isPresented: $showRemoveConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Remove Mailbox", role: .destructive) { remove() }
                    Button("Cancel", role: .cancel) {}
                }
                .task {
                    if !hasLoaded {
                        load(from: account)
                        hasLoaded = true
                    }
                }
            } else {
                // Account was removed (e.g. via the confirmation dialog).
                // Render an empty placeholder; the navigation stack pops
                // back to Settings on its own once `accountId` no longer
                // resolves.
                ContentUnavailableView("Mailbox removed", systemImage: "tray")
            }
        }
    }

    private func load(from account: Account) {
        displayName = account.displayName
        address = account.address
        host = account.host
        port = String(account.port)
        username = account.username
    }

    private func save() {
        guard let existing = account, let portInt else { return }
        errorMessage = nil

        let updated = Account(
            id: existing.id,
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            address: address.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: portInt,
            username: username.trimmingCharacters(in: .whitespaces),
            provider: AccountPreset.detect(host: host).accountProvider,
            authKind: existing.authKind
        )

        let didChangeFields = hasUnsavedFieldChanges
        accountStore.update(updated)

        if passwordTouched, !newPassword.isEmpty {
            do {
                try KeychainStore.savePassword(newPassword, for: updated.id)
            } catch {
                errorMessage = "Couldn't save password: \(error.localizedDescription)"
                return
            }
            newPassword = ""
            passwordTouched = false
        }

        // Force a reconnect on credential / host / port / username change.
        // `inbox.disconnect` clears the session; the next mailbox visit
        // (or the user's next refresh) brings it back up with the new
        // credentials.
        if didChangeFields || (!passwordTouched && newPassword.isEmpty == false) {
            Task { await inbox.disconnect(accountId: updated.id) }
        }

        dismiss()
    }

    private func remove() {
        Task { await inbox.disconnect(accountId: accountId) }
        accountStore.remove(accountId)
        dismiss()
    }
}
