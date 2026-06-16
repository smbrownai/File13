import File13Core
import SwiftUI

/// iOS rule monitoring + manual run surface. The Mac app's rule builder
/// (RuleBuilderSheet) is intentionally not ported in v1 — composing
/// conditions and outcomes is a desk-keyboard task, and the iOS surface is
/// "see what's set up, toggle them on / off, run them now."
///
/// Reads everything from the shared RuleStore + InboxStore — the runRules
/// pipeline, transactional protection, VIP protection, buffered-action
/// commits, undo banner, all the same code paths the Mac app uses.
///
/// Also hosts on-demand AI rule suggestions via `RuleSuggester`. The Mac app
/// surfaces suggestions in two places (a settings card and a dedicated sheet);
/// on iOS we put them right above the rules list, since the Rules tab is
/// already the rules-themed surface and the suggestion → rule flow is one
/// tap. Dismissals persist in `SuggestionDismissalStore`, fingerprint-keyed,
/// same as the macOS path.
struct iOSRulesTab: View {
    @Bindable var ruleStore: RuleStore
    @Bindable var inbox: InboxStore
    @Bindable var settings: SettingsStore
    @Bindable var categoryStore: SenderCategoryStore
    @Bindable var vipStore: VIPStore
    @Bindable var suggestionDismissals: SuggestionDismissalStore

    @State private var isRunning = false
    @State private var showSkipReason = false
    @State private var skipMessage = ""

    @State private var suggestions: [RuleSuggestion] = []
    @State private var isLoadingSuggestions = false
    @State private var suggestionsError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let report = ruleStore.lastRunReport {
                    lastRunSection(report)
                }
                suggestionsSection
                rulesSection
                scheduleSection
                helpSection
            }
            .navigationTitle("Rules")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        runRulesNow()
                    } label: {
                        if isRunning {
                            ProgressView()
                        } else {
                            Label("Run Rules Now", systemImage: "play.circle.fill")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .disabled(isRunning || ruleStore.enabledRules.isEmpty || inbox.sessions.isEmpty)
                }
            }
            .alert("Rules didn't run", isPresented: $showSkipReason) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(skipMessage)
            }
        }
    }

    // MARK: - Last run

    @ViewBuilder
    private func lastRunSection(_ report: RuleRunReport) -> some View {
        Section {
            if let reason = report.skipReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if report.ranAnything {
                ForEach(report.actions) { action in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.ruleName)
                                .font(.subheadline)
                            Text(action.outcomeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(action.count)")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                summaryRow(report)
            } else {
                Text("No matches this run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Last run")
                Spacer()
                if let at = ruleStore.lastRunAt {
                    Text(at, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
    }

    private func summaryRow(_ report: RuleRunReport) -> some View {
        HStack {
            Text("Total")
                .fontWeight(.medium)
            Spacer()
            Text("\(report.totalAffected) message\(report.totalAffected == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if report.protectedFromRules > 0 {
                Text("· \(report.protectedFromRules) protected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        Section {
            if ruleStore.rules.isEmpty {
                Text("No rules yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(ruleStore.rules) { rule in
                    ruleRow(rule)
                }
            }
        } header: {
            Text("Rules (\(ruleStore.rules.count))")
        } footer: {
            Text("Rules are created on the Mac app. Enable, disable, and run them from here.")
        }
    }

    private func ruleRow(_ rule: Rule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name)
                        .font(.subheadline)
                    Text(rule.conditions.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { rule.enabled },
                    set: { ruleStore.setEnabled(id: rule.id, enabled: $0) }
                ))
                .labelsHidden()
            }
            Label(rule.outcome.label, systemImage: rule.outcome.symbol)
                .font(.caption2)
                .foregroundStyle(.tint)
                .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        Section {
            Picker("Schedule", selection: $ruleStore.schedule) {
                ForEach(RuleSchedule.allCases) { schedule in
                    Text(scheduleLabel(schedule)).tag(schedule)
                }
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text(scheduleFooter)
        }
    }

    private func scheduleLabel(_ schedule: RuleSchedule) -> String {
        switch schedule {
        case .manual:   return "Manual only"
        case .onLaunch: return "When the app opens"
        case .hourly:   return "Every hour"
        case .daily:    return "Every day"
        }
    }

    private var scheduleFooter: String {
        switch ruleStore.schedule {
        case .manual:
            return "Use the Run button when you want rules to fire."
        case .onLaunch:
            return "Rules run automatically every time you open File13."
        case .hourly, .daily:
            return "Rules run automatically while the app is open."
        }
    }

    // MARK: - Help

    private var helpSection: some View {
        Section {
            if settings.protectTransactionalFromDeletion {
                Label("Transactional messages are protected from delete rules.", systemImage: "shield.lefthalf.filled")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if settings.protectVIPsFromRules {
                Label("VIPs are protected from delete rules.", systemImage: "star.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !settings.protectTransactionalFromDeletion && !settings.protectVIPsFromRules {
                Label("None.", systemImage: "slash.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Protections")
        }
    }

    // MARK: - Suggestions

    /// Suggestions surfaced from the most recent run, minus anything the user
    /// dismissed. Empty by default — generation is on-demand.
    private var visibleSuggestions: [RuleSuggestion] {
        suggestions.filter { !suggestionDismissals.isDismissed($0) }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        Section {
            if isLoadingSuggestions {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Asking \(settings.aiProvider.label)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if visibleSuggestions.isEmpty {
                Button {
                    Task { await loadSuggestions() }
                } label: {
                    Label(suggestionsCTA, systemImage: "sparkles")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!canRequestSuggestions)
            } else {
                ForEach(visibleSuggestions) { suggestion in
                    suggestionRow(suggestion)
                }
                Button {
                    Task { await loadSuggestions() }
                } label: {
                    Label("Regenerate suggestions", systemImage: "arrow.clockwise")
                        .font(.callout)
                }
            }
            if let error = suggestionsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        } header: {
            Text("Suggestions")
        } footer: {
            Text("Email headers only are sent to your configured AI provider when this runs.")
        }
    }

    /// CTA copy varies with state: "no AI rules yet" reads differently from
    /// "the AI's suggestions don't apply to your inbox yet".
    private var suggestionsCTA: String {
        if ruleStore.rules.isEmpty {
            return "Suggest rules from my inbox"
        } else {
            return "Suggest more rules"
        }
    }

    private var canRequestSuggestions: Bool {
        !inbox.senders.isEmpty
    }

    private func suggestionRow(_ suggestion: RuleSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: suggestion.outcome.symbol)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title.isEmpty ? "Suggested rule" : suggestion.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("\(suggestion.conditions.summary) → \(suggestion.outcome.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if suggestion.estimatedMatches > 0 {
                    Text("\(suggestion.estimatedMatches)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !suggestion.rationale.isEmpty {
                Text(suggestion.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button {
                    accept(suggestion)
                } label: {
                    Label("Add rule", systemImage: "plus.circle.fill")
                        .font(.callout)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(role: .cancel) {
                    dismissSuggestion(suggestion)
                } label: {
                    Text("Dismiss")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func loadSuggestions() async {
        suggestionsError = nil
        isLoadingSuggestions = true
        defer { isLoadingSuggestions = false }

        let provider = LLMProviderFactory.make(for: .ruleSuggest, settings: settings)
        let suggester = RuleSuggester(
            provider: provider,
            tuning: settings.tuning(for: .ruleSuggest)
        )

        // Use the whole-inbox corpus so suggestions can reason about archived
        // and sent-folder patterns, not just whatever's loaded in the
        // currently-displayed mailbox. Same call shape the macOS settings card
        // uses when the user hits "Suggest from whole inbox".
        let corpus = inbox.wholeInboxCorpus()
        do {
            suggestions = try await suggester.suggestWholeInbox(
                senders: corpus.senders,
                existingRules: ruleStore.rules,
                categoryFor: { categoryStore.category(for: $0) },
                repliedMessageIds: inbox.repliedMessageIds,
                isVIP: { vipStore.isVIP(senderId: $0) },
                allHeaders: corpus.headers
            )
        } catch {
            suggestionsError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func accept(_ suggestion: RuleSuggestion) {
        // Create the rule disabled so the user can review before turning it
        // on — matches the macOS pattern. Once they toggle it on, the
        // scheduler picks it up on the next run.
        var rule = suggestion.makeRule()
        rule.enabled = false
        ruleStore.upsert(rule)
        suggestionDismissals.dismiss(suggestion)
    }

    private func dismissSuggestion(_ suggestion: RuleSuggestion) {
        suggestionDismissals.dismiss(suggestion)
    }

    // MARK: - Actions

    private func runRulesNow() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            let report = await inbox.runRules(ruleStore.enabledRules)
            ruleStore.recordRun(report)
            isRunning = false
            if let reason = report.skipReason {
                skipMessage = reason
                showSkipReason = true
            }
        }
    }
}
