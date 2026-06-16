import Foundation

/// Identifies one AI-powered feature in the app. Used to look up per-feature tuning
/// (custom prompt suffix, temperature, max tokens, provider/model override) on
/// `SettingsStore`.
public enum AIFeature: String, CaseIterable, Identifiable, Hashable, Sendable {
    case senderAdvice       // SenderAdvisor — one sender, one recommendation.
    case senderCategorize   // SenderCategorizer — batches of senders → category each.
    case ruleSuggest        // RuleSuggester — bulk + per-sender rule proposals.

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .senderAdvice:     "Per-sender triage"
        case .senderCategorize: "Sender categorization"
        case .ruleSuggest:      "Rule suggestions"
        }
    }

    public var description: String {
        switch self {
        case .senderAdvice:
            "Recommends keep / archive / delete / unsubscribe for one sender at a time."
        case .senderCategorize:
            "Buckets senders into categories (newsletter, work, personal, etc.) in batches."
        case .ruleSuggest:
            "Proposes inbox-cleanup rules from read rates, reply counts, and categories."
        }
    }

    /// Temperature used for this feature when the user hasn't overridden it. Mirrors
    /// the values that were hard-coded in the providers before per-feature tuning
    /// shipped — bumped slightly for `ruleSuggest`, where a touch more variation in
    /// the suggestion set is welcome.
    public var defaultTemperature: Double {
        switch self {
        case .senderAdvice:     0.2
        case .senderCategorize: 0.0
        case .ruleSuggest:      0.3
        }
    }

    /// Max output tokens used for this feature when the user hasn't overridden it.
    /// Anthropic requires this; everywhere else it's optional and we send it only when
    /// non-nil.
    public var defaultMaxTokens: Int {
        switch self {
        case .senderAdvice:     1024   // single small JSON object
        case .senderCategorize: 2048   // up to 25 assignments per batch
        case .ruleSuggest:      1500   // up to 6 suggestion objects
        }
    }
}

/// Per-feature override bag. Empty / nil fields fall back to the feature's hard-coded defaults
/// (`AIFeature.defaultTemperature`, `AIFeature.defaultMaxTokens`) and the global `aiProvider`
/// / `aiModel` setting on `SettingsStore`. The all-defaults shape preserves prior behavior, so
/// users who never open the tuning UI see no change.
public struct AIFeatureTuning: Codable, Equatable, Sendable {
    public var customInstructions: String = ""
    public var temperature: Double? = nil
    public var maxTokens: Int? = nil
    public var providerOverride: AIProviderKind? = nil
    public var modelOverride: String = ""

    public init(
        customInstructions: String = "",
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        providerOverride: AIProviderKind? = nil,
        modelOverride: String = ""
    ) {
        self.customInstructions = customInstructions
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.providerOverride = providerOverride
        self.modelOverride = modelOverride
    }

    /// True iff none of the tuning fields differ from defaults — used to grey out the
    /// "Reset" button in the settings UI and to elide empty entries from the persisted JSON.
    public var isDefault: Bool {
        customInstructions.isEmpty
            && temperature == nil
            && maxTokens == nil
            && providerOverride == nil
            && modelOverride.isEmpty
    }

    /// Maximum length of `customInstructions` accepted into a prompt.
    /// Belt-and-suspenders cap — the UI text editor also enforces this,
    /// but a synced-from-attacker (or programmatically-written) value
    /// would bypass the UI. At ~4 KB this still leaves room for genuinely
    /// elaborate user instructions; longer than that and the user is
    /// almost certainly hitting per-provider prompt limits anyway.
    public static let customInstructionsMaxChars = 4096

    /// Format the user's `customInstructions` for splicing into a system prompt. Empty /
    /// whitespace-only input returns `""` — no separator, no marker — so the request looks
    /// identical to the pre-tuning behavior. Otherwise we wrap with a clear header so the
    /// model can distinguish app-level rules from user overrides.
    ///
    /// Length is clamped to `customInstructionsMaxChars` to prevent a
    /// pathologically-large (or attacker-injected via iCloud sync)
    /// payload from being prepended to every AI call — which on paid
    /// providers would silently drain the user's API quota.
    public var customInstructionsBlock: String {
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let bounded = trimmed.count <= Self.customInstructionsMaxChars
            ? trimmed
            : String(trimmed.prefix(Self.customInstructionsMaxChars))
        return "\n\n--- User custom instructions ---\n\(bounded)"
    }
}
