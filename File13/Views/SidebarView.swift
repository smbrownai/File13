import File13Core
import SwiftUI

struct SidebarView: View {
    @Bindable var inbox: InboxStore
    /// Invoked when the user picks "Edit Account…" / "Re-enter Password…"
    /// from a per-account context menu. ContentView owns the sheet
    /// state so the sheet survives sidebar re-renders.
    var onEditAccount: (Account) -> Void = { _ in }
    @Environment(\.accentPalette) private var palette
    @State private var showCreateSheet = false
    @State private var subfolderParent: Mailbox?
    @State private var renameTarget: Mailbox?
    @State private var deleteTarget: Mailbox?
    @State private var emptyTarget: Mailbox?
    @State private var folderActionError: String?

    var body: some View {
        List(selection: sidebarSelection) {
            Section("Inboxes") {
                ScopeRow(
                    label: "Unified Inbox",
                    icon: "tray.2",
                    scope: .unified,
                    current: inbox.scope,
                    accent: palette.color(at: 0)
                )
                .tag(SidebarItem.scope(.unified))
                ForEach(Array(inbox.sessions.enumerated()), id: \.element.id) { index, session in
                    accountRow(session: session, index: index)
                }
            }

            if let session = inbox.activeSession {
                let systems = session.mailboxes.filter(\.isSystem)
                let custom = session.mailboxes.filter { !$0.isSystem }
                if !systems.isEmpty {
                    Section("Mailboxes") {
                        ForEach(Array(systems.enumerated()), id: \.element.id) { index, mailbox in
                            systemRow(mailbox: mailbox, index: index, session: session)
                        }
                    }
                }
                if !custom.isEmpty {
                    Section("Folders") {
                        ForEach(Array(custom.enumerated()), id: \.element.id) { index, mailbox in
                            MailboxRow(
                                mailbox: mailbox,
                                isCurrent: mailbox.name == session.currentMailbox,
                                accent: palette.color(at: index),
                                session: session,
                                indentLevel: depth(of: mailbox)
                            )
                            .tag(SidebarItem.mailbox(mailbox.name))
                            .contextMenu {
                                Button("New Subfolder…") { subfolderParent = mailbox }
                                Divider()
                                Button("Rename…") { renameTarget = mailbox }
                                Button("Delete…", role: .destructive) { deleteTarget = mailbox }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await inbox.refresh() }
                } label: {
                    if inbox.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(inbox.connectedAccount == nil || inbox.isRefreshing)
                .help("Refresh the current mailbox")
            }
            ToolbarItem {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(inbox.activeSession == nil)
                .help(inbox.activeSession == nil
                      ? "Pick an account in the sidebar first — folders live on a single account."
                      : "Create a new folder on this account")
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateFolderSheet(inbox: inbox)
        }
        .sheet(item: $subfolderParent) { parent in
            CreateFolderSheet(
                inbox: inbox,
                parentPath: parent.name,
                parentDelimiter: parent.hierarchyDelimiter
            )
        }
        .sheet(item: $renameTarget) { mailbox in
            RenameFolderSheet(inbox: inbox, mailbox: mailbox)
        }
        .confirmationDialog(
            "Delete \"\(deleteTarget?.displayName ?? "")\"?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { mailbox in
            Button("Delete", role: .destructive) {
                Task { await deleteFolder(mailbox) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { mailbox in
            Text("This deletes the folder on the mail server. Most servers refuse to delete folders that still contain messages — move them somewhere else first.")
        }
        .confirmationDialog(
            "Empty \"\(emptyTarget?.displayName ?? "")\"?",
            isPresented: Binding(get: { emptyTarget != nil }, set: { if !$0 { emptyTarget = nil } }),
            presenting: emptyTarget
        ) { mailbox in
            Button("Empty \(mailbox.displayName)", role: .destructive) {
                Task { await empty(mailbox) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { mailbox in
            let n = mailbox.messageCount ?? 0
            Text("This permanently deletes \(n.formatted()) message\(n == 1 ? "" : "s") from \(mailbox.displayName) on the mail server. This cannot be undone.")
        }
        .alert("Couldn't update folder", isPresented: Binding(
            get: { folderActionError != nil },
            set: { if !$0 { folderActionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderActionError ?? "")
        }
    }

    /// Builds one row in the system-mailboxes section. Extracted so the
    /// outer body stays small enough for the type-checker — the inline
    /// `.tag` + `.contextMenu` chain on a `ForEach` over `enumerated()`
    /// blew past the timeout once the menu had any branching in it.
    @ViewBuilder
    private func systemRow(mailbox: Mailbox, index: Int, session: AccountSession) -> some View {
        // Empty is only meaningful for Trash and Junk — every other system
        // folder (Inbox, Sent, Drafts, Archive, All Mail) is live mail the
        // user shouldn't be able to wipe with one click.
        let canEmpty = mailbox.kind == .trash || mailbox.kind == .junk
        let hasMessages = (mailbox.messageCount ?? 0) > 0
        MailboxRow(
            mailbox: mailbox,
            isCurrent: mailbox.name == session.currentMailbox,
            accent: palette.color(at: index),
            session: session
        )
        .tag(SidebarItem.mailbox(mailbox.name))
        .contextMenu {
            if canEmpty {
                Button("Empty \(mailbox.displayName)…", role: .destructive) {
                    emptyTarget = mailbox
                }
                .disabled(!hasMessages)
            }
        }
    }

    private func deleteFolder(_ mailbox: Mailbox) async {
        do {
            try await inbox.deleteMailbox(named: mailbox.name)
        } catch {
            folderActionError = error.localizedDescription
        }
    }

    private func empty(_ mailbox: Mailbox) async {
        _ = await inbox.emptyMailbox(named: mailbox.name)
    }

    /// Visual nesting depth based on the server-reported hierarchy delimiter.
    /// Falls back to "/" — the same default the create sheet has always
    /// suggested — when the delimiter is unknown. Capped so a pathologically
    /// deep folder can't push the row off-screen.
    /// Per-account sidebar row with the routine "edit" / repair context
    /// menu. Extracted from the main body to keep SwiftUI's type-checker
    /// out of the "expression too complex" bailout — once you add a
    /// fifth nested modifier to an inline closure inside `Section { ForEach { … } }`
    /// the inference path explodes.
    @ViewBuilder
    private func accountRow(session: AccountSession, index: Int) -> some View {
        ScopeRow(
            label: session.account.displayName.isEmpty ? session.account.address : session.account.displayName,
            icon: "envelope.circle",
            scope: .account(session.id),
            current: inbox.scope,
            subtitle: session.account.address,
            session: session,
            accent: palette.color(at: index + 1)
        )
        .tag(SidebarItem.scope(.account(session.id)))
        .contextMenu {
            // Label relabels to "Re-enter Password…" when the session
            // is in a broken state, matching the user's mental model
            // in the most common repair scenario (Gmail / Outlook /
            // Yahoo app-passwords get revoked or rotated and the
            // account turns red in the sidebar). Either label routes
            // to the same EditAccountSheet.
            Button(editLabel(for: session)) {
                onEditAccount(session.account)
            }
        }
    }

    /// Label for the per-account context-menu's edit item. "Re-enter
    /// Password…" when the session is broken (the most common repair
    /// scenario — Gmail / Outlook / Yahoo app-passwords get revoked
    /// periodically and the user needs an obvious affordance to fix
    /// the account without deleting and re-adding it, which would
    /// discard local triage state). Otherwise "Edit Account…" for
    /// routine display-name / host / port changes.
    private func editLabel(for session: AccountSession) -> String {
        switch session.connectionState {
        case .failed, .offlineWithCache: "Re-enter Password…"
        default:                         "Edit Account…"
        }
    }

    private func depth(of mailbox: Mailbox) -> Int {
        // Force-unwrap is guarded by the `.isEmpty == false` check on the
        // same line — when the optional is non-empty it's by definition
        // non-nil. Don't refactor to read `mailbox.hierarchyDelimiter`
        // independently between the guard and the unwrap.
        let delim = (mailbox.hierarchyDelimiter?.isEmpty == false) ? mailbox.hierarchyDelimiter! : "/"
        let segments = mailbox.name.split(separator: Character(delim), omittingEmptySubsequences: true).count
        return min(max(0, segments - 1), 4)
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: {
                if case .account = inbox.scope, let session = inbox.activeSession {
                    return .mailbox(session.currentMailbox)
                }
                return .scope(inbox.scope)
            },
            set: { newValue in
                guard let item = newValue else { return }
                switch item {
                case .scope(let s):
                    inbox.scope = s
                case .mailbox(let name):
                    // Refuse to SELECT a `\Noselect` container. Gmail's bare
                    // `[Gmail]` row is the canonical example — IMAP SELECT
                    // on it returns NONEXISTENT and we'd surface that as a
                    // "Couldn't connect" pane. The row stays clickable as a
                    // visual entity so the disclosure triangle works, but
                    // tapping it is a no-op rather than a server error.
                    if let mb = inbox.activeSession?.mailboxes.first(where: { $0.name == name }),
                       !mb.isSelectable {
                        return
                    }
                    Task { await inbox.selectMailbox(name) }
                }
            }
        )
    }
}

private enum SidebarItem: Hashable {
    case scope(InboxScope)
    case mailbox(String)
}

private struct ScopeRow: View {
    let label: String
    let icon: String
    let scope: InboxScope
    let current: InboxScope
    var subtitle: String? = nil
    var session: AccountSession? = nil
    let accent: Color

    private var isActive: Bool { scope == current }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).lineLimit(1)
                if let subtitle, subtitle != label {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if let session {
                SessionStateGlyph(session: session)
            }
        }
        .fontWeight(isActive ? .semibold : .regular)
    }
}

private struct SessionStateGlyph: View {
    @Bindable var session: AccountSession

    var body: some View {
        switch session.connectionState {
        case .connected:
            if session.isRefreshing {
                progressIndicator
            } else {
                EmptyView()
            }
        case .connecting:
            ProgressView().controlSize(.mini)
        case .fetching:
            progressIndicator
        case .failed(let message):
            // Surface the underlying error as a hover tooltip and as the
            // accessibility label so a non-sighted user gets the same
            // diagnostic a mouse user does. Without this, the orange
            // triangle was a "something's wrong, good luck" signal.
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
                .help(message.isEmpty ? "Account connection failed" : message)
                .accessibilityLabel(message.isEmpty
                    ? "Connection failed"
                    : "Connection failed: \(message)")
        case .offlineWithCache(let message):
            // Distinct from `.failed`: cached headers are visible (the
            // inbox isn't empty) but the connection isn't live, so
            // destructive bulk actions will fail at commit time. Gray
            // wifi-slash conveys "your data is here, but stale," and the
            // tooltip names the underlying reach error.
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
                .font(.caption)
                .help(message.isEmpty
                    ? "Offline — showing cached headers"
                    : "Offline — showing cached headers. \(message)")
                .accessibilityLabel(message.isEmpty
                    ? "Offline, showing cached headers"
                    : "Offline, showing cached headers. \(message)")
        case .disconnected:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if session.fetchTotal > 0 {
            HStack(spacing: 4) {
                Text("\(percent)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                ProgressView(value: Double(session.fetchProgress),
                             total: Double(session.fetchTotal))
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    private var percent: Int {
        guard session.fetchTotal > 0 else { return 0 }
        return Int((Double(session.fetchProgress) / Double(session.fetchTotal)) * 100)
    }
}

private struct MailboxRow: View {
    let mailbox: Mailbox
    let isCurrent: Bool
    let accent: Color
    @Bindable var session: AccountSession
    /// 0 for top-level folders, 1 for `Parent/Child`, etc. Drives a small
    /// leading inset so nested folders read as nested rather than as siblings.
    /// `MailboxRow` doesn't know about the delimiter directly — its parent
    /// computes the depth from `mailbox.hierarchyDelimiter`.
    var indentLevel: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            if indentLevel > 0 {
                Spacer().frame(width: CGFloat(indentLevel) * 12)
            }
            Image(systemName: mailbox.systemIcon)
                .foregroundStyle(accent)
                .frame(width: 18)
            Text(mailbox.displayName)
                .lineLimit(1)
            // Distinct yellow warning glyph on the *currently-viewed*
            // mailbox when the last fetch ended mid-stream. The chip
            // already truncates to whatever we collected; without this
            // signal the user has no idea their inbox view isn't
            // complete and might delete / archive / run rules against
            // what they think is the full list.
            if isCurrent && session.lastFetchWasIncomplete {
                Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                    .help("Last fetch ended early — count shown is partial. Refresh to load the rest.")
                    .accessibilityLabel("Last fetch was incomplete; mailbox count is partial. Refresh to load the rest.")
            }
            Spacer()
            if isCurrent && isMailboxFetching {
                // Replace the message-count chip with a fetch arc while this
                // specific mailbox is being pulled. Only the current mailbox
                // can be fetching at a time per session, so the (isCurrent &&
                // fetching) guard fully scopes the indicator to this row.
                MailboxProgressArc(session: session)
            } else if let count = mailbox.messageCount {
                Text(count.formatted())
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    /// True when the session is actively pulling headers — either the initial
    /// post-connect fetch (`.fetching`) or an incremental refresh kicked off
    /// from the toolbar (`.connected` + `isRefreshing`).
    private var isMailboxFetching: Bool {
        switch session.connectionState {
        case .fetching: return true
        case .connected: return session.isRefreshing
        case .connecting, .failed, .disconnected, .offlineWithCache: return false
        }
    }
}

/// Compact circular progress arc shown in the sidebar next to whichever
/// mailbox row is currently being fetched. Mirrors the per-account arc on
/// `ScopeRow` so users get the same visual whether they're watching the
/// account or the specific folder.
private struct MailboxProgressArc: View {
    @Bindable var session: AccountSession

    var body: some View {
        if session.fetchTotal > 0 {
            HStack(spacing: 4) {
                Text("\(percent)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                ProgressView(value: Double(session.fetchProgress),
                             total: Double(session.fetchTotal))
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    private var percent: Int {
        guard session.fetchTotal > 0 else { return 0 }
        return Int((Double(session.fetchProgress) / Double(session.fetchTotal)) * 100)
    }
}
