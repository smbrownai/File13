import File13Core
import SwiftUI

struct RulesSettingsView: View {
    @Bindable var ruleStore: RuleStore
    @Bindable var inbox: InboxStore
    @Bindable var settings: SettingsStore
    @Bindable var categoryStore: SenderCategoryStore
    @Bindable var suggestionDismissals: SuggestionDismissalStore
    @Bindable var vipStore: VIPStore

    @State private var showBuilder = false
    @State private var editingRule: Rule?
    @State private var pendingDelete: Rule?
    @State private var isRunning = false

    @State private var suggestions: [RuleSuggestion] = []
    @State private var isSuggesting = false
    @State private var suggestionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Pending-sync banner: shown if iCloud delivered
                    // rule changes that haven't been approved on this
                    // Mac. Rules run automatically on the user's
                    // schedule and have no undo buffer in the rule
                    // path, so a sync-injected `outcome: .delete` rule
                    // is potentially mass-data-loss. Banner gates that.
                    PendingRuleChangesBanner(ruleStore: ruleStore)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)

                    suggestionsSection
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                    if !suggestions.isEmpty || isSuggesting {
                        Divider().padding(.vertical, 12)
                    }
                    rulesList
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Run rules", selection: $ruleStore.schedule) {
                        ForEach(RuleSchedule.allCases) { schedule in
                            Text(schedule.label).tag(schedule)
                        }
                    }
                    .frame(maxWidth: 320)
                    Spacer()
                }
                Text(ruleStore.schedule.explainer)
                    .font(.callout).foregroundStyle(.secondary)
                if let report = ruleStore.lastRunReport, let when = ruleStore.lastRunAt {
                    LastRunSummary(report: report, at: when)
                }
                HStack {
                    Button {
                        showBuilder = true
                    } label: {
                        Label("New Rule", systemImage: "plus")
                    }
                    Spacer()
                    Button {
                        Task { await runNow() }
                    } label: {
                        if isRunning {
                            ProgressView().controlSize(.small).padding(.horizontal, 4)
                        } else {
                            Label("Run All Rules Now", systemImage: "play.circle")
                        }
                    }
                    .disabled(isRunning || ruleStore.enabledRules.isEmpty || inbox.connectedAccount == nil)
                    .help(runHelpText)
                }
            }
            .padding(12)
        }
        .sheet(isPresented: $showBuilder) {
            RuleBuilderSheet(ruleStore: ruleStore, inbox: inbox, initial: Rule())
        }
        .sheet(item: $editingRule) { rule in
            RuleBuilderSheet(ruleStore: ruleStore, inbox: inbox, initial: rule, isEditing: true)
        }
        .confirmationDialog(
            "Delete this rule?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { rule in
            Button("Delete", role: .destructive) { ruleStore.remove(id: rule.id) }
            Button("Cancel", role: .cancel) { }
        } message: { rule in
            Text("Removing \"\(rule.name.isEmpty ? "Untitled rule" : rule.name)\" can't be undone.")
        }
    }

    @ViewBuilder
    private var rulesList: some View {
        if ruleStore.rules.isEmpty {
            ContentUnavailableView(
                "No rules yet",
                systemImage: "wand.and.stars",
                description: Text("Create rules to automatically delete, archive, or move messages that match conditions you define.")
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            List {
                ForEach(ruleStore.rules) { rule in
                    RuleRow(rule: rule, ruleStore: ruleStore) {
                        editingRule = rule
                    } onDelete: {
                        pendingDelete = rule
                    }
                }
                .onMove { ruleStore.move(from: $0, to: $1) }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Warn when ruleSuggest is using a different provider than the
            // global setting — protects against silent provider re-routing
            // via iCloud sync (mitigated by the per-device confirm flow,
            // but worth surfacing at the action site too).
            ProviderOverrideBanner(feature: .ruleSuggest, settings: settings)

            HStack(alignment: .firstTextBaseline) {
                Text("AI suggestions")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await generateSuggestions(scope: .currentMailbox) }
                } label: {
                    if isSuggesting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Analyzing…")
                        }
                    } else if visibleSuggestions.isEmpty {
                        Label("Suggest rules with AI", systemImage: "sparkles")
                    } else {
                        Label("Re-run suggestions", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isSuggesting || inbox.senders.isEmpty)
                .help("Look at the senders in the currently-displayed mailbox and propose rules. Metadata only — no body content sent.")
                Button {
                    Task { await generateSuggestions(scope: .wholeInbox) }
                } label: {
                    Label("Whole mailbox", systemImage: "tray.2")
                }
                .disabled(isSuggesting || inbox.sessions.isEmpty)
                .help("Look at every cached folder (Inbox, Archive, Sent, custom folders) and propose rules with cross-folder evidence. Slower; same privacy posture.")
            }

            if let error = suggestionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .lineLimit(3, reservesSpace: false)
            }

            if visibleSuggestions.isEmpty && !isSuggesting && suggestionError == nil {
                Text("File13 can read your sender stats and propose rules; for example, archive promotional senders you never open. Suggestions arrive disabled by default; you review before turning them on.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(visibleSuggestions) { suggestion in
                SuggestionCard(
                    suggestion: suggestion,
                    onAccept: { accept(suggestion) },
                    onDismiss: { dismiss(suggestion) }
                )
            }
        }
    }

    private var visibleSuggestions: [RuleSuggestion] {
        // Hide suggestions the user has already dismissed in any prior run — fingerprint
        // match on conditions+outcome, so re-suggesting the same intent stays gone.
        suggestions.filter { !suggestionDismissals.isDismissed($0) }
    }

    /// Which corpus the run pulls from. The two paths differ only in `senders`
    /// / `allHeaders` — the suggester picks, prompts, and matches the same way.
    private enum SuggestionScope { case currentMailbox, wholeInbox }

    private func generateSuggestions(scope: SuggestionScope) async {
        isSuggesting = true
        suggestionError = nil
        defer { isSuggesting = false }
        let provider = LLMProviderFactory.make(for: .ruleSuggest, settings: settings)
        let suggester = RuleSuggester(provider: provider, tuning: settings.tuning(for: .ruleSuggest))
        do {
            let result: [RuleSuggestion]
            switch scope {
            case .currentMailbox:
                result = try await suggester.suggest(
                    senders: inbox.senders,
                    existingRules: ruleStore.rules,
                    categoryFor: { categoryStore.category(for: $0) },
                    repliedMessageIds: inbox.repliedMessageIds,
                    isVIP: { vipStore.isVIP(senderId: $0) },
                    allHeaders: inbox.allHeaders
                )
            case .wholeInbox:
                let corpus = inbox.wholeInboxCorpus()
                result = try await suggester.suggestWholeInbox(
                    senders: corpus.senders,
                    existingRules: ruleStore.rules,
                    categoryFor: { categoryStore.category(for: $0) },
                    repliedMessageIds: inbox.repliedMessageIds,
                    isVIP: { vipStore.isVIP(senderId: $0) },
                    allHeaders: corpus.headers
                )
            }
            suggestions = result
        } catch {
            suggestionError = error.localizedDescription
        }
    }

    private func accept(_ suggestion: RuleSuggestion) {
        ruleStore.upsert(suggestion.makeRule())
        // Accepting also dismisses — otherwise the same suggestion would resurface every run.
        suggestionDismissals.dismiss(suggestion)
    }

    private func dismiss(_ suggestion: RuleSuggestion) {
        suggestionDismissals.dismiss(suggestion)
    }

    private var runHelpText: String {
        if inbox.connectedAccount == nil { return "Connect an account before running rules." }
        if ruleStore.enabledRules.isEmpty { return "Enable at least one rule with conditions to run." }
        return "Apply enabled rules to the current mailbox."
    }

    private func runNow() async {
        isRunning = true
        defer { isRunning = false }
        let report = await inbox.runRules(ruleStore.enabledRules)
        ruleStore.recordRun(report)
    }
}

private struct SuggestionCard: View {
    let suggestion: RuleSuggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: suggestion.outcome.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title.isEmpty ? "Suggested rule" : suggestion.title)
                        .font(.headline)
                    Text(suggestion.conditions.summary + " → " + suggestion.outcome.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(suggestion.rationale)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text("\(suggestion.estimatedMatches.formatted()) matching message\(suggestion.estimatedMatches == 1 ? "" : "s") right now")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Dismiss") { onDismiss() }
                Button {
                    onAccept()
                } label: {
                    Label("Add (disabled)", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .help("Adds the rule to your list with the toggle off. Review and turn it on when ready.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }
}

private struct RuleRow: View {
    let rule: Rule
    @Bindable var ruleStore: RuleStore
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rule.outcome.symbol)
                .font(.title3)
                .frame(width: 28, height: 28)
                .foregroundStyle(rule.enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Untitled rule" : rule.name)
                    .font(.headline)
                Text(rule.conditions.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("→ \(rule.outcome.label) · in \(rule.effectiveScope.summary)")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { ruleStore.setEnabled(id: rule.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit rule")

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Delete rule")
        }
        .padding(.vertical, 4)
    }
}

private struct LastRunSummary: View {
    let report: RuleRunReport
    let at: Date

    private var formattedTime: String {
        at.formatted(.relative(presentation: .numeric))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                if let reason = report.skipReason {
                    Text("Last run \(formattedTime) — skipped: \(reason)")
                        .font(.callout).foregroundStyle(.secondary)
                } else if report.actions.isEmpty {
                    Text("Last run \(formattedTime) — no matches.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Last run \(formattedTime) — \(report.totalAffected.formatted()) message\(report.totalAffected == 1 ? "" : "s") affected.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(report.actions) { action in
                Text("• \(action.ruleName): \(action.outcomeLabel) × \(action.count.formatted())")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if report.protectedFromRules > 0 {
                Label(
                    "\(report.protectedFromRules.formatted()) message\(report.protectedFromRules == 1 ? "" : "s") protected as transactional (receipts, invoices, …).",
                    systemImage: "shield.lefthalf.filled"
                )
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 4)
    }
}
