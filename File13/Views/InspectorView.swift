import File13Core
import SwiftUI

/// Right-hand inspector for the inbox. When a sender is selected (via row tap in
/// `SenderListView`), shows a per-sender header, action buttons, and the sender's full
/// message list with checkboxes that drive the same `selectedMessageIds` set used by the
/// bottom `BulkActionBar`. AI insights live here too once `Analyze with AI` is run.
struct InspectorView: View {
    /// Namespaces sender vs. cluster identity for `.id(...)`. Both inner
    /// ids are `String`-typed, so a raw `.id(sender.id)` / `.id(cluster.id)`
    /// pair would collide if a sender and cluster ever shared a value —
    /// SwiftUI would reuse view storage across the type boundary and
    /// retain stale per-view state (scroll position, focus, sheet).
    /// The enum case carries the namespace at the type level so the
    /// hash + equality already disambiguate.
    private enum InspectedID: Hashable {
        case sender(String)
        case cluster(String)
    }

    @Bindable var store: InboxStore
    @Bindable var ruleStore: RuleStore
    @Bindable var settings: SettingsStore
    @Bindable var categoryStore: SenderCategoryStore
    @Bindable var suggestionDismissals: SuggestionDismissalStore
    @Bindable var vipStore: VIPStore
    var onAnalyzeSenders: ([Sender]) -> Void = { _ in }

    var body: some View {
        Group {
            if let sender = inspectedSender {
                SenderInspector(
                    store: store,
                    ruleStore: ruleStore,
                    settings: settings,
                    categoryStore: categoryStore,
                    suggestionDismissals: suggestionDismissals,
                    vipStore: vipStore,
                    sender: sender,
                    onAnalyze: { onAnalyzeSenders([sender]) }
                )
                .id(InspectedID.sender(sender.id))
            } else if let cluster = inspectedCluster {
                ClusterInspector(
                    store: store,
                    ruleStore: ruleStore,
                    cluster: cluster,
                    onAnalyzeSenders: onAnalyzeSenders
                )
                .id(InspectedID.cluster(cluster.id))
            } else {
                ContentUnavailableView(
                    "No selection",
                    systemImage: "sidebar.right",
                    description: Text("Tap a sender or subject cluster to see its messages, suggested actions, and AI insights here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var inspectedSender: Sender? {
        guard let id = store.inspectedSenderId else { return nil }
        return store.sender(byId: id)
    }

    private var inspectedCluster: SubjectCluster? {
        guard store.inspectedSenderId == nil,
              let id = store.inspectedSubjectClusterId else { return nil }
        return store.subjectCluster(byId: id)
    }
}

// MARK: - Sender inspector

private struct SenderInspector: View {
    @Bindable var store: InboxStore
    @Bindable var ruleStore: RuleStore
    @Bindable var settings: SettingsStore
    @Bindable var categoryStore: SenderCategoryStore
    @Bindable var suggestionDismissals: SuggestionDismissalStore
    @Bindable var vipStore: VIPStore
    let sender: Sender
    let onAnalyze: () -> Void

    @State private var ruleDraft: Rule?
    @State private var unsubscribeCandidates: [InboxStore.UnsubscribeCandidate]?
    @State private var unsubscribeAutoRun: Bool = false
    @State private var showSuggestionsSheet: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                actionBar
                if hasUnsubscribe {
                    unsubscribeBadge
                }
                Divider()
                messagesHeader
                MessageList(store: store, sender: sender)
            }
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $ruleDraft) { draft in
            RuleBuilderSheet(ruleStore: ruleStore, inbox: store, initial: draft)
        }
        .sheet(isPresented: Binding(
            get: { unsubscribeCandidates != nil },
            set: { if !$0 { unsubscribeCandidates = nil } }
        )) {
            UnsubscribeSheet(
                candidates: unsubscribeCandidates ?? [],
                autoRun: unsubscribeAutoRun,
                mailClientAppURL: store.preferredMailClientAppURL,
                browserAppURL: store.preferredBrowserAppURL
            )
        }
        .sheet(isPresented: $showSuggestionsSheet) {
            SuggestionsSheet(
                sender: sender,
                ruleStore: ruleStore,
                inbox: store,
                settings: settings,
                categoryStore: categoryStore,
                suggestionDismissals: suggestionDismissals,
                vipStore: vipStore
            )
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if vipStore.isVIP(senderId: sender.id) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .help("VIP — high engagement.")
                        }
                        Text(sender.name.isEmpty ? sender.address : sender.name)
                            .font(.title3).bold()
                            .lineLimit(1)
                    }
                    if !sender.name.isEmpty {
                        Text(sender.address)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                StatChip(label: "Messages", value: sender.messageCount.formatted())
                StatChip(label: "Unread", value: sender.unreadCount.formatted(), tinted: sender.unreadCount > 0)
                StatChip(
                    label: "Most recent",
                    value: sender.mostRecent.formatted(date: .abbreviated, time: .omitted)
                )
            }
        }
        .padding(.horizontal, 12)
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Primary, read-only action — doesn't conflict with the bulk verbs in the bottom
            // bar, so it stays as a prominent button.
            Button {
                onAnalyze()
            } label: {
                Label("Analyze with AI", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Per-sender shortcuts collapsed into a single secondary menu so the inspector
            // doesn't visually duplicate the bottom BulkActionBar's verbs. Each item makes the
            // scope explicit ("all from this sender") instead of relying on label parity with
            // selection-scoped buttons.
            Menu {
                Button {
                    store.applyAction(.archive, toSender: sender)
                } label: {
                    Label("Archive all", systemImage: "archivebox")
                }
                Button(role: .destructive) {
                    store.applyAction(.delete, toSender: sender)
                } label: {
                    Label("Delete all", systemImage: "trash")
                }
                Button {
                    unsubscribeAutoRun = !store.requiresUnsubscribeConfirmation
                    unsubscribeCandidates = inspectorUnsubscribeCandidates()
                } label: {
                    Label("Unsubscribe", systemImage: "envelope.badge")
                }
                .disabled(!hasUnsubscribe)
                Divider()
                Button {
                    if vipStore.isVIP(senderId: sender.id) {
                        vipStore.unpin(senderId: sender.id)
                    } else {
                        vipStore.pin(senderId: sender.id)
                    }
                } label: {
                    Label(
                        vipStore.isVIP(senderId: sender.id) ? "Remove from VIPs" : "Pin as VIP",
                        systemImage: vipStore.isVIP(senderId: sender.id) ? "star.slash" : "star"
                    )
                }
                Button {
                    ruleDraft = inspectorRuleDraft()
                } label: {
                    Label("Create rule from sender", systemImage: "wand.and.stars")
                }
                Button {
                    showSuggestionsSheet = true
                } label: {
                    Label("Suggest rules with AI…", systemImage: "sparkles")
                }
            } label: {
                Label(applyToAllLabel, systemImage: "ellipsis.circle")
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.borderedButton)
            .controlSize(.large)
            .help("One-click shortcuts that act on every message from this sender. To act on a subset, check messages below and use the bottom action bar.")
        }
        .padding(.horizontal, 12)
    }

    private var applyToAllLabel: String {
        let count = sender.messageCount.formatted()
        let plural = sender.messageCount == 1 ? "message" : "messages"
        return "Apply to all \(count) \(plural)…"
    }

    private var messagesHeader: some View {
        HStack(spacing: 8) {
            Text("Messages")
                .font(.headline)
            Spacer()
            // Tri-state checkbox surfaces "select all from this sender" right where the user
            // is already focused — the canonical path to the bottom BulkActionBar.
            TriStateCheckbox(
                isOn: store.isSenderFullySelected(sender),
                isMixed: store.isSenderPartiallySelected(sender)
            ) { newValue in
                store.setSenderSelected(sender, selected: newValue)
            }
            .frame(width: 20)
            Text(selectAllLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
    }

    private var selectAllLabel: String {
        if store.isSenderFullySelected(sender) { return "Deselect all" }
        if store.isSenderPartiallySelected(sender) { return "Select all" }
        return "Select all"
    }

    private var unsubscribeBadge: some View {
        Label(
            "Sender provides a List-Unsubscribe header — one-click unsubscribe is available.",
            systemImage: "checkmark.seal"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
    }

    private var hasUnsubscribe: Bool {
        sender.unsubscribeAnchor != nil
    }

    private func inspectorUnsubscribeCandidates() -> [InboxStore.UnsubscribeCandidate] {
        guard let anchor = sender.unsubscribeAnchor else { return [] }
        let mechanisms = UnsubscribeParser.parse(
            listUnsubscribe: anchor.listUnsubscribe,
            listUnsubscribePost: anchor.listUnsubscribePost
        )
        guard !mechanisms.isEmpty else { return [] }
        return [.init(sender: sender, anchor: anchor, mechanisms: mechanisms)]
    }

    private func inspectorRuleDraft() -> Rule {
        var conditions = Rule.Conditions()
        conditions.fromAddressOrDomain = sender.address.lowercased()
        return Rule(conditions: conditions, outcome: .delete)
    }
}

// MARK: - Stat chip

private struct StatChip: View {
    let label: String
    let value: String
    var tinted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout).monospacedDigit()
                .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .fontWeight(tinted ? .semibold : .regular)
        }
    }
}

// MARK: - Message list

private struct MessageList: View {
    @Bindable var store: InboxStore
    let sender: Sender

    var body: some View {
        // `sender.messages` is pre-sorted newest-first by `groupedBySender()`.
        // LazyVStack so SwiftUI only materializes Row structs for messages
        // currently in the scroll viewport. Eager VStack here would
        // allocate every Row up front for a sender with thousands of
        // messages — and re-render the whole stack on each `Observable`
        // tick (every checkbox click). The lazy form is the single
        // biggest scaling win for the inspector at 5k+ messages/sender.
        LazyVStack(spacing: 0) {
            ForEach(sender.messages) { message in
                Row(store: store, message: message)
                Divider().opacity(0.3)
            }
        }
        .padding(.horizontal, 12)
    }

    private struct Row: View {
        @Bindable var store: InboxStore
        let message: MessageHeader

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                TriStateCheckbox(
                    isOn: store.selectedMessageIds.contains(message.id),
                    isMixed: false
                ) { newValue in
                    if newValue { store.selectedMessageIds.insert(message.id) }
                    else        { store.selectedMessageIds.remove(message.id) }
                }
                .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if !message.isRead {
                            Circle()
                                .fill(.tint)
                                .frame(width: 6, height: 6)
                                // Unread state is otherwise color-only.
                                // Give it a label so VoiceOver and the
                                // sender list rotor surface it.
                                .accessibilityLabel("Unread")
                        }
                        if message.isLikelyTransactional {
                            Image(systemName: "dollarsign.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 11))
                                .help("Looks transactional — protected from rules when that setting is on.")
                        }
                        if message.isFromDisposableDomain {
                            Image(systemName: "trash.slash.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 11))
                                .help("Sender's domain appears on the bundled disposable-email-domains list.")
                        }
                        Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                            .lineLimit(2)
                    }
                    Text(message.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Cluster inspector

private struct ClusterInspector: View {
    @Bindable var store: InboxStore
    @Bindable var ruleStore: RuleStore
    let cluster: SubjectCluster
    let onAnalyzeSenders: ([Sender]) -> Void

    @State private var ruleDraft: Rule?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                actionBar
                Divider()
                messagesHeader
                ClusterMessageList(store: store, cluster: cluster)
            }
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $ruleDraft) { draft in
            RuleBuilderSheet(ruleStore: ruleStore, inbox: store, initial: draft)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text(cluster.representative)
                    .font(.title3).bold()
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                StatChip(label: "Messages", value: cluster.messageCount.formatted())
                StatChip(label: "Unread", value: cluster.unreadCount.formatted(), tinted: cluster.unreadCount > 0)
                StatChip(label: "Senders", value: cluster.uniqueSenderCount.formatted())
                StatChip(
                    label: "Most recent",
                    value: cluster.mostRecent.formatted(date: .abbreviated, time: .omitted)
                )
            }
        }
        .padding(.horizontal, 12)
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Mirrors `SenderInspector.actionBar`: prominent read-only AI button + a single
            // secondary menu for destructive shortcuts so the inspector doesn't visually
            // duplicate the bottom BulkActionBar's verbs.
            Button {
                onAnalyzeSenders(distinctSenders())
            } label: {
                Label("Analyze senders with AI", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Menu {
                Button {
                    runOnCluster { store.archiveSelection() }
                } label: {
                    Label("Archive all in cluster", systemImage: "archivebox")
                }
                Button(role: .destructive) {
                    runOnCluster { store.startDelete() }
                } label: {
                    Label("Delete all in cluster", systemImage: "trash")
                }
                Divider()
                Button {
                    ruleDraft = inspectorRuleDraft()
                } label: {
                    Label("Create rule from subject", systemImage: "wand.and.stars")
                }
            } label: {
                Label(applyToAllLabel, systemImage: "ellipsis.circle")
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.borderedButton)
            .controlSize(.large)
            .help("One-click shortcuts that act on every message in this subject cluster. To act on a subset, check messages below and use the bottom action bar.")
        }
        .padding(.horizontal, 12)
    }

    private var applyToAllLabel: String {
        let count = cluster.messageCount.formatted()
        let plural = cluster.messageCount == 1 ? "message" : "messages"
        return "Apply to all \(count) \(plural)…"
    }

    private var messagesHeader: some View {
        HStack(spacing: 8) {
            Text("Messages")
                .font(.headline)
            Spacer()
            TriStateCheckbox(
                isOn: store.isClusterFullySelected(cluster),
                isMixed: store.isClusterPartiallySelected(cluster)
            ) { newValue in
                store.setClusterSelected(cluster, selected: newValue)
            }
            .frame(width: 20)
            Text(store.isClusterFullySelected(cluster) ? "Deselect all" : "Select all")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
    }

    /// Distinct senders represented in the cluster, looked up from the live sender index so
    /// the AI analysis sheet has full message context for each one.
    private func distinctSenders() -> [Sender] {
        var seen: Set<String> = []
        var senders: [Sender] = []
        for message in cluster.messages {
            let key = message.senderAddress.lowercased()
            guard seen.insert(key).inserted else { continue }
            if let sender = store.sender(byId: key) { senders.append(sender) }
        }
        return senders
    }

    /// Run a bulk-action helper (`archiveSelection`, `startDelete`) scoped to the cluster's
    /// message ids, then restore the user's prior selection. The action methods themselves
    /// clear `selectedMessageIds` internally; the save/restore is so the user doesn't get
    /// yanked out of whatever they had checked.
    private func runOnCluster(_ action: () -> Void) {
        let saved = store.selectedMessageIds
        store.selectedMessageIds = Set(cluster.messages.map(\.id))
        action()
        store.selectedMessageIds = saved
    }

    private func inspectorRuleDraft() -> Rule {
        // Use the subject's normalized form so the rule survives slight variations like
        // "Re: ", thread numbers, etc. — same canonicalization the cluster id uses.
        var conditions = Rule.Conditions()
        conditions.subjectContains = cluster.id
        return Rule(conditions: conditions, outcome: .archive)
    }
}

private struct ClusterMessageList: View {
    @Bindable var store: InboxStore
    let cluster: SubjectCluster

    var body: some View {
        // `cluster.messages` is pre-sorted newest-first by `clusteredBySubject()`.
        // LazyVStack for the same reason as `MessageList` above — a hot
        // subject cluster can pull in hundreds of messages, and we
        // shouldn't allocate a Row for every one of them on first paint.
        LazyVStack(spacing: 0) {
            ForEach(cluster.messages) { message in
                Row(store: store, message: message)
                Divider().opacity(0.3)
            }
        }
        .padding(.horizontal, 12)
    }

    private struct Row: View {
        @Bindable var store: InboxStore
        let message: MessageHeader

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                TriStateCheckbox(
                    isOn: store.selectedMessageIds.contains(message.id),
                    isMixed: false
                ) { newValue in
                    if newValue { store.selectedMessageIds.insert(message.id) }
                    else        { store.selectedMessageIds.remove(message.id) }
                }
                .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if !message.isRead {
                            Circle()
                                .fill(.tint)
                                .frame(width: 6, height: 6)
                                // Unread state is otherwise color-only.
                                // Give it a label so VoiceOver and the
                                // sender list rotor surface it.
                                .accessibilityLabel("Unread")
                        }
                        Text(message.senderName.isEmpty ? message.senderAddress : message.senderName)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(message.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
    }
}
