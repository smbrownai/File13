import File13Core
import SwiftUI

/// Drill-in from `iOSSenderListView` — every message from one sender, newest
/// first, plus an on-demand AI advice card. The advice runs through the same
/// `SenderAdvisor` the Mac app uses, configured from `SettingsStore`'s
/// per-feature tuning. Headers only ever go to the configured provider; bodies
/// are never fetched and never sent. That's the whole privacy story.
///
/// Actions on the advice (`Archive all`, `Delete all`) route through the
/// shared `InboxStore.applyAction(_:toSender:)`, which arms the buffered
/// pending-action with its undo banner — same code path that's been working
/// since PR #6.
struct iOSSenderDetailView: View {
    let sender: Sender
    @Bindable var inbox: InboxStore
    @Bindable var settings: SettingsStore
    @Bindable var categoryStore: SenderCategoryStore

    @State private var adviceState: AdviceState = .idle
    @State private var unsubscribeState: UnsubscribeState = .idle
    /// Set when the user taps the advice card's "Delete all" button and
    /// `settings.confirmBeforeDelete` is on. The presented confirmation
    /// dialog reads this to decide whether to render, and fires
    /// `applyAction(.delete, …)` on accept.
    @State private var showAdviceDeleteConfirm = false
    /// EditMode for the Messages list — drives the toolbar's Select/Done
    /// button and the bottom-bar bulk-action pill. Same single-select-set
    /// pattern as `iOSMessageListView` so the user can cherry-pick a subset
    /// of this sender's messages for Delete / Move / Archive.
    @State private var editMode: EditMode = .inactive
    @State private var showBulkDeleteConfirm = false
    @State private var showBulkMoveSheet = false
    @State private var showArchiveError = false
    /// Same shape for unsubscribe: when the user taps the unsubscribe button
    /// and `settings.confirmBeforeUnsubscribe` is on, we stash the chosen
    /// mechanism here and ask before executing it. `nil` ⇒ no pending
    /// unsubscribe. We hold the mechanism (not just a bool) because the
    /// follow-up action depends on whether it's a one-click POST or a
    /// browser/mailto handoff.
    @State private var pendingUnsubscribe: UnsubscribeMechanism?
    @Environment(\.openURL) private var openURL

    private enum AdviceState {
        case idle
        case loading
        case ready(SenderAdvice)
        case failed(String)
    }

    /// Lifecycle of a one-click RFC 8058 unsubscribe POST on this sender's
    /// best-available HTTPS link. `.web` / `.mailto` mechanisms route through
    /// SwiftUI's `openURL` and don't touch this state machine.
    private enum UnsubscribeState: Equatable {
        case idle
        case posting
        case succeeded(statusCode: Int)
        case failed(message: String, fallback: URL?)
    }

    var body: some View {
        List(selection: $inbox.selectedMessageIds) {
            Section { } header: { summaryHeader.textCase(nil) }
            adviceSection
            standaloneUnsubscribeSection
            Section("Messages") {
                ForEach(sender.messages) { header in
                    SenderMessageRow(header: header)
                        .tag(header.id)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(sender.name.isEmpty ? sender.address : sender.name)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar { bulkToolbarContent }
        // Bulk-action pill rides above the tab bar via a bottom safe-area
        // inset rather than `.toolbar(... .bottomBar)`. The message list
        // uses `.toolbar(.hidden, for: .tabBar)` to clear room for its
        // bottom bar, but that modifier doesn't propagate from a 2nd-level
        // pushed view — the system tab bar stays put and covers the
        // `.bottomBar` items. Rendering as a safe-area inset sidesteps the
        // whole conflict: the bar appears above the tab bar with no
        // overlap and no need to hide anything.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode == .active && !inbox.selectedMessageIds.isEmpty {
                bulkActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: editMode)
        .animation(.snappy, value: inbox.selectedMessageIds.isEmpty)
        .onDisappear {
            // Don't carry this view's selection back into the message list.
            inbox.clearSelection()
            editMode = .inactive
        }
        .onChange(of: editMode) { _, newValue in
            // Tapping Done clears any in-progress selection so the next
            // entry into Select mode starts empty.
            if newValue == .inactive { inbox.clearSelection() }
        }
        .confirmationDialog(
            "Delete \(inbox.selectedMessageIds.count) message\(inbox.selectedMessageIds.count == 1 ? "" : "s")?",
            isPresented: $showBulkDeleteConfirm,
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
        .alert("No archive folder", isPresented: $showArchiveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This account didn't report an archive mailbox. Try Delete, or pick a destination on the Mac app for now.")
        }
        .sheet(isPresented: $showBulkMoveSheet) {
            if let session = bulkActionSession {
                iOSMoveToFolderSheet(inbox: inbox, session: session)
            }
        }
        .confirmationDialog(
            "Delete \(sender.messageCount) message\(sender.messageCount == 1 ? "" : "s") from \(sender.name.isEmpty ? sender.address : sender.name)?",
            isPresented: $showAdviceDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                inbox.applyAction(.delete, toSender: sender)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(settings.dryRunMode
                 ? "Dry-run mode is on — local list will update but the server won't be touched."
                 : "You'll have \(settings.undoBufferSeconds) seconds to undo before it commits to the server.")
        }
        .confirmationDialog(
            unsubscribeConfirmTitle,
            isPresented: Binding(
                get: { pendingUnsubscribe != nil },
                set: { if !$0 { pendingUnsubscribe = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(unsubscribeConfirmActionLabel, role: .destructive) {
                if let mechanism = pendingUnsubscribe {
                    handleUnsubscribe(mechanism)
                }
                pendingUnsubscribe = nil
            }
            Button("Cancel", role: .cancel) { pendingUnsubscribe = nil }
        } message: {
            Text(unsubscribeConfirmMessage)
        }
    }

    // MARK: - Bulk actions

    /// Account session whose mailbox list backs the Move sheet. Senders are
    /// rendered inside a per-account scope (`InboxStore.scope == .account`),
    /// so every message in `sender.messages` belongs to the same account —
    /// pick the first message's `accountId` and find its session.
    private var bulkActionSession: AccountSession? {
        guard let accountId = sender.messages.first?.accountId else { return nil }
        return inbox.sessions.first(where: { $0.id == accountId })
    }

    /// Whether the session has any mailboxes the user could move into.
    /// Disables the Move button on accounts that only advertised the current
    /// folder so the user doesn't tap into an empty sheet.
    private var hasMoveDestinations: Bool {
        guard let session = bulkActionSession else { return false }
        return session.mailboxes.contains { $0.name != session.currentMailbox }
    }

    @ToolbarContentBuilder
    private var bulkToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            // Hand-rolled instead of `EditButton()` for the same reasons the
            // message list does it: "Select" reads better than "Edit" in a
            // read-only triage view, and we want to gate it on having at
            // least one message to select.
            Button {
                withAnimation {
                    editMode = (editMode == .active) ? .inactive : .active
                }
            } label: {
                Text(editMode == .active ? "Done" : "Select")
                    .fontWeight(editMode == .active ? .semibold : .regular)
            }
            .disabled(sender.messages.isEmpty)
        }
    }

    /// Bulk-action bar rendered into the bottom safe-area inset above the
    /// system tab bar. Three buttons in a single row — Delete on the left
    /// (destructive tint), Move in the middle (open-ended destination),
    /// Archive on the right. Disables Move when the account didn't advertise
    /// any other folders. The bar matches the in-app material chrome so it
    /// reads as a toolbar, not a floating sheet.
    private var bulkActionBar: some View {
        HStack(spacing: 24) {
            Button(role: .destructive) {
                if settings.confirmBeforeDelete {
                    showBulkDeleteConfirm = true
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
                showBulkMoveSheet = true
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

    /// Title for the unsubscribe confirmation dialog. Mirrors the
    /// button's own label so the user never has to re-read the row
    /// to know what they're agreeing to.
    private var unsubscribeConfirmTitle: String {
        let who = sender.name.isEmpty ? sender.address : sender.name
        return "Unsubscribe from \(who)?"
    }

    /// Action verb on the confirm button. Matches the mechanism — a
    /// one-click POST fires immediately, while web/mailto hand off to an
    /// external app, and the wording reflects which is which.
    private var unsubscribeConfirmActionLabel: String {
        switch pendingUnsubscribe {
        case .oneClick:                       return "Unsubscribe"
        case .web:                            return "Open Link"
        case .mailto:                         return "Compose Email"
        case nil:                             return "Unsubscribe"
        }
    }

    private var unsubscribeConfirmMessage: String {
        switch pendingUnsubscribe {
        case .oneClick:
            return "File13 will send a one-click unsubscribe request to the sender. This usually can't be undone."
        case .web(let url):
            return "File13 will open \(url.host ?? url.absoluteString) so you can finish unsubscribing in your browser."
        case .mailto(_, let address):
            return "File13 will open your mail client to send an unsubscribe message to \(address)."
        case nil:
            return ""
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(sender.messageCount) message\(sender.messageCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if sender.unreadCount > 0 {
                    Text("· \(sender.unreadCount) unread")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
                Spacer()
                if let category = categoryStore.category(for: sender.id) {
                    CategoryBadge(category: category)
                }
            }
            if !sender.name.isEmpty {
                Text(sender.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Advice section

    @ViewBuilder
    private var adviceSection: some View {
        Section {
            switch adviceState {
            case .idle:
                Button {
                    runAdvice()
                } label: {
                    Label("Get AI advice", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Asking \(settings.aiProvider.label)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .ready(let advice):
                adviceCard(advice)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                    Button("Try again") { runAdvice() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Triage advice")
        } footer: {
            footerText
        }
    }

    private var footerText: some View {
        switch adviceState {
        case .ready(let advice) where advice.suitableForRule:
            Text("This recommendation also fits as an ongoing rule. Create the rule in the Mac app to apply it to future mail from this sender.")
        default:
            Text("File13 sends headers only — never message bodies — to your configured AI provider when this runs.")
        }
    }

    // MARK: - Standalone unsubscribe

    /// Whether to render the "Unsubscribe" section as a peer of the AI
    /// advice card. Hidden when the AI card is already exposing the same
    /// button (advice == .unsubscribe and a mechanism exists), so the user
    /// sees one Unsubscribe button at a time.
    private var showsStandaloneUnsubscribe: Bool {
        guard bestUnsubscribeMechanism != nil else { return false }
        if case .ready(let advice) = adviceState, advice.action == .unsubscribe {
            return false
        }
        return true
    }

    /// Standalone unsubscribe affordance for any sender whose messages
    /// expose a one-click or web `List-Unsubscribe` mechanism. Mirrors
    /// the Mac envelope.badge button on the inspector — gives the user a
    /// way to act without waiting on AI. Reuses `unsubscribeButton` so the
    /// same `unsubscribeState` machine drives both surfaces; if the user
    /// taps from this section, the inflight / success / failure UI shows
    /// here, and the AI card (when present) reflects the same state.
    @ViewBuilder
    private var standaloneUnsubscribeSection: some View {
        if showsStandaloneUnsubscribe {
            Section {
                unsubscribeButton
            } header: {
                Text("Unsubscribe")
            } footer: {
                Text("File13 uses the sender's List-Unsubscribe header. One-click links unsubscribe in place; web links open in your browser. The sender may identify you from the URL.")
            }
        }
    }

    private func adviceCard(_ advice: SenderAdvice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: advice.action.symbol)
                    .foregroundStyle(advice.action.color)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(advice.action.label)
                        .font(.headline)
                        .foregroundStyle(advice.action.color)
                    Text(advice.summary)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(advice.rationale)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            adviceActionButtons(advice)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func adviceActionButtons(_ advice: SenderAdvice) -> some View {
        switch advice.action {
        case .keep:
            EmptyView()
        case .archive:
            Button {
                inbox.applyAction(.archive, toSender: sender)
            } label: {
                Label("Archive all \(sender.messageCount)", systemImage: "archivebox")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(.blue)
        case .delete:
            Button(role: .destructive) {
                if settings.confirmBeforeDelete {
                    showAdviceDeleteConfirm = true
                } else {
                    inbox.applyAction(.delete, toSender: sender)
                }
            } label: {
                Label("Delete all \(sender.messageCount)", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        case .unsubscribe:
            unsubscribeButton
        }
    }

    /// Action UI for an unsubscribe recommendation. The button shape depends
    /// on the best-available mechanism extracted from the sender's messages:
    /// - `.oneClick`: a single tap fires an RFC 8058 HTTPS POST via the
    ///   in-app `UnsubscribeService`; success shows a confirmation, failure
    ///   surfaces the message + offers an "Open in browser" fallback (any
    ///   web URL we found alongside the one-click endpoint).
    /// - `.web`: tap opens the URL via SwiftUI's `openURL` environment.
    /// - `.mailto`: same — hand off to the user's mail client.
    /// - `nil`: inline hint that there's nothing actionable on iOS for this
    ///   sender (no List-Unsubscribe header at all).
    @ViewBuilder
    private var unsubscribeButton: some View {
        switch unsubscribeState {
        case .idle:
            if let mechanism = bestUnsubscribeMechanism {
                Button {
                    if settings.confirmBeforeUnsubscribe {
                        pendingUnsubscribe = mechanism
                    } else {
                        handleUnsubscribe(mechanism)
                    }
                } label: {
                    Label(unsubscribeButtonLabel(for: mechanism), systemImage: "envelope.badge.shield.half.filled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(.orange)
            } else {
                Label("No one-click or web unsubscribe link on this sender's messages.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .posting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Unsubscribing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        case .succeeded(let statusCode):
            Label("Unsubscribed (server returned \(statusCode))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message, let fallback):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                HStack(spacing: 10) {
                    if let fallback {
                        Button {
                            openURL(fallback)
                        } label: {
                            Label("Open in browser", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button("Try again") {
                        unsubscribeState = .idle
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func unsubscribeButtonLabel(for mechanism: UnsubscribeMechanism) -> String {
        switch mechanism {
        case .oneClick:                return "Unsubscribe in one click"
        case .web:                     return "Open unsubscribe link"
        case .mailto(_, let address):  return "Email \(address)"
        }
    }

    private func handleUnsubscribe(_ mechanism: UnsubscribeMechanism) {
        switch mechanism {
        case .oneClick(let url):
            unsubscribeState = .posting
            let fallback = firstWebFallbackURL
            Task { @MainActor in
                let outcome = await UnsubscribeService().postOneClick(to: url)
                switch outcome {
                case .oneClickSucceeded(let code):
                    unsubscribeState = .succeeded(statusCode: code)
                case .oneClickServerError(let code, let body):
                    let detail = body?.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines)
                    let msg = "Server returned \(code)\(detail.map { ": \($0)" } ?? "")."
                    unsubscribeState = .failed(message: msg, fallback: fallback)
                case .oneClickFailed(let m):
                    unsubscribeState = .failed(message: m, fallback: fallback)
                case .openedExternally, .externalOpenFailed:
                    // postOneClick never returns these; included for exhaustiveness.
                    unsubscribeState = .idle
                }
            }
        case .web(let url), .mailto(let url, _):
            openURL(url)
        }
    }

    /// Best mechanism available across all this sender's messages. Earlier
    /// entries from `UnsubscribeParser.parse` win because the parser sorts
    /// one-click first, then web, then mailto. iOS deliberately drops the
    /// `.mailto` path — composing a `mailto:` link forces a hand-off to
    /// Apple Mail (no other client claims the scheme cleanly on iOS), which
    /// is jarring when every other File13 action stays in-app. We just
    /// pretend mailto-only senders have no unsubscribe affordance.
    /// Returns nil when no message has a usable (one-click or web) link.
    private var bestUnsubscribeMechanism: UnsubscribeMechanism? {
        for header in sender.messages {
            guard let raw = header.listUnsubscribe else { continue }
            let mechanisms = UnsubscribeParser.parse(
                listUnsubscribe: raw,
                listUnsubscribePost: header.listUnsubscribePost
            )
            if let first = mechanisms.first(where: { mechanism in
                switch mechanism {
                case .oneClick, .web: return true
                case .mailto:         return false
                }
            }) {
                return first
            }
        }
        return nil
    }

    /// HTTPS web URL we can hand to Safari if the one-click POST fails — the
    /// user often has somewhere to click through on the same domain. Falls
    /// through to nil when only one-click or mailto links are advertised.
    private var firstWebFallbackURL: URL? {
        for header in sender.messages {
            guard let raw = header.listUnsubscribe else { continue }
            for mechanism in UnsubscribeParser.parse(listUnsubscribe: raw, listUnsubscribePost: header.listUnsubscribePost) {
                if case .web(let url) = mechanism { return url }
                if case .oneClick(let url) = mechanism { return url }
            }
        }
        return nil
    }

    // MARK: - Run advice

    private func runAdvice() {
        adviceState = .loading
        let provider = LLMProviderFactory.make(for: .senderAdvice, settings: settings)
        let tuning = settings.tuning(for: .senderAdvice)
        let profile = sender.makeProfile()
        let senderId = sender.id
        Task { @MainActor in
            switch await provider.availability() {
            case .ready: break
            case .needsSetup(let m), .unsupported(let m), .error(let m):
                adviceState = .failed(m)
                return
            }
            do {
                let advisor = SenderAdvisor(provider: provider, tuning: tuning)
                var advice = try await advisor.analyze(profile)
                // The advisor doesn't fill in the senderId itself — patch it
                // here so any downstream consumer (and our Identifiable
                // conformance via `id == senderId`) is consistent.
                advice = SenderAdvice(
                    senderId: senderId,
                    action: advice.action,
                    summary: advice.summary,
                    rationale: advice.rationale,
                    suitableForRule: advice.suitableForRule
                )
                adviceState = .ready(advice)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                adviceState = .failed(message)
            }
        }
    }
}

/// Compact row for the per-sender detail view. Same shape as the
/// chronological `MessageRow` but trims the sender name (the navigation title
/// already says who this is).
private struct SenderMessageRow: View {
    let header: MessageHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(header.subject.isEmpty ? "(no subject)" : header.subject)
                    .font(.subheadline)
                    .foregroundStyle(header.isRead ? .secondary : .primary)
                    .lineLimit(2)
                Spacer()
                Text(header.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
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
