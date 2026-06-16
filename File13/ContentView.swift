import File13Core
import SwiftUI

struct ContentView: View {
    @Bindable var inbox: InboxStore
    @Bindable var accountStore: AccountStore
    @Bindable var settings: SettingsStore
    @Bindable var ruleStore: RuleStore
    @Bindable var categoryStore: SenderCategoryStore
    @Bindable var suggestionDismissals: SuggestionDismissalStore
    @Bindable var vipStore: VIPStore
    @Bindable var cloudMirror: CloudKVSyncMirror
    @Bindable var license: LicenseStore

    @State private var showAddAccountSheet = false
    @State private var showInstallCLISheet = false
    /// Account currently open in `EditAccountSheet`, presented from the
    /// sidebar's per-account context menu. Used both for the routine
    /// "Edit Account…" case and the "Re-enter Password…" repair path
    /// when an existing account's connection has failed or gone
    /// offline-with-cache (typically: Gmail / Outlook app passwords
    /// revoked or rotated). The sheet routes to the same flow either
    /// way; only the menu label differs.
    @State private var editingAccount: Account?
    @State private var hasAttemptedAutoConnect = false
    @State private var hasAppliedDefaultScope = false
    @State private var analyzeSendersModel: AnalyzeSendersModel?
    @State private var inspectorPresented: Bool = false
    @State private var activityDrawerVisible: Bool = false

    // Shared state for the bulk-action toolbar items and their dialogs.
    @State private var bulkShowMovePicker = false
    @State private var bulkShowDeleteConfirm = false
    @State private var bulkRuleDraft: Rule?
    @State private var bulkUnsubscribeCandidates: [InboxStore.UnsubscribeCandidate]?
    @State private var bulkUnsubscribeAutoRun = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                inbox: inbox,
                onEditAccount: { editingAccount = $0 }
            )
                .navigationSplitViewColumnWidth(250)
        } detail: {
            detailView
        }
        .frame(minWidth: 880, minHeight: 560)
        .tint(settings.accentPalette.primary)
        .environment(\.accentPalette, settings.accentPalette)
        .preferredColorScheme(settings.appearance.colorScheme)
        .sheet(isPresented: $showAddAccountSheet) {
            AddAccountSheet(accountStore: accountStore, inbox: inbox, license: license)
        }
        .sheet(item: $editingAccount) { account in
            EditAccountSheet(accountStore: accountStore, inbox: inbox, account: account)
        }
        .sheet(isPresented: $showInstallCLISheet) {
            InstallCLIView(license: license)
        }
        .onReceive(NotificationCenter.default.publisher(for: .installFile13CLI)) { _ in
            showInstallCLISheet = true
        }
        .sheet(isPresented: Binding(
            get: { analyzeSendersModel != nil },
            set: { if !$0 { analyzeSendersModel = nil } }
        )) {
            if let model = analyzeSendersModel {
                AnalyzeSendersSheet(model: model, settings: settings)
            }
        }
        .task {
            guard !hasAttemptedAutoConnect else { return }
            hasAttemptedAutoConnect = true
            await autoConnect()
            inbox.reconcileScheduledRefresh()
        }
        .onChange(of: settings.refreshSchedule) {
            inbox.reconcileScheduledRefresh()
        }
        .onChange(of: settings.accentPalette, initial: true) {
            AccentColorOverride.apply(settings.accentPalette)
        }
        .onChange(of: settings.iCloudSyncEnabled, initial: true) {
            if settings.iCloudSyncEnabled {
                cloudMirror.start()
            } else {
                cloudMirror.stop()
            }
        }
    }

    private var detailView: some View {
        // `VerticalSplit` is an `NSSplitViewController`-backed two-pane
        // splitter that replaces SwiftUI's `VSplitView`. We needed it because
        // `VSplitView` has no public API to set the initial divider position
        // and its `idealHeight` hints don't reliably honor that — the
        // Activity drawer kept opening at minimum height regardless. AppKit
        // also handles the drag-resize directly, which is what kept smooth
        // resize working when we first migrated off a SwiftUI custom
        // divider; that property is preserved.
        ZStack(alignment: .trailing) {
            VerticalSplit(
                showsBottom: activityDrawerVisible,
                initialBottomRatio: 0.5,
                topMinHeight: 240,
                bottomMinHeight: 140
            ) {
                VStack(spacing: 0) {
                    if settings.dryRunMode {
                        DryRunBanner()
                    }
                    UndoBanner(store: inbox)
                    if let lastError = inbox.lastError {
                        // Show server errors unconditionally. Originally gated
                        // on `!senders.isEmpty` so the banner wouldn't clutter
                        // the empty state, but that hid the messages users
                        // needed most — including failed deletes / moves,
                        // which the user has no other way to learn about.
                        InlineErrorBanner(message: lastError) { inbox.lastError = nil }
                    }
                    mainContent
                    BulkActionBar(store: inbox)
                }
            } bottom: {
                ActivityView(
                    store: inbox,
                    categoryStore: categoryStore,
                    settings: settings,
                    ruleStore: ruleStore,
                    suggestionDismissals: suggestionDismissals,
                    vipStore: vipStore
                )
            }

            // Inspector floats on top of the detail content rather than
            // claiming layout space. This avoids cramping the AppKit-backed
            // sender table whose `lastColumnOnlyAutoresizingStyle` doesn't
            // play well with a NavigationSplitView column appearing alongside
            // it. A leading-edge divider preserves visual separation.
            if inspectorPresented {
                HStack(spacing: 0) {
                    Divider()
                    InspectorView(
                        store: inbox,
                        ruleStore: ruleStore,
                        settings: settings,
                        categoryStore: categoryStore,
                        suggestionDismissals: suggestionDismissals,
                        vipStore: vipStore,
                        onAnalyzeSenders: { openAnalyze(senders: $0) }
                    )
                    .frame(width: 360)
                    .background(.regularMaterial)
                }
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: inspectorPresented)
        .toolbar {
            BulkActionToolbar(
                store: inbox,
                ruleStore: ruleStore,
                onAnalyzeSenders: { openAnalyze(senders: $0) },
                showMovePicker: $bulkShowMovePicker,
                showDeleteConfirm: $bulkShowDeleteConfirm,
                ruleDraft: $bulkRuleDraft,
                unsubscribeCandidates: $bulkUnsubscribeCandidates,
                unsubscribeAutoRun: $bulkUnsubscribeAutoRun
            )
            ToolbarItem(placement: .primaryAction) {
                Spacer()
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        openAnalyze(senders: inbox.sendersInSelection)
                    } label: {
                        Label(
                            inbox.sendersInSelection.isEmpty
                                ? "Analyze selection"
                                : "Analyze selection (\(inbox.sendersInSelection.count))",
                            systemImage: "checkmark.circle"
                        )
                    }
                    .disabled(inbox.sendersInSelection.isEmpty)

                    Button {
                        openAnalyze(senders: inbox.topSendersByVolume(limit: 25))
                    } label: {
                        Label("Analyze top 25 senders", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    .disabled(inbox.senders.isEmpty)
                } label: {
                    Label("Analyze with AI", systemImage: "sparkles")
                }
                .disabled(inbox.senders.isEmpty && inbox.sendersInSelection.isEmpty)
                .help("AI triage: pick selection or top senders by volume.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    activityDrawerVisible.toggle()
                } label: {
                    Label("Activity", systemImage: "chart.bar.xaxis")
                }
                .help(activityDrawerVisible ? "Hide activity panel" : "Show activity panel")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    inspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help(inspectorPresented ? "Hide inspector" : "Show inspector")
            }
        }
        .modifier(BulkActionDialogs(
            store: inbox,
            ruleStore: ruleStore,
            showDeleteConfirm: $bulkShowDeleteConfirm,
            ruleDraft: $bulkRuleDraft,
            unsubscribeCandidates: $bulkUnsubscribeCandidates,
            unsubscribeAutoRun: bulkUnsubscribeAutoRun
        ))
    }

    @ViewBuilder
    private var mainContent: some View {
        switch displayMode {
        case .list:
            VStack(spacing: 0) {
                ViewModeSwitcher(store: inbox)
                listForCurrentMode
            }
        case .empty:
            EmptyStateView(
                onAddAccount: { showAddAccountSheet = true },
                onUseDemoData: { inbox.loadDemoData() }
            )
        case .connecting:
            LoadingStateView(title: "Connecting…", subtitle: connectingSubtitle)
        case .fetching:
            LoadingStateView(
                title: fetchingTitle,
                subtitle: "Headers only",
                onCancel: { inbox.cancelFetches() }
            )
        case .error(let msg):
            ErrorStateView(
                message: msg,
                onRetry: { Task { await retryConnect() } },
                onAddAccount: { showAddAccountSheet = true }
            )
        }
    }

    @ViewBuilder
    private var listForCurrentMode: some View {
        switch inbox.displayMode {
        case .sender:
            SenderListView(store: inbox, onAnalyzeSender: { openAnalyze(senders: [$0]) })
        case .subject: SubjectListView(store: inbox)
        case .date:    DateListView(store: inbox)
        }
    }

    private func openAnalyze(senders: [Sender]) {
        guard !senders.isEmpty else { return }
        let provider = LLMProviderFactory.make(for: .senderAdvice, settings: settings)
        analyzeSendersModel = AnalyzeSendersModel(
            inbox: inbox,
            ruleStore: ruleStore,
            provider: provider,
            tuning: settings.tuning(for: .senderAdvice),
            senders: senders
        )
    }

    private enum DisplayMode {
        case list, empty, connecting, fetching, error(String)
    }

    private var displayMode: DisplayMode {
        if !inbox.senders.isEmpty { return .list }
        switch inbox.connectionState {
        case .connecting: return .connecting
        case .fetching:   return .fetching
        case .failed(let m): return .error(m)
        case .connected:  return .list
        case .offlineWithCache:
            // Cached headers should already have populated `senders`, but
            // if the cache happened to be empty (first launch with an
            // account that's never synced), fall through to .list so the
            // standard empty-mailbox treatment renders rather than a
            // confusing "Connecting…" spinner.
            return .list
        case .disconnected:
            return accountStore.accounts.isEmpty ? .empty : .connecting
        }
    }

    private var isLoading: Bool {
        switch inbox.connectionState {
        case .connecting, .fetching: true
        default: false
        }
    }

    private var fetchingTitle: String { inbox.fetchProgressTitle }

    private var connectingSubtitle: String? {
        switch inbox.scope {
        case .unified:
            let count = inbox.sessions.count
            return count > 0 ? "\(count) account\(count == 1 ? "" : "s")" : nil
        case .account:
            return inbox.activeSession?.account.address
        }
    }

    private func autoConnect() async {
        let toConnect = accountStore.accounts.filter { acct in
            !inbox.sessions.contains(where: { $0.id == acct.id })
        }
        await withTaskGroup(of: Void.self) { group in
            for account in toConnect {
                group.addTask { @MainActor in
                    do {
                        let credentials = try await accountStore.credentials(for: account)
                        await inbox.connect(account: account, credentials: credentials)
                    } catch {
                        // Most common cause: the user is locked out of their
                        // Keychain at first launch (FileVault unlocked but
                        // Keychain still locked, or no login session yet on
                        // a freshly-rebooted Mac). Previously this `try?`
                        // swallowed the error and the account showed
                        // disconnected with no diagnostic — the user had
                        // no way to know what to do. Now the main banner
                        // tells them to unlock and retry.
                        inbox.lastError = "Couldn't read the password for \(account.displayName). Unlock your Keychain and refresh — \(error.localizedDescription)"
                    }
                }
            }
        }
        applyDefaultInboxScope()
    }

    /// Applies `settings.defaultInboxScope` after auto-connect runs. We do this
    /// once at startup, not reactively — the user can switch scope from the
    /// sidebar after launch and we don't want the setting to override their
    /// in-session choice.
    private func applyDefaultInboxScope() {
        guard !hasAppliedDefaultScope else { return }
        hasAppliedDefaultScope = true
        switch settings.defaultInboxScope {
        case .unified:
            inbox.scope = .unified
        case .account(let id):
            // If the chosen account no longer exists (deleted or not yet
            // connected), fall back to unified so the user isn't stuck on an
            // empty scope.
            if accountStore.accounts.contains(where: { $0.id == id }) {
                inbox.scope = .account(id)
            } else {
                inbox.scope = .unified
            }
        }
    }

    private func retryConnect() async {
        await autoConnect()
    }
}

private struct ViewModeSwitcher: View {
    @Bindable var store: InboxStore

    var body: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $store.displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Toggle(isOn: $store.newslettersOnly) {
                Label("Newsletters only", systemImage: "envelope.badge")
            }
            .toggleStyle(.button)
            .controlSize(.regular)
            .help("Show only senders flagged as newsletters or auto-mail (List-Unsubscribe / List-ID / Auto-Submitted).")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct DryRunBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
            Text("Dry Run Mode: actions update this view but are not committed to the mail server.")
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.18))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct InlineErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

#Preview {
    ContentView(
        inbox: InboxStore(senders: MockInbox.generate()),
        accountStore: AccountStore(),
        settings: SettingsStore(),
        ruleStore: RuleStore(),
        categoryStore: SenderCategoryStore(),
        suggestionDismissals: SuggestionDismissalStore(),
        vipStore: VIPStore(),
        cloudMirror: CloudKVSyncMirror(),
        license: LicenseStore()
    )
}
