import File13Core
import SwiftUI

/// Per-account INBOX view. Renders the latest cached headers chronologically,
/// supports multi-select via the standard iOS `EditMode`, and exposes Delete /
/// Archive bulk actions in the toolbar. Pull-to-refresh fires the session's
/// `refresh()` so newly-arrived headers appear without leaving the screen.
///
/// Scope is deliberately narrow: one account, the active mailbox (always
/// `INBOX` in v1 — mailbox switching follows alongside sender / subject views).
///
/// Selection and the buffered pending action both live on the shared
/// `InboxStore`, so `EditMode` multi-select drives the same code path the
/// macOS app uses. The SwiftUI `List(selection:)` is bound directly to
/// `inbox.selectedMessageIds` — no parallel `@State` to keep in sync.
struct iOSMessageListView: View {
    let account: Account
    @Bindable var inbox: InboxStore
    @Bindable var settings: SettingsStore
    @Bindable var categoryStore: SenderCategoryStore
    let accountConnector: AccountConnector

    @State private var editMode: EditMode = .inactive
    @State private var showDeleteConfirm = false
    @State private var showArchiveError = false
    @State private var showMoveSheet = false
    /// Message ids waiting on confirmation from a per-row swipe Delete. We
    /// can't hold the swipe open while the user decides — the row collapses
    /// immediately. Stash the target here so the confirmation dialog can
    /// fire `applyOneOff` on OK. `nil` ⇒ no swipe-delete is pending.
    @State private var pendingSwipeDeleteIds: Set<String>?
    /// Set when the user taps the toolbar's Empty button on a Trash/Junk
    /// mailbox. Carries the count we showed in the confirmation dialog so
    /// the message reads with the same number even if STATUS races mid-tap.
    @State private var emptyConfirmCount: Int?
    /// Flips to `true` the first time we observe `.connected` for this session.
    /// After that, we never blank the screen for a `.fetching` state again —
    /// switching mailboxes keeps the list and the picker visible and surfaces
    /// progress via the inline banner instead. Without this, picking a folder
    /// on a large mailbox dropped the whole UI behind a spinner for the
    /// duration of the UID-flags + headers fetch.
    @State private var hasEverConnected = false

    /// The InboxStore-managed session for this view's account. `ensureSession`
    /// is idempotent and cheap; the IMAP socket only opens when
    /// `accountConnector.connect(account:)` fires from `.task`.
    private var session: AccountSession { inbox.ensureSession(for: account) }

    var body: some View {
        Group {
            switch session.connectionState {
            case .disconnected:
                connectingState("Preparing…")
            case .connecting:
                connectingState("Connecting to \(account.host)…")
            case .fetching:
                // First-ever connect: no cached headers yet, full-screen
                // spinner is appropriate. Once the session has been connected
                // once, a `.fetching` state means the user switched mailboxes —
                // keep the list path so the title bar, picker, and inline
                // progress banner stay visible.
                if hasEverConnected {
                    connectedBody
                } else {
                    connectingState("Fetching headers…")
                }
            case .connected:
                if session.headers.isEmpty {
                    if session.isRefreshing {
                        connectingState("Fetching headers…")
                    } else {
                        emptyMailbox
                    }
                } else {
                    connectedBody
                }
            case .failed(let message):
                failedState(message)
            case .offlineWithCache:
                // Cached headers loaded; render the standard connected
                // body. The sidebar / inbox-level banner already
                // surfaces the offline state on macOS; on iOS the
                // user-facing copy will surface via `inbox.lastError`
                // (set by `InboxStore.connect`). Empty-mailbox state
                // here is also handled by the inner branch since
                // `headers.isEmpty` triggers the same empty UI.
                if session.headers.isEmpty {
                    emptyMailbox
                } else {
                    connectedBody
                }
            }
        }
        .onChange(of: session.connectionState) { _, newState in
            if case .connected = newState { hasEverConnected = true }
        }
        .navigationTitle(session.currentMailboxDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar { toolbarContent }
        .refreshable {
            // Route through InboxStore.refresh() rather than the bare
            // session call so the auto-categorize-new-senders hook gets a
            // chance to fire when the user has the setting on. With
            // `inbox.scope = .account(account.id)` set in `.task`, this
            // refreshes only the active session, same effective behavior
            // for the user.
            await inbox.refresh()
        }
        .task {
            // Scope drives which sessions InboxStore aggregates over and what
            // `startDelete` / `archiveSelection` operate on. We set it to this
            // view's account so bulk actions only ever touch this mailbox,
            // regardless of what else is connected.
            inbox.scope = .account(account.id)
            await accountConnector.connect(account)
        }
        .onDisappear {
            // Leaving the per-account view clears any selection it owned, so
            // a stale selection can't drive an InboxStore action from
            // elsewhere (e.g. a future toolbar elsewhere in the app).
            inbox.clearSelection()
            editMode = .inactive
        }
        .onChange(of: session.currentMailbox) { _, _ in
            // Switching mailbox invalidates any in-progress selection — those
            // ids point at the previous mailbox's messages. Clear so the user
            // doesn't accidentally act on a phantom selection in the new view.
            inbox.clearSelection()
            editMode = .inactive
        }
        .onChange(of: inbox.displayMode) { _, _ in
            // A partial selection in sender mode wouldn't map cleanly to
            // chronological mode (and vice versa), so flip clears it.
            inbox.clearSelection()
            editMode = .inactive
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Bulk-action bar — same shape and code path as
            // `iOSSenderDetailView.bulkActionBar`. Lives in a bottom
            // safe-area inset (rather than `.toolbar(... .bottomBar)`) so
            // it sits above the system tab bar with no overlap and the
            // tab bar stays put. Smoother than the previous "hide the
            // tab bar while editing" trick that shifted everything.
            if editMode == .active && !inbox.selectedMessageIds.isEmpty {
                bulkActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Per-account banner filter: the pending action's `perAccount`
            // entries name the affected account, so iPad split-view users
            // navigating between accounts don't see a stale banner.
            if let pending = inbox.pendingAction,
               pending.perAccount.contains(where: { $0.accountId == account.id }) {
                iOSUndoBanner(pending: pending) {
                    inbox.undoPendingAction()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: editMode)
        .animation(.snappy, value: inbox.selectedMessageIds.isEmpty)
        .animation(.snappy, value: inbox.pendingAction)
        .confirmationDialog(
            "Delete \(inbox.selectedMessageIds.count) message\(inbox.selectedMessageIds.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                editMode = .inactive
                inbox.startDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(settings.dryRunMode
                 ? "Dry-run mode is on — local list will update but the server won't be touched."
                 : "You'll have \(settings.undoBufferSeconds) seconds to undo before it commits to the server.")
        }
        .confirmationDialog(
            "Delete \(pendingSwipeDeleteIds?.count ?? 0) message\((pendingSwipeDeleteIds?.count ?? 0) == 1 ? "" : "s")?",
            isPresented: Binding(
                get: { pendingSwipeDeleteIds != nil },
                set: { if !$0 { pendingSwipeDeleteIds = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let ids = pendingSwipeDeleteIds {
                    applyOneOff(.delete, to: ids)
                }
                pendingSwipeDeleteIds = nil
            }
            Button("Cancel", role: .cancel) { pendingSwipeDeleteIds = nil }
        } message: {
            Text(settings.dryRunMode
                 ? "Dry-run mode is on — local list will update but the server won't be touched."
                 : "You'll have \(settings.undoBufferSeconds) seconds to undo before it commits to the server.")
        }
        .confirmationDialog(
            // Title pulls from the live mailbox display name so Gmail
            // users see "Empty Trash" and POP/IMAP users see whatever
            // their server calls it (Deleted Items, Bin, …).
            "Empty \(currentEmptyableMailbox?.displayName ?? "this folder")?",
            isPresented: Binding(
                get: { emptyConfirmCount != nil },
                set: { if !$0 { emptyConfirmCount = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Empty \(currentEmptyableMailbox?.displayName ?? "")", role: .destructive) {
                if let name = currentEmptyableMailbox?.name {
                    Task { await inbox.emptyMailbox(named: name) }
                }
                emptyConfirmCount = nil
            }
            Button("Cancel", role: .cancel) { emptyConfirmCount = nil }
        } message: {
            let n = emptyConfirmCount ?? 0
            Text("This permanently deletes \(n.formatted()) message\(n == 1 ? "" : "s") on the mail server. This cannot be undone.")
        }
        .alert(
            "No archive folder",
            isPresented: $showArchiveError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This account didn't report an archive mailbox. Try Delete, or pick a destination on the Mac app for now.")
        }
        .sheet(isPresented: $showMoveSheet) {
            iOSMoveToFolderSheet(inbox: inbox, session: session)
        }
    }

    // MARK: - States

    /// Connected (or post-first-connect fetching) body. Renders the chosen
    /// display mode with a thin progress banner stacked at the top so the
    /// user always sees the app working during a mailbox switch instead of
    /// a blank screen.
    @ViewBuilder
    private var connectedBody: some View {
        VStack(spacing: 0) {
            if settings.dryRunMode {
                DryRunBanner()
            }
            FetchProgressBanner(session: session)
            // Display mode is shared state on `InboxStore`. The picker in the
            // toolbar writes to it; the body re-renders into the matching
            // layout. All three modes from the macOS app are wired now.
            switch inbox.displayMode {
            case .sender:
                iOSSenderListView(inbox: inbox, settings: settings, categoryStore: categoryStore)
            case .subject:
                iOSSubjectListView(inbox: inbox, settings: settings)
            case .date:
                if session.headers.isEmpty {
                    emptyMailbox
                } else {
                    messageList
                }
            }
        }
    }

    private func connectingState(_ message: String) -> some View {
        VStack(spacing: 16) {
            // Show a determinate bar once the server has reported the new-UID
            // count; until then, an indeterminate spinner is the best we can do.
            if session.fetchTotal > 0 {
                ProgressView(value: Double(session.fetchProgress),
                             total: Double(session.fetchTotal))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text("\(session.fetchProgress.formatted()) of \(session.fetchTotal.formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView()
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyMailbox: some View {
        ContentUnavailableView {
            Label("Inbox empty", systemImage: "tray")
        } description: {
            Text("Pull down to refresh.")
        }
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await accountConnector.connect(account) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var messageList: some View {
        List(selection: $inbox.selectedMessageIds) {
            // Show either kind of error. `session.lastError` covers
            // connect/refresh failures the session sets directly;
            // `inbox.lastError` is where InboxStore.surfaceSessionErrors
            // promotes per-commit failures so the cross-platform banner on
            // macOS can render them. Either one means "user needs to know
            // something didn't work."
            if let lastError = inbox.lastError ?? session.lastError {
                Section {
                    Label(lastError, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            ForEach(session.headers) { header in
                MessageRow(header: header)
                    .tag(header.id)
                    // Trailing swipe → Delete (destructive). Full swipe goes
                    // straight to the action — matches iOS Mail. Server commit
                    // is buffered through InboxStore's pending-action with
                    // undo, same as the bottom-bar Delete.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            if settings.confirmBeforeDelete {
                                pendingSwipeDeleteIds = [header.id]
                            } else {
                                applyOneOff(.delete, to: [header.id])
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    // Leading swipe → Archive. Disabled when the account
                    // didn't advertise an archive mailbox so the user doesn't
                    // tap into a silent no-op.
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            if inbox.archiveMailboxName == nil {
                                showArchiveError = true
                            } else {
                                applyOneOff(.archive, to: [header.id])
                            }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.blue)
                    }
            }
            tabBarSpacer
        }
        .listStyle(.plain)
    }

    /// One-off bulk action on a specific set of message ids that doesn't
    /// disturb the user's current multi-select. The shape mirrors
    /// `InboxStore.applyAction(_:toSender:)`: save the visible selection,
    /// swap to the ids we want acted on, fire the buffered action (which
    /// clears selection internally), and restore so the user's checkmarks
    /// don't disappear under them.
    private func applyOneOff(_ kind: InboxStore.PendingAction.Kind, to ids: Set<String>) {
        let saved = inbox.selectedMessageIds
        inbox.selectedMessageIds = ids
        switch kind {
        case .delete:                  inbox.startDelete()
        case .archive:                 inbox.archiveSelection()
        case .move(let destination):   inbox.moveSelection(to: destination)
        }
        inbox.selectedMessageIds = saved
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            displayModeMenu
        }
        ToolbarItem(placement: .principal) {
            mailboxPicker
        }
        // Empty-trash / Empty-spam button. Only appears when the active
        // mailbox is a Trash or Junk container that holds at least one
        // message — same restriction the macOS sidebar context menu uses.
        // Placed before Select so the destructive action is harder to
        // hit by accident: Select is where the user's thumb expects it.
        if let emptyable = currentEmptyableMailbox {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    emptyConfirmCount = emptyable.messageCount ?? session.headers.count
                } label: {
                    Label(
                        emptyable.kind == .trash ? "Empty Trash" : "Empty \(emptyable.displayName)",
                        systemImage: "trash.slash"
                    )
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            // Hand-rolled multi-select toggle instead of SwiftUI's
            // `EditButton()`. `EditButton` reads / writes EditMode via
            // `@Environment(\.editMode)` and renders its own label as
            // "Edit" / "Done", which (a) doesn't communicate "tap me to
            // select multiple senders" as cleanly as "Select" in this
            // read-only triage context, and (b) historically rendered as
            // "Edit" in an app where there's nothing to edit per-row.
            Button {
                withAnimation {
                    editMode = (editMode == .active) ? .inactive : .active
                }
            } label: {
                Text(editMode == .active ? "Done" : "Select")
                    .fontWeight(editMode == .active ? .semibold : .regular)
            }
            .disabled(session.headers.isEmpty)
        }
    }

    /// Returns the active mailbox iff it's Trash or Junk and contains at
    /// least one message — i.e. the conditions under which the "Empty"
    /// toolbar button should be offered. Pulls the count from the cached
    /// `Mailbox.messageCount` (server STATUS); if STATUS hasn't run yet
    /// for the current selection, falls back to the in-memory header
    /// count so we don't disable the button on first paint.
    private var currentEmptyableMailbox: Mailbox? {
        guard let mailbox = session.mailboxes.first(where: { $0.name == session.currentMailbox }),
              mailbox.kind == .trash || mailbox.kind == .junk
        else { return nil }
        let count = mailbox.messageCount ?? session.headers.count
        return count > 0 ? mailbox : nil
    }

    /// Bulk-action bar pinned in the bottom safe-area inset, above the
    /// system tab bar. Same icon trio (Delete / Move / Archive) and same
    /// behavior as `iOSSenderDetailView.bulkActionBar` — single source of
    /// truth would be nicer, but the two views call into different
    /// per-action state and dialogs, so a shared shape is cleaner than a
    /// shared component.
    private var bulkActionBar: some View {
        HStack(spacing: 24) {
            Button(role: .destructive) {
                if settings.confirmBeforeDelete {
                    showDeleteConfirm = true
                } else {
                    editMode = .inactive
                    inbox.startDelete()
                }
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
            }
            Button {
                showMoveSheet = true
            } label: {
                Label("Move", systemImage: "folder")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .disabled(!hasMoveDestinations)
            Button {
                if inbox.archiveMailboxName == nil {
                    showArchiveError = true
                } else {
                    editMode = .inactive
                    inbox.archiveSelection()
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Whether the session has any mailboxes the user could move into.
    /// At least one mailbox other than the current one must exist; otherwise
    /// the Move button is disabled (avoids tapping into an empty sheet).
    private var hasMoveDestinations: Bool {
        session.mailboxes.contains { $0.name != session.currentMailbox }
    }

    private var displayModeMenu: some View {
        Menu {
            Button {
                inbox.displayMode = .sender
            } label: {
                Label("Senders", systemImage: "person.2")
                    .labelStyle(.titleAndIcon)
            }
            Button {
                inbox.displayMode = .subject
            } label: {
                Label("Subjects", systemImage: "text.alignleft")
                    .labelStyle(.titleAndIcon)
            }
            Button {
                inbox.displayMode = .date
            } label: {
                Label("Chronological", systemImage: "calendar")
                    .labelStyle(.titleAndIcon)
            }
        } label: {
            Label(displayModeLabel, systemImage: displayModeSymbol)
                .labelStyle(.iconOnly)
        }
    }

    private var displayModeLabel: String {
        switch inbox.displayMode {
        case .sender:   return "Senders"
        case .subject:  return "Subjects"
        case .date:     return "Chronological"
        }
    }

    private var displayModeSymbol: String {
        switch inbox.displayMode {
        case .sender:   return "person.2"
        case .subject:  return "text.alignleft"
        case .date:     return "calendar"
        }
    }

    // MARK: - Mailbox picker

    /// Principal toolbar item — tap to pick a different mailbox on this
    /// account. The selected mailbox name + a chevron sits in the nav-bar
    /// title slot, replacing the static nav-title text. Falls back to a
    /// plain non-tappable Text label until the session's mailbox list comes
    /// back from `XLIST` so we don't render a Menu with empty contents.
    @ViewBuilder
    private var mailboxPicker: some View {
        let mailboxes = sortedMailboxes
        if mailboxes.count > 1 {
            Menu {
                ForEach(mailboxes) { mailbox in
                    Button {
                        Task { await session.selectMailbox(mailbox.name) }
                    } label: {
                        mailboxRowLabel(mailbox)
                    }
                }
            } label: {
                mailboxLabel
            }
        } else {
            mailboxLabel
        }
    }

    /// Title-row label used inside (or in place of) the mailbox picker
    /// Menu. Shows the mailbox name + chevron, and during an active sync
    /// also surfaces a small "N / M" caption underneath so the user sees
    /// long syncs progressing without sacrificing a separate banner row.
    @ViewBuilder
    private var mailboxLabel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(session.currentMailboxDisplayName)
                    .font(.headline)
                if sortedMailboxes.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }
            if let progress = syncCompactText {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(progress)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .foregroundStyle(.primary)
    }

    /// Compact "200 / 5,000" caption for the title-row sync indicator.
    private var syncCompactText: String? {
        guard session.isRefreshing, session.fetchTotal > 0 else { return nil }
        return "\(session.fetchProgress) / \(session.fetchTotal)"
    }

    /// Row label for one mailbox in the picker menu. The currently-selected
    /// mailbox gets a checkmark icon (no count — the title bar already says
    /// where we are). Others show their system icon plus a trailing unread
    /// count when we know one, formatted as a `·`-separated suffix because
    /// SwiftUI Menus don't reliably style trailing badges inside Button
    /// content the way an inline iOS Mail-style pill would.
    @ViewBuilder
    private func mailboxRowLabel(_ mailbox: Mailbox) -> some View {
        if mailbox.name == session.currentMailbox {
            Label(mailbox.displayName, systemImage: "checkmark")
        } else {
            let unread = unreadCount(in: mailbox)
            if unread > 0 {
                Label("\(mailbox.displayName)  ·  \(unread) unread", systemImage: mailbox.systemIcon)
            } else {
                Label(mailbox.displayName, systemImage: mailbox.systemIcon)
            }
        }
    }

    /// Unread count for a mailbox the user might be considering switching to.
    /// Prefers the server-reported `STATUS (UNSEEN)` count populated by
    /// `AccountSession.refreshMailboxStatuses()` after each connect — that
    /// path covers folders the user has never opened, which the SwiftData
    /// cache (the historical source) silently reported as 0. Falls back to
    /// the cache count when the STATUS sweep hasn't finished yet (or the
    /// server refused to STATUS that folder), so first-paint badges land
    /// from the cache and then refine as the sweep completes.
    private func unreadCount(in mailbox: Mailbox) -> Int {
        if let unseen = mailbox.unseenCount { return unseen }
        return session.headers(in: mailbox.name).lazy.filter { !$0.isRead }.count
    }

    /// System folders (Inbox, Sent, Drafts, Archive, Trash, Junk) first in
    /// their natural order, then custom folders alphabetically. Matches what
    /// iOS Mail's sidebar does so users don't have to re-learn the ordering.
    /// Drops `\Noselect` containers (Gmail's bare `[Gmail]` row, mostly) —
    /// the macOS sidebar keeps them as a parent for its disclosure triangle,
    /// but the iOS picker is a flat menu so a non-tappable row is just noise.
    private var sortedMailboxes: [Mailbox] {
        session.mailboxes.filter(\.isSelectable).sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

/// Inline progress strip pinned above the list. Visible whenever the session
/// is fetching headers — `connectionState == .fetching` or `isRefreshing` —
/// and hides itself completely when there's nothing to report. Bridges the
/// gap between picking a folder and seeing the first row land: the user
/// always has either a determinate bar (UID-flags fetch returned) or an
/// indeterminate spinner (still waiting on the server's response) confirming
/// the app is working.
private struct FetchProgressBanner: View {
    @Bindable var session: AccountSession

    private var isActive: Bool {
        if case .fetching = session.connectionState { return true }
        return session.isRefreshing
    }

    var body: some View {
        if isActive {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    if session.fetchTotal > 0 {
                        Text("Syncing headers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(session.fetchProgress.formatted()) / \(session.fetchTotal.formatted())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Contacting server…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                if session.fetchTotal > 0 {
                    ProgressView(value: Double(session.fetchProgress),
                                 total: Double(session.fetchTotal))
                        .progressViewStyle(.linear)
                } else {
                    // Slim indeterminate strip; keeps the banner's height
                    // stable across the "waiting" → "fetching" transition so
                    // the list below doesn't jump.
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Slim banner pinned above the message list whenever
/// `SettingsStore.dryRunMode` is on. Mirrors the macOS `DryRunBanner` in
/// `ContentView` so the user has the same visible cue on every platform that
/// bulk actions won't reach the server. The setting itself syncs via iCloud
/// KV, so the banner is the safety net for an iOS user who flipped it on the
/// Mac and forgot.
private struct DryRunBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
            Text("Dry Run Mode: actions update this view but are not committed to the mail server.")
                .font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.22))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Single row in the message list. Two-line layout — sender + date stamp on
/// the top line, subject on the bottom — matches the iOS Mail.app density.
private struct MessageRow: View {
    let header: MessageHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(header.senderName.isEmpty ? header.senderAddress : header.senderName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(header.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(header.subject.isEmpty ? "(no subject)" : header.subject)
                .font(.subheadline)
                .foregroundStyle(header.isRead ? .secondary : .primary)
                .lineLimit(2)
            if !header.isRead || header.isLikelyTransactional {
                HStack(spacing: 6) {
                    if !header.isRead {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.tint)
                    }
                    if header.isLikelyTransactional {
                        Label("Transactional", systemImage: "receipt")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
