import Foundation

/// Identifier for the user's chosen AI backend. Surfaced in settings and used to look up the
/// matching `LLMProvider` implementation.
public enum AIProviderKind: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case appleFoundation = "apple-foundation"
    case openai          = "openai"
    case anthropic       = "anthropic"
    case google          = "google"
    case perplexity      = "perplexity"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .appleFoundation: "Apple Foundation Models (on-device)"
        case .openai:          "OpenAI (ChatGPT)"
        case .anthropic:       "Anthropic (Claude)"
        case .google:          "Google (Gemini)"
        case .perplexity:      "Perplexity"
        }
    }

    /// True for providers that require the user to paste a personal API key.
    public var requiresAPIKey: Bool {
        self != .appleFoundation
    }

    /// One-line privacy disclosure shown next to the picker.
    public var privacyNote: String {
        switch self {
        case .appleFoundation:
            return "Runs locally on your Mac (or via Apple's Private Cloud Compute for harder requests). Prompts never reach a developer-operated server."
        case .openai:
            return "File13 will send subjects, sender addresses, and other selected metadata directly to OpenAI using your API key. Body content is never sent. OpenAI's privacy policy applies."
        case .anthropic:
            return "File13 will send subjects, sender addresses, and other selected metadata directly to Anthropic using your API key. Body content is never sent. Anthropic's privacy policy applies."
        case .google:
            return "File13 will send subjects, sender addresses, and other selected metadata directly to Google AI using your API key. Body content is never sent. Google's privacy policy applies."
        case .perplexity:
            return "File13 will send subjects, sender addresses, and other selected metadata directly to Perplexity using your API key. Body content is never sent. Perplexity's privacy policy applies."
        }
    }

    /// Default model to request when this provider is selected. Empty string for Apple (the
    /// system manages model selection itself).
    public var defaultModel: String {
        availableModels.first?.id ?? ""
    }

    /// Curated list of well-known model IDs we surface in the picker. Settings also accepts a
    /// custom ID typed by the user, so this list doesn't have to be exhaustive — just a starting
    /// menu of the common ones.
    public var availableModels: [AIModelOption] {
        switch self {
        case .appleFoundation:
            return []
        case .openai:
            return [
                .init(id: "gpt-4o-mini", label: "GPT-4o mini",
                      summary: "Fast and cheap. Good default for triage."),
                .init(id: "gpt-4o", label: "GPT-4o",
                      summary: "More capable, ~10× the price of mini."),
                .init(id: "gpt-4.1", label: "GPT-4.1",
                      summary: "Stronger general model."),
                .init(id: "gpt-4.1-mini", label: "GPT-4.1 mini",
                      summary: "Lightweight 4.1."),
                .init(id: "o3-mini", label: "o3-mini",
                      summary: "Reasoning model. Slower, better on hard prompts.")
            ]
        case .anthropic:
            return [
                .init(id: "claude-haiku-4-5", label: "Claude Haiku 4.5",
                      summary: "Fast and cheap. Good default."),
                .init(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6",
                      summary: "Balanced model."),
                .init(id: "claude-sonnet-4-7", label: "Claude Sonnet 4.7",
                      summary: "Latest Sonnet."),
                .init(id: "claude-opus-4-7", label: "Claude Opus 4.7",
                      summary: "Most capable, slowest, most expensive.")
            ]
        case .google:
            return [
                .init(id: "gemini-2.0-flash", label: "Gemini 2.0 Flash",
                      summary: "Fast and cheap."),
                .init(id: "gemini-2.5-flash", label: "Gemini 2.5 Flash",
                      summary: "Newer Flash, balanced."),
                .init(id: "gemini-2.5-pro", label: "Gemini 2.5 Pro",
                      summary: "Most capable.")
            ]
        case .perplexity:
            return [
                .init(id: "sonar", label: "Sonar",
                      summary: "Default."),
                .init(id: "sonar-pro", label: "Sonar Pro",
                      summary: "Stronger model."),
                .init(id: "sonar-reasoning", label: "Sonar Reasoning",
                      summary: "Multi-step reasoning.")
            ]
        }
    }
}

public struct AIModelOption: Hashable, Identifiable, Sendable {
    public let id: String        // sent to the API
    public let label: String     // display name
    public let summary: String?  // optional one-line description

    public init(id: String, label: String, summary: String? = nil) {
        self.id = id
        self.label = label
        self.summary = summary
    }
}

/// Result of querying a provider for whether it can be used right now.
public enum ProviderAvailability: Equatable, Sendable {
    case ready
    /// User-correctable: missing API key, Apple Intelligence not enabled, etc.
    case needsSetup(message: String)
    /// Not user-correctable on this machine: hardware doesn't support Apple Intelligence, etc.
    case unsupported(message: String)
    /// Network/credential failure observed on the last attempt.
    case error(message: String)
}

/// Per-call generation knobs. Both fields are optional — when nil, each provider falls back
/// to the value it was hard-coding before per-feature tuning shipped (so unmodified callers
/// see no behavior change). Power users surface non-nil values via `AIFeatureTuning`.
public struct LLMGenerationOptions: Sendable, Equatable {
    /// Sampling temperature. Provider-specific range, but we clamp to `[0.0, 1.0]` at the
    /// call site since that's the safe common ceiling across OpenAI / Anthropic / Google /
    /// Perplexity / Apple Foundation Models.
    public var temperature: Double?
    /// Cap on output tokens. Anthropic requires a value (we keep its existing 1024 default
    /// when nil); everywhere else we send the field only when non-nil.
    public var maxTokens: Int?

    public init(temperature: Double? = nil, maxTokens: Int? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    public static let `default` = LLMGenerationOptions()
}

/// Minimal LLM contract used by the rest of the app. Everything else (sender insights, suggested
/// rules, …) builds prompts and consumes plain-text responses on top of this.
public protocol LLMProvider: Sendable {
    var kind: AIProviderKind { get }
    var displayName: String { get }

    func availability() async -> ProviderAvailability

    /// Send the user prompt, optionally prefixed by system-level instructions, and return the
    /// model's plain-text response. Implementations are responsible for any provider-specific
    /// formatting, retries, and timeout policy. `options` carries optional per-call overrides
    /// for temperature / max output tokens — provider keeps its existing default when an option
    /// is nil.
    func generate(systemInstructions: String?, userPrompt: String, options: LLMGenerationOptions) async throws -> String
}

public extension LLMProvider {
    /// Convenience overload for the common case where the caller doesn't need to override
    /// temperature or max tokens. Forwards to the canonical signature with `.default`.
    func generate(systemInstructions: String?, userPrompt: String) async throws -> String {
        try await generate(systemInstructions: systemInstructions, userPrompt: userPrompt, options: .default)
    }
}

public enum LLMProviderError: LocalizedError {
    case notImplemented(provider: AIProviderKind)
    case missingAPIKey(provider: AIProviderKind)
    case unsupported(message: String)
    case requestFailed(statusCode: Int, body: String?)
    case decodingFailed(String)
    case underlying(Error)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let p):
            return "\(p.label) isn't supported in this build yet."
        case .missingAPIKey(let p):
            return "Add your \(p.label) API key in Settings → AI Integration."
        case .unsupported(let message):
            return message
        case .requestFailed(let code, let body):
            if let body, !body.isEmpty {
                return "AI provider returned HTTP \(code): \(body.prefix(200))"
            }
            return "AI provider returned HTTP \(code)."
        case .decodingFailed(let detail):
            return "Couldn't decode the AI provider's response: \(detail)"
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}
