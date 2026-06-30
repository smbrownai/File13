import File13Core
import SwiftUI

/// Add-mailbox flow for iOS. Mirrors the macOS `AddAccountSheet` shape:
/// provider preset row at the top, email-driven autofill, inline
/// app-password callouts for hosts that need them. Auth is IMAP +
/// password / app-specific password — OAuth is scaffold-only on both
/// platforms (see CLAUDE.md).
struct iOSAddAccountSheet: View {
    @Bindable var accountStore: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var preset: AccountPreset = .custom
    @State private var displayName = ""
    @State private var address = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    @State private var lastDerivedDisplayName: String = ""
    @State private var lastDerivedHost: String = ""
    @State private var lastDerivedUsername: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    iOSPresetPicker(selection: $preset, onPick: applyPreset)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                Section("Identity") {
                    TextField("Display name", text: $displayName, prompt: Text("Personal Mail"))
                        .textContentType(.organizationName)
                        .autocorrectionDisabled()
                    TextField("Email address", text: $address, prompt: Text("you@example.com"))
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: address) { _, new in applyEmailDerived(new) }
                }
                Section("IMAP server") {
                    TextField("Host", text: $host, prompt: Text("imap.example.com"))
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: host) { _, new in
                            preset = AccountPreset.detect(host: new)
                        }
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }
                Section("Credentials") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
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
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Mailbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        if isSaving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(!isValid || isSaving)
                }
            }
        }
    }

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
            && address.contains("@")
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port) != nil
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    private func applyPreset(_ preset: AccountPreset) {
        if let h = preset.host {
            host = h
            lastDerivedHost = h
            port = String(preset.port)
        } else if host == lastDerivedHost {
            // "Other" selected — clear an autofilled host (and with it the
            // provider callout). Preserve a host the user typed themselves.
            host = ""
            lastDerivedHost = ""
        }
    }

    /// Update derived fields (username, display name, host) as the user
    /// types the email address. Each field is only refreshed if it still
    /// matches what we previously autofilled — once the user manually edits
    /// a field, we stop touching it.
    private func applyEmailDerived(_ email: String) {
        let derived = AccountEmailDerivation.derive(from: email)

        if username == lastDerivedUsername {
            username = derived.username
            lastDerivedUsername = derived.username
        }
        if let name = derived.displayName, displayName == lastDerivedDisplayName {
            displayName = name
            lastDerivedDisplayName = name
        }
        if let h = derived.host, host == lastDerivedHost {
            host = h
            lastDerivedHost = h
        }
    }

    private func submit() {
        guard let portInt = Int(port), portInt > 0, portInt < 65536 else {
            errorMessage = "Port must be a number between 1 and 65535."
            return
        }
        isSaving = true
        defer { isSaving = false }
        let account = Account(
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            address: address.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: portInt,
            username: username.trimmingCharacters(in: .whitespaces),
            provider: AccountPreset.detect(host: host).accountProvider
        )
        do {
            try accountStore.add(account, password: password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Preset row — grid of provider tiles. Single-column on the narrow
/// iPhone form rows would feel cramped; six tiles fit comfortably in a
/// scroll-snapping `LazyHGrid`. Tap a tile to fill host + port; the
/// detection logic on the host field flips the highlight back if the
/// user edits the host directly.
struct iOSPresetPicker: View {
    @Binding var selection: AccountPreset
    let onPick: (AccountPreset) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
                        .frame(width: 72)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selection == preset ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(Color.clear))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selection == preset ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.25)),
                                        lineWidth: selection == preset ? 1.5 : 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// iOS render of `ProviderPasswordCalloutInfo`. macOS has its own
/// (`ProviderPasswordCallout`); both consume the same shared data type
/// from File13Core.
struct iOSProviderPasswordCallout: View {
    let info: ProviderPasswordCalloutInfo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key.fill")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.callout).fontWeight(.semibold)
                Text(info.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(destination: info.url) {
                    HStack(spacing: 4) {
                        Text(info.linkLabel)
                            .font(.caption)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
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
