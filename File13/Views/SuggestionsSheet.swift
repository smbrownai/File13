import File13Core
import SwiftUI

/// Modal sheet hosting AI-generated rule suggestions for a single sender. Triggered from the
/// inspector's "Apply to all" menu and from sender-row context menus in the activity drawer,
/// so the user can ask "what should I do about this sender?" without leaving the inbox.
struct SuggestionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let sender: Sender
    @Bindable var ruleStore: RuleStore
    @Bindable var inbox: InboxStore
    @Bindable var settings: SettingsStore
    @Bindable var categoryStore: SenderCategoryStore
    @Bindable var suggestionDismissals: SuggestionDismissalStore
    @Bindable var vipStore: VIPStore

    @State private var suggestions: [RuleSuggestion] = []
    @State private var isLoading: Bool = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
                .padding(.bottom, 0)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isLoading {
                        loadingState
                    } else if let error {
                        errorState(error)
                    } else if visibleSuggestions.isEmpty {
                        emptyState
                    } else {
                        ForEach(visibleSuggestions) { suggestion in
                            SuggestionCard(
                                suggestion: suggestion,
                                onAccept: { accept(suggestion) },
                                onDismiss: { dismiss(suggestion) }
                            )
                        }
                    }
                }
                .padding(20)
            }
            .frame(minHeight: 260, maxHeight: 480)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 540)
        .task { await loadSuggestions() }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Suggestions for \(sender.name.isEmpty ? sender.address : sender.name)")
                    .font(.title3).bold()
                    .lineLimit(1)
                Text("File13 looked at this sender's metadata and proposed rules below. Each one is added with the toggle off so you can review before turning it on.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Analyzing this sender's pattern…")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No suggestions",
            systemImage: "checkmark.seal",
            description: Text("Nothing to recommend for this sender right now.")
        )
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Logic

    private var visibleSuggestions: [RuleSuggestion] {
        suggestions.filter { !suggestionDismissals.isDismissed($0) }
    }

    private func loadSuggestions() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let provider = LLMProviderFactory.make(for: .ruleSuggest, settings: settings)
        let suggester = RuleSuggester(provider: provider, tuning: settings.tuning(for: .ruleSuggest))
        do {
            suggestions = try await suggester.suggest(
                forSender: sender,
                existingRules: ruleStore.rules,
                categoryFor: { categoryStore.category(for: $0) },
                repliedMessageIds: inbox.repliedMessageIds,
                isVIP: { vipStore.isVIP(senderId: $0) },
                allHeaders: inbox.allHeaders
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func accept(_ suggestion: RuleSuggestion) {
        ruleStore.upsert(suggestion.makeRule())
        suggestionDismissals.dismiss(suggestion)
    }

    private func dismiss(_ suggestion: RuleSuggestion) {
        suggestionDismissals.dismiss(suggestion)
    }
}

// MARK: - Suggestion card

/// Shared layout used by both the rules-tab list and this sheet. Mirrors the card styling in
/// `RulesSettingsView`'s private `SuggestionCard` — same visual weight so users see the same
/// affordances in both places.
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
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }
}
