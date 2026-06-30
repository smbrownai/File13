import Foundation

/// Make an `LLMProvider` instance for the user's currently selected backend, with optional
/// per-feature overrides.
@MainActor
public enum LLMProviderFactory {
    /// Build a provider for the user's *globally* selected backend (the picker in
    /// AI Integration settings). Used when no per-feature override applies — e.g. the
    /// "Test connection" affordance in settings itself.
    public static func make(kind: AIProviderKind, settings: SettingsStore) -> any LLMProvider {
        return makeProvider(kind: kind, model: settings.aiModel)
    }

    /// Build a provider for one AI feature, applying any per-feature provider/model override
    /// the user has set. Resolution: feature override → global setting → provider default.
    /// When the feature has its own provider override, the global model setting is *not* used
    /// (it belongs to a different provider) — we use the feature's `modelOverride` if set,
    /// otherwise the chosen provider's `defaultModel`.
    public static func make(for feature: AIFeature, settings: SettingsStore) -> any LLMProvider {
        let tuning = settings.tuning(for: feature)
        if let override = tuning.providerOverride {
            let model = !tuning.modelOverride.isEmpty
                ? tuning.modelOverride
                : override.defaultModel
            return makeProvider(kind: override, model: model)
        }
        // No provider override → inherit global. Per-feature `modelOverride` is only honored
        // alongside a provider override, since model IDs aren't portable across providers.
        return makeProvider(kind: settings.aiProvider, model: settings.aiModel)
    }

    private static func makeProvider(kind: AIProviderKind, model: String) -> any LLMProvider {
        switch kind {
        case .appleFoundation:
            return AppleFoundationModelsProvider()
        case .openai:
            let key = try? KeychainStore.loadAIKey(for: kind)
            return OpenAIProvider(apiKey: key, model: model)
        case .anthropic:
            let key = try? KeychainStore.loadAIKey(for: kind)
            return AnthropicProvider(apiKey: key, model: model)
        case .google:
            let key = try? KeychainStore.loadAIKey(for: kind)
            return GoogleProvider(apiKey: key, model: model)
        case .perplexity:
            let key = try? KeychainStore.loadAIKey(for: kind)
            return PerplexityProvider(apiKey: key, model: model)
        }
    }
}
