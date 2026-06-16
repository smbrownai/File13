import Foundation

/// A draft rule the AI proposes after analyzing the user's read/unread patterns. Suggestions
/// are presented as accept/dismiss cards in the Rules settings tab — accepting promotes the
/// suggestion into a real `Rule` in the `RuleStore`. Dismissals are session-scoped.
public struct RuleSuggestion: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Short title for the suggestion card. The model writes this directly. Should read like
    /// a rule name (e.g. "Archive promotional you never open").
    public let title: String
    /// 1–2 sentences explaining why the suggestion exists, drawn from the metadata the model
    /// saw — read rate, volume, category, and so on.
    public let rationale: String
    public let conditions: Rule.Conditions
    public let outcome: Rule.Outcome
    /// Local count of how many existing headers in the inbox would match this suggestion's
    /// conditions right now. Computed by `RuleSuggester`, not the LLM, so the user gets an
    /// accurate "applies to N messages" preview.
    public let estimatedMatches: Int

    public init(id: UUID, title: String, rationale: String, conditions: Rule.Conditions, outcome: Rule.Outcome, estimatedMatches: Int) {
        self.id = id
        self.title = title
        self.rationale = rationale
        self.conditions = conditions
        self.outcome = outcome
        self.estimatedMatches = estimatedMatches
    }

    public func makeRule() -> Rule {
        Rule(
            id: UUID(),
            name: title,
            enabled: false,    // user reviews the rule before turning it on
            conditions: conditions,
            outcome: outcome
        )
    }
}
