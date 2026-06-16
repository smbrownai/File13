import File13Core
import SwiftData
import SwiftUI

@main
struct File13App: App {
    /// Adopt an `NSApplicationDelegate` so we can implement
    /// `applicationShouldTerminate` — the only AppKit hook that lets
    /// us defer quit while pending IMAP work commits. See
    /// `File13AppDelegate` for the full rationale. Apple constructs
    /// the delegate before our `App.init` runs, so the stores get
    /// injected lazily from `.body` via `.task` rather than at
    /// delegate-init time.
    @NSApplicationDelegateAdaptor(File13AppDelegate.self) private var appDelegate

    @State private var inbox: InboxStore
    @State private var accountStore: AccountStore
    @State private var settings: SettingsStore
    @State private var ruleStore = RuleStore()
    @State private var categoryStore = SenderCategoryStore()
    @State private var suggestionDismissals = SuggestionDismissalStore()
    @State private var vipStore = VIPStore()
    @State private var repliedStore = RepliedMessagesStore()
    @State private var cloudMirror = CloudKVSyncMirror()
    @State private var license = LicenseStore()
    private let modelContainer: ModelContainer

    /// Process-level lock on the App Group container. Held for the lifetime of the GUI app
    /// so the headless `file13` CLI bails (exit 2) when run while the GUI is open, and
    /// vice versa. Owned by the `App` value to keep the file descriptor alive.
    private static let containerLock = LockFile()

    /// Bump this whenever the cached header set gains new fields that incremental sync wouldn't
    /// otherwise backfill (e.g., List-Unsubscribe-Post). Forces one full re-sync per account.
    private static let headersSchemaVersion = 3

    init() {
        // Install the AppKit accent override before any window opens so the
        // very first paint of toolbars, dialogs, and the sidebar selection
        // pill already use the user's chosen palette.
        AccentColorOverride.install()

        // First thing on launch: copy any pre-existing UserDefaults data from `.standard` into
        // the App Group suite, exactly once. After this, every store reads/writes the suite
        // so the headless `file13` CLI can see the same state. Idempotent.
        SharedDefaults.migrateFromStandardIfNeeded()

        // Take the container lock so the CLI can't open the SwiftData store concurrently.
        // We never block: if another process holds it, log and continue (the GUI is the
        // primary; a stuck CLI process is the user's problem, not ours).
        switch Self.containerLock.tryAcquire() {
        case .acquired:
            break
        case .heldByOther:
            print("warning: File13 container lock held by another process — opening SwiftData anyway")
        case .error(let message):
            print("warning: File13 container lock error: \(message)")
        }

        self.modelContainer = Self.makeContainer()
        let cache = MessageCache(context: modelContainer.mainContext)
        MessageCache.runSchemaMigrationIfNeeded(version: Self.headersSchemaVersion, cache: cache)
        let initialSettings = SettingsStore()
        let initialAccountStore = AccountStore()
        // Rewrite already-stored IMAP and AI credentials when the user toggles
        // iCloud Keychain sync. `kSecAttrSynchronizable` is part of a keychain
        // item's primary key, so we have to delete and re-add — there's no
        // SecItemUpdate path that flips the bit.
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
        _inbox = State(initialValue: InboxStore(
            cache: cache,
            settings: initialSettings,
            categoryStore: initialCategoryStore,
            vipStore: initialVIPStore,
            repliedStore: initialRepliedStore
        ))

        // Seed the AppKit accent override from the persisted palette so
        // already-mounted windows (e.g. the menu bar) tint correctly even
        // before ContentView's `onChange` fires.
        AccentColorOverride.apply(initialSettings.accentPalette)
    }

    private static func makeContainer() -> ModelContainer {
        // The store lives in the App Group container so the CLI can open it too. Older
        // installs had a sandbox-relative store at applicationSupportDirectory; first
        // launch after upgrade copies that over so the user's cached headers don't
        // disappear.
        Self.migrateLegacyStoreIfNeeded()

        let storeURL = SharedContainerURL.swiftDataStore()
        let config = ModelConfiguration(url: storeURL)
        do {
            return try ModelContainer(for: CachedMessage.self, configurations: config)
        } catch {
            // Reset on corruption — wipe the three SQLite files at the new location and retry.
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

    /// Copy the pre-App-Group SwiftData store from the legacy sandbox path into the App
    /// Group container, exactly once. No-op on a fresh install or after the migration has
    /// already run. Conservative: never overwrites a non-empty file at the destination.
    private static func migrateLegacyStoreIfNeeded() {
        let dest = SharedContainerURL.swiftDataStore()
        if FileManager.default.fileExists(atPath: dest.path) { return }
        let legacy = URL.applicationSupportDirectory.appending(path: "default.store")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        for ext in ["", "-shm", "-wal"] {
            let from = ext.isEmpty ? legacy : legacy.appendingPathExtension(String(ext.dropFirst()))
            let to   = ext.isEmpty ? dest   : dest.appendingPathExtension(String(ext.dropFirst()))
            try? FileManager.default.copyItem(at: from, to: to)
        }
    }

    var body: some Scene {
        WindowGroup("Email Cleaner") {
            ContentView(
                inbox: inbox,
                accountStore: accountStore,
                settings: settings,
                ruleStore: ruleStore,
                categoryStore: categoryStore,
                suggestionDismissals: suggestionDismissals,
                vipStore: vipStore,
                cloudMirror: cloudMirror,
                license: license
            )
                .task {
                    await license.bootstrap()
                    // License tier is settled — apply the persisted app-icon
                    // choice. If the user picked a Pro alternate but isn't Pro
                    // (e.g. refund, free-tier device receiving a synced choice),
                    // the applier reverts to the default.
                    AppIconApplier.apply(settings.appIcon, tier: license.tier)
                }
                .onChange(of: settings.appIcon) { _, choice in
                    AppIconApplier.apply(choice, tier: license.tier)
                }
                .onChange(of: license.tier) { _, tier in
                    AppIconApplier.apply(settings.appIcon, tier: tier)
                }
                .task {
                    // Hand the live stores to the AppDelegate so its
                    // `applicationShouldTerminate` hook can commit
                    // pending IMAP actions + flush iCloud dirty flags
                    // before exit. Apple constructs the delegate
                    // before `File13App.init` runs, so this is the
                    // first reliable place to inject the references.
                    appDelegate.inbox = inbox
                    appDelegate.cloudMirror = cloudMirror
                }
                .task {
                    await runRulesOnLaunchIfNeeded()
                }
                .task(id: ruleStore.schedule) {
                    await runScheduledRulesLoop()
                }
                .task {
                    // Surface `FileBackedUserDefaults` write failures
                    // (disk-full, permission denied on the App Group
                    // container) on the main banner instead of letting
                    // settings changes silently disappear. The
                    // notification is posted from File13Core — see
                    // the comment on `.fileBackedDefaultsWriteFailed`.
                    let stream = NotificationCenter.default.notifications(
                        named: .fileBackedDefaultsWriteFailed
                    )
                    for await note in stream {
                        let message = (note.userInfo?["error"] as? String) ?? "unknown error"
                        inbox.lastError = "Couldn't save settings — \(message). Your most recent change wasn't written. Check that your disk isn't full."
                    }
                }
        }
        .modelContainer(modelContainer)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    inbox.undoPendingAction()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(inbox.pendingAction == nil)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Select All Visible") {
                    inbox.selectAllVisible()
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(inbox.senders.isEmpty)

                Button("Clear Selection") {
                    inbox.clearSelection()
                }
                .disabled(!inbox.hasSelection)

                Button("Delete Selection") {
                    inbox.startDelete()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!inbox.hasSelection)

                Divider()
                Button("Refresh Inbox") {
                    Task { await inbox.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(inbox.sessions.isEmpty)

                Button("Install File13 CLI…") {
                    NotificationCenter.default.post(name: .installFile13CLI, object: nil)
                }

                Button("Run Rules Now") {
                    Task {
                        let report = await inbox.runRules(ruleStore.enabledRules)
                        ruleStore.recordRun(report)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(inbox.sessions.isEmpty || ruleStore.enabledRules.isEmpty)
            }
            HelpCommands()
            AboutCommands()
        }

        Window("File13 Help", id: HelpWindowID) {
            HelpWindowView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 880, height: 600)

        Window("About File13", id: AboutWindowID) {
            AboutWindowView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(
                settings: settings,
                accountStore: accountStore,
                inbox: inbox,
                ruleStore: ruleStore,
                categoryStore: categoryStore,
                suggestionDismissals: suggestionDismissals,
                vipStore: vipStore,
                repliedStore: repliedStore,
                license: license
            )
        }
    }

    private func runRulesOnLaunchIfNeeded() async {
        guard ruleStore.schedule == .onLaunch else { return }
        // Wait until at least one session reaches connected.
        for _ in 0..<60 {
            if inbox.sessions.contains(where: { $0.connectionState == .connected }) { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard inbox.sessions.contains(where: { $0.connectionState == .connected }) else { return }
        let report = await inbox.runRules(ruleStore.enabledRules)
        ruleStore.recordRun(report)
    }

    private func runScheduledRulesLoop() async {
        switch ruleStore.schedule {
        case .manual, .onLaunch:
            return // No timer needed; the .task will end and SwiftUI will restart it on schedule change.
        case .hourly:
            while !Task.isCancelled {
                let delay = Self.nextHourlyDelaySeconds()
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                await fireScheduledRun()
            }
        case .daily:
            while !Task.isCancelled {
                let delay = Self.nextDailyDelaySeconds(at: 3)
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                await fireScheduledRun()
            }
        }
    }

    private func fireScheduledRun() async {
        guard inbox.sessions.contains(where: { $0.connectionState == .connected }) else { return }
        let report = await inbox.runRules(ruleStore.enabledRules)
        ruleStore.recordRun(report)
    }

    /// Seconds until the next wall-clock hour boundary (`:00`). Anchoring to
    /// the wall clock instead of "60 minutes from when the timer was armed"
    /// makes the schedule predictable across app restarts and matches what
    /// users expect when they read "Hourly" in Settings.
    static func nextHourlyDelaySeconds(now: Date = .now) -> TimeInterval {
        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day, .hour], from: now)
        components.hour = (components.hour ?? 0) + 1
        components.minute = 0
        components.second = 0
        let next = cal.date(from: components) ?? now.addingTimeInterval(3600)
        // Floor the delay at 60s so we never busy-loop right after a fire.
        return max(60, next.timeIntervalSince(now))
    }

    /// Seconds until the next occurrence of the given local-clock hour (e.g. 3 → 3 AM).
    private static func nextDailyDelaySeconds(at hour: Int) -> TimeInterval {
        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day], from: .now)
        components.hour = hour
        components.minute = 0
        components.second = 0
        var next = cal.date(from: components) ?? .now
        if next <= .now {
            next = cal.date(byAdding: .day, value: 1, to: next) ?? next
        }
        return max(60, next.timeIntervalSince(.now))
    }
}
