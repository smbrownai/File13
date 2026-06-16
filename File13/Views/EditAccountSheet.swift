import File13Core
import SwiftUI

struct EditAccountSheet: View {
    @Bindable var accountStore: AccountStore
    @Bindable var inbox: InboxStore
    let account: Account
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String
    @State private var emailAddress: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String

    @State private var isWorking = false
    @State private var errorText: String?

    init(accountStore: AccountStore, inbox: InboxStore, account: Account) {
        self.accountStore = accountStore
        self.inbox = inbox
        self.account = account
        _displayName = State(initialValue: account.displayName)
        _emailAddress = State(initialValue: account.address)
        _host = State(initialValue: account.host)
        _port = State(initialValue: String(account.port))
        _username = State(initialValue: account.username)
        // Load the existing password so the field is pre-populated. Mark unchanged until the
        // user types so we can preserve it as-is on submit.
        let existing = (try? KeychainStore.loadPassword(for: account.id)) ?? ""
        _password = State(initialValue: existing)
    }

    private var portInt: Int? {
        let p = Int(port)
        return p.flatMap { (1..<65536).contains($0) ? $0 : nil }
    }

    private var canSubmit: Bool {
        !host.isEmpty && !username.isEmpty && !password.isEmpty &&
        !emailAddress.isEmpty && portInt != nil && !isWorking
    }

    private var isICloudHost: Bool {
        host.lowercased().hasSuffix("mail.me.com")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit account").font(.title3).bold()
                    Text("Update connection details for \(account.address). Saving will reconnect this account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Form {
                Section {
                    TextField("Display name", text: $displayName, prompt: Text("Personal Mail"))
                    TextField("Email address", text: $emailAddress, prompt: Text("you@example.com"))
                        .textContentType(.emailAddress)
                }

                Section("Server") {
                    TextField("IMAP host", text: $host, prompt: Text("imap.example.com"))
                    LabeledContent("Port") {
                        TextField("", text: $port)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                            .labelsHidden()
                    }
                }

                Section("Credentials") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    if let callout = ProviderPasswordCallout.forHost(host) {
                        callout
                    }
                }
            }
            .formStyle(.grouped)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(3, reservesSpace: false)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await submit() }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small).padding(.horizontal, 8)
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func submit() async {
        guard let port = portInt else { return }
        isWorking = true
        defer { isWorking = false }
        errorText = nil

        let provider: Account.Provider = guessProvider(host: host)
        let updated = Account(
            id: account.id,
            displayName: displayName.isEmpty ? emailAddress : displayName,
            address: emailAddress,
            host: host,
            port: port,
            username: username,
            provider: provider
        )

        do {
            try accountStore.add(updated, password: password)
        } catch {
            errorText = "Couldn't save credentials: \(error.localizedDescription)"
            return
        }

        // Reconnect with the new details so the change takes effect immediately.
        await inbox.disconnect(accountId: updated.id)
        let credentials = AccountCredentials.resolved(host: host, port: port, username: username, password: password)
        let session = await inbox.connect(account: updated, credentials: credentials)

        // Surface BOTH `.failed` and `.offlineWithCache` as an error here.
        // The user just typed new credentials and clicked Save; if the new
        // credentials don't actually authenticate, they deserve to know
        // immediately rather than dismissing into a stale-cache view that
        // implies success. (Without this branch, an account that has
        // cached headers from before would land in `.offlineWithCache`
        // after an edit-with-bad-password and the sheet would dismiss
        // cleanly.)
        switch session.connectionState {
        case .failed(let msg), .offlineWithCache(let msg):
            errorText = rewriteError(msg)
            return
        default:
            break
        }
        dismiss()
    }

    /// Mirror of `AddAccountSheet.rewriteError` — iCloud's raw
    /// `AUTHENTICATIONFAILED` is opaque; rewrite it to point at the
    /// app-specific-password page so users editing an iCloud account get
    /// the same hint they'd get when first adding one.
    private func rewriteError(_ raw: String) -> String {
        guard isICloudHost else { return raw }
        let lower = raw.lowercased()
        let looksLikeAuth = lower.contains("auth")
            || lower.contains("login")
            || lower.contains("invalid")
            || lower.contains("rejected")
            || lower.contains("incorrect")
        guard looksLikeAuth else { return raw }
        return """
        iCloud rejected this password. Apple requires an app-specific password — your regular Apple ID password won't work. Generate one at appleid.apple.com (Sign-In and Security → App-Specific Passwords) and paste it above. 2FA must be on for your Apple ID.
        """
    }

    private func guessProvider(host: String) -> Account.Provider {
        let lower = host.lowercased()
        if lower.contains("gmail") || lower.contains("google") { return .gmail }
        if lower.contains("outlook") || lower.contains("office365") { return .outlook }
        if lower.contains("me.com") || lower.contains("icloud") { return .icloud }
        if lower.contains("yahoo") { return .yahoo }
        if lower.contains("aol") { return .aol }
        return .imap
    }
}
