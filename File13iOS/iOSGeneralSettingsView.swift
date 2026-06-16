import File13Core
import SwiftUI

struct iOSGeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var accountStore: AccountStore
    @Bindable var license: LicenseStore

    @State private var showPaywall = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ForEach(SettingsStore.AppIconChoice.allCases) { choice in
                        iOSAppIconTile(
                            choice: choice,
                            isSelected: settings.appIcon == choice,
                            isPro: license.tier == .pro,
                            onTap: {
                                if choice.requiresPro && license.tier != .pro {
                                    showPaywall = true
                                } else {
                                    settings.appIcon = choice
                                }
                            }
                        )
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } header: {
                Text("App icon")
            } footer: {
                if license.tier != .pro {
                    Text("Alternate icons are part of File13 Pro.")
                }
            }

            Section {
                Picker("Refresh Inbox", selection: $settings.refreshSchedule) {
                    ForEach(SettingsStore.RefreshSchedule.allCases) { schedule in
                        Text(schedule.label).tag(schedule)
                    }
                }
            } header: {
                Text("Refresh")
            } footer: {
                Text("How often File13 re-fetches headers from your connected accounts. Pull-to-refresh works at any time regardless of this setting.")
            }

            Section {
                Picker("Default Mailbox", selection: $settings.defaultInboxScope) {
                    Text("Mailbox list").tag(SettingsStore.DefaultInboxScope.unified)
                    if !accountStore.accounts.isEmpty {
                        Divider()
                        ForEach(accountStore.accounts) { account in
                            Text(account.displayName)
                                .tag(SettingsStore.DefaultInboxScope.account(account.id))
                        }
                    }
                }
            } header: {
                Text("Behavior")
            } footer: {
                Text("Where File13 lands you when the app launches. Pick a specific mailbox to skip the list and open straight to its messages, or leave on \"Mailbox list\" to choose each time.")
            }

            Section {
                Toggle("Sync settings with iCloud", isOn: $settings.iCloudSyncEnabled)
                Toggle("Sync passwords with iCloud Keychain", isOn: $settings.iCloudKeychainSyncEnabled)
            } header: {
                Text("iCloud")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("**Sync settings with iCloud** mirrors accounts (without passwords), rules, AI preferences, sender categories, your VIP list, dismissed suggestions, and reply history across your devices. Email headers, message contents, and the local cache are never uploaded — only your configuration.")
                    Text("**Sync passwords with iCloud Keychain** stores IMAP account passwords and AI provider API keys in Apple's iCloud Keychain so they appear automatically on your other devices. Requires iCloud Keychain to be enabled in Settings → Apple Account → iCloud. Turning this off removes the synced copies from your other devices.")
                }
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            iOSPaywallSheet(license: license)
        }
    }
}

private struct iOSAppIconTile: View {
    let choice: SettingsStore.AppIconChoice
    let isSelected: Bool
    let isPro: Bool
    let onTap: () -> Void

    private var locked: Bool { choice.requiresPro && !isPro }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    iconImage
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(
                                    isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: isSelected ? 2.5 : 1
                                )
                        )
                        .opacity(locked ? 0.55 : 1)
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.7)))
                            .offset(x: 6, y: -6)
                    }
                }
                Text(choice.label)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var iconImage: Image {
        if let ui = UIImage(named: choice.previewAssetName) {
            return Image(uiImage: ui)
        }
        return Image(systemName: "app.dashed")
    }
}
