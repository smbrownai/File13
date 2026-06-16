import File13Core
import SwiftUI

/// Top-level chrome for the iPhone / iPad app. Adapts to the current
/// `horizontalSizeClass`:
///
/// - **Compact** (iPhone, or iPad in Split View / Slide Over): a `TabView`
///   with Mailboxes + Settings as bottom tabs.
/// - **Regular** (iPad in full-width): a two-column `NavigationSplitView`
///   with accounts + a Settings row in the sidebar and the selected item
///   in the detail column.
///
/// Switching is reactive — dragging the app into Split View with another
/// iPad app flips the size class, and SwiftUI re-renders into the iPhone
/// chrome until full width is restored.
struct iOSRootView: View {
    @Bindable var accountStore: AccountStore
    @Bindable var settings: SettingsStore
    @Bindable var ruleStore: RuleStore
    @Bindable var categoryStore: SenderCategoryStore
    @Bindable var vipStore: VIPStore
    @Bindable var suggestionDismissals: SuggestionDismissalStore
    @Bindable var inbox: InboxStore
    let accountConnector: AccountConnector
    @Bindable var license: LicenseStore

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                iOSSplitView(
                    accountStore: accountStore,
                    settings: settings,
                    ruleStore: ruleStore,
                    categoryStore: categoryStore,
                    vipStore: vipStore,
                    suggestionDismissals: suggestionDismissals,
                    inbox: inbox,
                    accountConnector: accountConnector,
                    license: license
                )
            }
        }
    }

    private var compactLayout: some View {
        TabView {
            iOSMailboxesTab(
                accountStore: accountStore,
                settings: settings,
                categoryStore: categoryStore,
                inbox: inbox,
                accountConnector: accountConnector,
                license: license
            )
                .tabItem { Label("Mailboxes", systemImage: "tray.full") }

            iOSRulesTab(
                ruleStore: ruleStore,
                inbox: inbox,
                settings: settings,
                categoryStore: categoryStore,
                vipStore: vipStore,
                suggestionDismissals: suggestionDismissals
            )
                .tabItem { Label("Rules", systemImage: "wand.and.stars") }

            iOSSettingsTab(
                settings: settings,
                accountStore: accountStore,
                inbox: inbox,
                license: license
            )
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }

}
