import File13Core
import SwiftData
import SwiftUI

/// iOS / iPadOS entry point. Mirrors what the macOS `File13App` does for the
/// pieces that overlap (App Group migration, SwiftData container, license
/// bootstrap, the shared `InboxStore`), and omits the rest (login items,
/// AppKit accent override, CLI embedding, menu bar commands).
///
/// Universal Purchase: same bundle id as the macOS target
/// (`com.shawnbrown.File13`), so a Pro purchase from either platform
/// satisfies the entitlement check on the other.
@main
struct File13iOSApp: App {
    @State private var accountStore: AccountStore
    @State private var settings: SettingsStore
    @State private var ruleStore = RuleStore()
    @State private var categoryStore = SenderCategoryStore()
    @State private var vipStore = VIPStore()
    @State private var repliedStore = RepliedMessagesStore()
    @State private var suggestionDismissals = SuggestionDismissalStore()
    @State private var inbox: InboxStore
    @State private var license = LicenseStore()
    private let modelContainer: ModelContainer

    /// Bump in lockstep with the macOS app — same on-disk schema, same SwiftData
    /// store at the App Group location, same migration trigger value.
    private static let headersSchemaVersion = 3

    init() {
        // Move any pre-App-Group UserDefaults values into the shared suite
        // before any store reads. Idempotent.
        SharedDefaults.migrateFromStandardIfNeeded()

        let container = Self.makeContainer()
        self.modelContainer = container
        let cache = MessageCache(context: container.mainContext)
        MessageCache.runSchemaMigrationIfNeeded(version: Self.headersSchemaVersion, cache: cache)

        let initialSettings = SettingsStore()
        let initialAccountStore = AccountStore()
        initialSettings.iCloudKeychainSyncMigrator = { enabled in
            for account in initialAccountStore.accounts {
                try? KeychainStore.migrateAccountPassword(for: account.id, toSynchronizable: enabled)
                try? KeychainStore.migrateOAuthTokens(for: account.id, toSynchronizable: enabled)
            }
            for kind in AIProviderKind.allCases {
                try? KeychainStore.migrateAIKey(for: kind, toSynchronizable: enabled)
            }
        }
        let initialCategoryStore = SenderCategoryStore()
        let initialVIPStore = VIPStore()
        let initialRepliedStore = RepliedMessagesStore()
        _accountStore = State(initialValue: initialAccountStore)
        _settings = State(initialValue: initialSettings)
        _categoryStore = State(initialValue: initialCategoryStore)
        _vipStore = State(initialValue: initialVIPStore)
        _repliedStore = State(initialValue: initialRepliedStore)
        // Shared with the macOS app via `File13Core`. iOS uses the same
        // store for session lifecycle, multi-select state, buffered actions,
        // and (in subsequent PRs) sender / subject / date aggregation, rule
        // running, AI activity.
        _inbox = State(initialValue: InboxStore(
            cache: cache,
            settings: initialSettings,
            categoryStore: initialCategoryStore,
            vipStore: initialVIPStore,
            repliedStore: initialRepliedStore
        ))
    }

    /// Same SwiftData store path as the macOS app — the App Group container —
    /// so a user on the same Apple ID syncing settings via iCloud sees their
    /// account list and triage state on both platforms.
    private static func makeContainer() -> ModelContainer {
        let storeURL = SharedContainerURL.swiftDataStore()
        let config = ModelConfiguration(url: storeURL)
        do {
            return try ModelContainer(for: CachedMessage.self, configurations: config)
        } catch {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
            do {
                return try ModelContainer(for: CachedMessage.self, configurations: config)
            } catch {
                fatalError("Couldn't create SwiftData model container after reset: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            iOSRootView(
                accountStore: accountStore,
                settings: settings,
                ruleStore: ruleStore,
                categoryStore: categoryStore,
                vipStore: vipStore,
                suggestionDismissals: suggestionDismissals,
                inbox: inbox,
                accountConnector: AccountConnector(accountStore: accountStore, inbox: inbox),
                license: license
            )
            .task {
                await license.bootstrap()
                AppIconApplier.apply(settings.appIcon, tier: license.tier)
            }
            .onChange(of: settings.appIcon) { _, choice in
                AppIconApplier.apply(choice, tier: license.tier)
            }
            .onChange(of: license.tier) { _, tier in
                AppIconApplier.apply(settings.appIcon, tier: tier)
            }
        }
        .modelContainer(modelContainer)
    }
}

/// Small adapter that bundles the credentials-lookup + InboxStore.connect
/// dance into a single async call. Views shouldn't have to reach into
/// `AccountStore.credentials(for:)` themselves — the iOS message list / split
/// view's job is to call `connect(account:)` and let this fold in the keychain
/// fetch and the OAuth refresh-on-expiry path.
@MainActor
final class AccountConnector {
    let accountStore: AccountStore
    let inbox: InboxStore

    init(accountStore: AccountStore, inbox: InboxStore) {
        self.accountStore = accountStore
        self.inbox = inbox
    }

    /// Idempotent: if the session is already connected (or actively
    /// connecting), no-op. Otherwise fetches credentials and kicks off
    /// `inbox.connect`. Failures surface on the session's `lastError`.
    func connect(_ account: Account) async {
        let session = inbox.ensureSession(for: account)
        switch session.connectionState {
        case .connected, .connecting, .fetching:
            return
        case .disconnected, .failed, .offlineWithCache:
            // `.offlineWithCache` is a non-live state (the previous
            // connect failed but cached headers are showing). Allow a
            // fresh attempt — the user may have just regained network.
            break
        }
        do {
            let credentials = try await accountStore.credentials(for: account)
            _ = await inbox.connect(account: account, credentials: credentials)
        } catch {
            session.lastError = "Couldn't load credentials: \(error.localizedDescription)"
        }
    }
}
