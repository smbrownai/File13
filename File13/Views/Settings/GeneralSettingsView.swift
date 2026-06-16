import File13Core
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var accountStore: AccountStore
    @Bindable var license: LicenseStore

    @State private var installedMailClients: [OpenableApp] = []
    @State private var systemDefaultMailClient: OpenableApp?
    @State private var installedBrowsers: [OpenableApp] = []
    @State private var systemDefaultBrowser: OpenableApp?
    @State private var showPaywall = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(SettingsStore.AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                AccentPalettePicker(selection: $settings.accentPalette)

                AppIconPicker(
                    selection: $settings.appIcon,
                    isPro: license.tier == .pro,
                    onLockedTap: { showPaywall = true }
                )
            } header: {
                Text("Appearance").font(.headline)
            }

            Section {
                AppHandlerPicker(
                    label: "Open mailto links in",
                    selection: Binding(
                        get: { settings.preferredMailClientBundleId ?? Self.systemDefaultSentinel },
                        set: { newValue in
                            settings.preferredMailClientBundleId =
                                (newValue == Self.systemDefaultSentinel) ? nil : newValue
                        }
                    ),
                    apps: installedMailClients,
                    systemDefault: systemDefaultMailClient
                )
            } header: {
                Text("Mail Client").font(.headline)
            } footer: {
                Text("Used to open `mailto:` unsubscribe links. File13 never sends mail itself. Your chosen client composes and sends the unsubscribe message.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                AppHandlerPicker(
                    label: "Open web links in",
                    selection: Binding(
                        get: { settings.preferredBrowserBundleId ?? Self.systemDefaultSentinel },
                        set: { newValue in
                            settings.preferredBrowserBundleId =
                                (newValue == Self.systemDefaultSentinel) ? nil : newValue
                        }
                    ),
                    apps: installedBrowsers,
                    systemDefault: systemDefaultBrowser
                )
            } header: {
                Text("Browser").font(.headline)
            } footer: {
                Text("Used to open web confirmation pages from unsubscribe links. One-click HTTPS unsubscribes are POSTed automatically and don't open the browser.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Refresh Inbox", selection: $settings.refreshSchedule) {
                    ForEach(SettingsStore.RefreshSchedule.allCases) { schedule in
                        Text(schedule.label).tag(schedule)
                    }
                }
            } header: {
                Text("Refresh").font(.headline)
            } footer: {
                Text("How often File13 re-fetches headers from your connected accounts. The Refresh button in the toolbar works at any time, regardless of this setting.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Default Inbox Scope") {
                    Picker("", selection: $settings.defaultInboxScope) {
                        Text("All Accounts (Unified)")
                            .tag(SettingsStore.DefaultInboxScope.unified)
                        if !accountStore.accounts.isEmpty {
                            Divider()
                            ForEach(accountStore.accounts) { account in
                                Text(account.displayName)
                                    .tag(SettingsStore.DefaultInboxScope.account(account.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                LabeledContent("Launch at Login") {
                    Toggle("", isOn: $settings.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            } header: {
                Text("Behavior").font(.headline)
            } footer: {
                Text("Default Inbox Scope is applied on app launch. Launch at Login registers the app with macOS via Login Items. You may be prompted to confirm in System Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Sync settings with iCloud") {
                    Toggle("", isOn: $settings.iCloudSyncEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                LabeledContent("Sync passwords with iCloud Keychain") {
                    Toggle("", isOn: $settings.iCloudKeychainSyncEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            } header: {
                Text("iCloud").font(.headline)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("**Sync settings with iCloud** mirrors accounts (without passwords), rules, AI preferences, sender categories, your VIP list, dismissed suggestions, and reply history across your devices. Email headers, message contents, and the local cache are never uploaded — only your configuration.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("**Sync passwords with iCloud Keychain** stores IMAP account passwords and AI provider API keys in Apple's iCloud Keychain so they appear automatically on your other devices. Requires iCloud Keychain to be enabled in System Settings → Apple ID → iCloud. Turning this off removes the synced copies from your other devices.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
        .task {
            installedMailClients = MailClientDirectory.installedClients()
            systemDefaultMailClient = MailClientDirectory.systemDefault()
            installedBrowsers = BrowserDirectory.installedBrowsers()
            systemDefaultBrowser = BrowserDirectory.systemDefault()
        }
        .sheet(isPresented: $showPaywall) {
            PaywallSheet(license: license)
        }
    }

    fileprivate static let systemDefaultSentinel = "__file13_system_default__"
}

private struct AppHandlerPicker: View {
    let label: String
    @Binding var selection: String
    let apps: [OpenableApp]
    let systemDefault: OpenableApp?

    var body: some View {
        LabeledContent(label) {
            Picker("", selection: $selection) {
                Text(systemDefaultLabel)
                    .tag(GeneralSettingsView.systemDefaultSentinel)
                if !apps.isEmpty {
                    Divider()
                    ForEach(apps) { app in
                        Text(app.displayName).tag(app.bundleIdentifier)
                    }
                }
                // Add a ghost row for the persisted selection when it
                // doesn't match anything in `apps` — either the directory
                // hasn't finished enumerating yet (first render, `.task`
                // hasn't fired), or the app the user picked previously
                // was uninstalled. Without this, SwiftUI logs:
                //   "Picker: the selection '<bundleId>' is invalid and
                //    does not have an associated tag, this will give
                //    undefined results."
                // and the picker reverts to the system-default text.
                if isOrphanedSelection {
                    Divider()
                    Text(orphanedSelectionLabel).tag(selection)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var systemDefaultLabel: String {
        if let name = systemDefault?.displayName {
            return "System default (\(name))"
        }
        return "System default"
    }

    /// True when `selection` is a non-sentinel value that isn't represented
    /// by any installed-app row.
    private var isOrphanedSelection: Bool {
        guard selection != GeneralSettingsView.systemDefaultSentinel else { return false }
        return !apps.contains(where: { $0.bundleIdentifier == selection })
    }

    private var orphanedSelectionLabel: String {
        // Show the bundle ID with a "not installed" suffix so the user can
        // tell what they previously picked, even if the app is gone now.
        // Once they switch to another option the orphan row disappears.
        "Not installed (\(selection))"
    }
}

private struct AppIconPicker: View {
    @Binding var selection: SettingsStore.AppIconChoice
    let isPro: Bool
    let onLockedTap: () -> Void

    var body: some View {
        LabeledContent("App Icon") {
            HStack(spacing: 12) {
                ForEach(SettingsStore.AppIconChoice.allCases) { choice in
                    let locked = choice.requiresPro && !isPro
                    Button {
                        if locked {
                            onLockedTap()
                        } else {
                            selection = choice
                        }
                    } label: {
                        VStack(spacing: 4) {
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: thumbnail(for: choice))
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(
                                                choice == selection ? Color.primary : Color.secondary.opacity(0.3),
                                                lineWidth: choice == selection ? 2 : 1
                                            )
                                    )
                                    .opacity(locked ? 0.55 : 1)
                                if locked {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(Circle().fill(Color.black.opacity(0.7)))
                                        .offset(x: 4, y: -4)
                                }
                            }
                            Text(choice.label)
                                .font(.caption)
                                .foregroundStyle(choice == selection ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(locked ? "\(choice.label) — requires File13 Pro" : choice.label)
                }
            }
        }
    }

    private func thumbnail(for choice: SettingsStore.AppIconChoice) -> NSImage {
        NSImage(named: choice.previewAssetName) ?? NSImage(size: NSSize(width: 48, height: 48))
    }
}

private struct AccentPalettePicker: View {
    @Binding var selection: SettingsStore.AccentPalette

    var body: some View {
        LabeledContent("Accent Color") {
            HStack(spacing: 12) {
                ForEach(SettingsStore.AccentPalette.allCases) { palette in
                    Button {
                        selection = palette
                    } label: {
                        VStack(spacing: 4) {
                            HStack(spacing: 3) {
                                ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, color in
                                    Circle()
                                        .fill(color)
                                        .frame(width: 14, height: 14)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(palette == selection ? Color.primary : Color.secondary.opacity(0.3),
                                            lineWidth: palette == selection ? 2 : 1)
                            )
                            Text(palette.label)
                                .font(.caption)
                                .foregroundStyle(palette == selection ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(palette.label)
                }
            }
        }
    }
}
