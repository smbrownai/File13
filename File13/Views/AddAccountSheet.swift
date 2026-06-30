import File13Core
import SwiftUI

struct AddAccountSheet: View {
    @Bindable var accountStore: AccountStore
    @Bindable var inbox: InboxStore
    @Bindable var license: LicenseStore
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false

    @State private var displayName: String = ""
    @State private var emailAddress: String = ""
    @State private var host: String = ""
    @State private var port: String = "993"
    @State private var username: String = ""
    @State private var password: String = ""

    @State private var isWorking = false
    @State private var errorText: String?
    @State private var preset: AccountPreset = .custom

    // Track the last value we autofilled into each derived field. As long as
    // the field still holds that derived value (or is empty), each new email
    // keystroke can refresh it; once the user types something different we
    // stop touching it. Without this, the original `isEmpty` guard fired
    // exactly once — on the first email character — and never updated again.
    @State private var lastDerivedDisplayName: String = ""
    @State private var lastDerivedHost: String = ""
    @State private var lastDerivedUsername: String = ""

    private var portInt: Int? {
        let p = Int(port)
        return p.flatMap { (1..<65536).contains($0) ? $0 : nil }
    }

    private var canSubmit: Bool {
        !host.isEmpty && !username.isEmpty && !password.isEmpty &&
        !emailAddress.isEmpty && portInt != nil && !isWorking
    }

    /// True when the host points at Apple's iCloud Mail server. iCloud rejects
    /// regular Apple-ID passwords; users must paste an app-specific password
    /// generated at appleid.apple.com (which itself requires 2FA on the
    /// Apple ID). The `ICloudAppPasswordCallout` below surfaces that
    /// requirement inline so users don't waste a round-trip on the wrong
    /// password.
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
                    Text("Connect IMAP account").font(.title3).bold()
                    Text("File13 fetches headers only by default. Your password is stored in your Mac's Keychain — it never leaves your device except to sign in to your mail server.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PresetPicker(selection: $preset, onPick: applyPreset)

            Form {
                Section {
                    TextField("Display name", text: $displayName, prompt: Text("Personal Mail"))
                    TextField("Email address", text: $emailAddress, prompt: Text("you@example.com"))
                        .textContentType(.emailAddress)
                        .onChange(of: emailAddress) { _, new in
                            applyEmailDerived(new)
                        }
                }

                Section("Server") {
                    TextField("IMAP host", text: $host, prompt: Text("imap.example.com"))
                        .onChange(of: host) { _, new in
                            // Keep the preset tile in sync with whatever's in
                            // the host field, whether the user typed it
                            // directly or it came in via email-driven autofill.
                            preset = AccountPreset.detect(host: new)
                        }
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
                        Text("Connect")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 480)
        // Soft paywall, shown if the user hits Connect with a 2nd account
        // on the free tier. Dismissible so they can back out without
        // upgrading; the sheet self-closes on successful purchase.
        .sheet(isPresented: $showPaywall) {
            PaywallSheet(license: license)
        }
    }

    /// Apply a preset to the host / port fields. Doesn't touch
    /// email/username/password — the user might already have typed those, and
    /// switching presets shouldn't wipe their work. Custom preset clears the
    /// host so the email-driven autofill takes over again.
    private func applyPreset(_ preset: AccountPreset) {
        if let h = preset.host {
            host = h
            lastDerivedHost = h
            port = String(preset.port)
        } else if host == lastDerivedHost {
            // "Other" selected. If the host still holds a value we autofilled
            // from a previous preset (or email derivation), clear it so any
            // provider-specific callout — e.g. Yahoo's app-password notice —
            // disappears. If the user typed their own host, leave it.
            host = ""
            lastDerivedHost = ""
        }
    }

    /// Update derived fields (username, display name, host) as the user types
    /// the email address. Each field is only refreshed if it still matches
    /// what we previously autofilled — once the user manually edits a field,
    /// `field != lastDerived<Field>` and we stop touching it.
    ///
    /// Username mirrors the full email string. Display name and host need
    /// the `@<domain>` part to derive anything, so they no-op until the user
    /// types the `@`.
    private func applyEmailDerived(_ email: String) {
        // Username = full email string.
        if username == lastDerivedUsername {
            username = email
            lastDerivedUsername = email
        }

        // Display name + host require a domain — bail until we see `@`.
        guard let atIndex = email.firstIndex(of: "@") else { return }
        let domain = String(email[email.index(after: atIndex)...]).lowercased()
        guard !domain.isEmpty else { return }

        if displayName == lastDerivedDisplayName {
            displayName = domain
            lastDerivedDisplayName = domain
        }

        if host == lastDerivedHost, let derivedHost = AccountEmailDerivation.derive(from: email).host {
            host = derivedHost
            lastDerivedHost = derivedHost
        }
    }

    private func submit() async {
        guard let port = portInt else { return }
        // Pro-gate: the free tier allows exactly one connected mailbox.
        // Trigger the soft paywall here instead of inside `AccountStore`
        // so the sheet stays the data-only store it's always been.
        guard license.canAddAccount(currentCount: accountStore.accounts.count) else {
            showPaywall = true
            return
        }
        isWorking = true
        defer { isWorking = false }
        errorText = nil

        let provider: Account.Provider = guessProvider(host: host)
        let account = Account(
            id: UUID(),
            displayName: displayName.isEmpty ? emailAddress : displayName,
            address: emailAddress,
            host: host,
            port: port,
            username: username,
            provider: provider
        )

        do {
            try accountStore.add(account, password: password)
        } catch {
            errorText = "Couldn't save credentials: \(error.localizedDescription)"
            return
        }

        let credentials = AccountCredentials.resolved(host: host, port: port, username: username, password: password)
        let session = await inbox.connect(account: account, credentials: credentials)

        if case .failed(let msg) = session.connectionState {
            errorText = rewriteError(msg)
            await inbox.disconnect(accountId: account.id)
            accountStore.remove(account.id)
            return
        }
        dismiss()
    }

    /// When iCloud rejects login, SwiftMail surfaces a raw IMAP
    /// `AUTHENTICATIONFAILED` / `LOGIN failed` string. Most users will read
    /// that, assume they mistyped their Apple ID password, and bounce —
    /// they don't know that iCloud requires an app-specific password. Map
    /// the auth failure to a clear hint pointing at the page that issues
    /// one. Non-auth errors (host unreachable, TLS, etc.) pass through.
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

// MARK: - Provider presets

private struct PresetPicker: View {
    @Binding var selection: AccountPreset
    let onPick: (AccountPreset) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AccountPreset.allCases) { preset in
                Button {
                    selection = preset
                    onPick(preset)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: preset.icon)
                            .font(.title2)
                            .foregroundStyle(selection == preset ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(preset.label)
                            .font(.caption)
                            .foregroundStyle(selection == preset ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selection == preset ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(Color.clear))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selection == preset ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.25)),
                                    lineWidth: selection == preset ? 1.5 : 1)
                    )
                    // Without this, SwiftUI hit-tests only the rendered
                    // glyph/text pixels — clicks on the padded whitespace
                    // inside the tile slip through. `.contentShape` makes
                    // the entire rounded rect clickable.
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(preset.label)
            }
        }
    }
}

// MARK: - Provider password callouts

/// Inline notice rendered from a `ProviderPasswordCalloutInfo`. The data
/// (title, message, link) lives in File13Core so iOS can reuse it. Same
/// affordance Spark / Mimestream / Newton show, because the IMAP
/// `AUTHENTICATIONFAILED` string returned by these servers is opaque and
/// most users don't know about the requirement.
struct ProviderPasswordCallout: View {
    let info: ProviderPasswordCalloutInfo

    static func forHost(_ host: String) -> ProviderPasswordCallout? {
        ProviderPasswordCalloutInfo.forHost(host).map { ProviderPasswordCallout(info: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.title)
                        .font(.callout).fontWeight(.semibold)
                    Text(info.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: info.url) {
                        HStack(spacing: 4) {
                            Text(info.linkLabel)
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.tint.opacity(0.25), lineWidth: 1)
        )
    }
}
