import File13Core
import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var accountStore: AccountStore
    @Bindable var inbox: InboxStore
    @Bindable var ruleStore: RuleStore
    @Bindable var categoryStore: SenderCategoryStore
    @Bindable var suggestionDismissals: SuggestionDismissalStore
    @Bindable var vipStore: VIPStore
    @Bindable var repliedStore: RepliedMessagesStore
    @Bindable var license: LicenseStore

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings, accountStore: accountStore, license: license)
                .tabItem { Label("General", systemImage: "gear") }

            ActionsSafetySettingsView(
                settings: settings,
                vipStore: vipStore,
                repliedStore: repliedStore,
                categoryStore: categoryStore
            )
            .tabItem { Label("Actions & Safety", systemImage: "shield.lefthalf.filled") }

            RulesSettingsView(
                ruleStore: ruleStore,
                inbox: inbox,
                settings: settings,
                categoryStore: categoryStore,
                suggestionDismissals: suggestionDismissals,
                vipStore: vipStore
            )
            .tabItem { Label("Rules", systemImage: "wand.and.stars") }

            AIIntegrationSettingsView(settings: settings)
                .tabItem { Label("AI", systemImage: "sparkles") }

            AccountsSettingsView(accountStore: accountStore, inbox: inbox, license: license)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }

            LicenseSettingsView(license: license)
                .tabItem { Label("License", systemImage: "rosette") }
        }
        .frame(width: 600, height: 540)
        .background(SettingsWindowCenterer())
    }
}

/// Re-centers the settings window on every open so it doesn't reuse a
/// previously-saved off-screen position.
private struct SettingsWindowCenterer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // `setFrameAutosaveName("")` disables persistence; combined with
            // `.center()` this gives a freshly-centered window on each open.
            window.setFrameAutosaveName("")
            window.center()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
