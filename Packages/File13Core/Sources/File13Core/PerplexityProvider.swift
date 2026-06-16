import Foundation

/// Calls Perplexity's chat completions endpoint. Their API is intentionally OpenAI-compatible —
/// same request/response shapes, different base URL.
public struct PerplexityProvider: LLMProvider {
    public let apiKey: String?
    public let model: String

    public var kind: AIProviderKind { .perplexity }
    public var displayName: String { kind.label }

    public init(apiKey: String?, model: String = AIProviderKind.perplexity.defaultModel) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? AIProviderKind.perplexity.defaultModel : model
    }

    public func availability() async -> ProviderAvailability {
        guard let apiKey, !apiKey.isEmpty else {
            return .needsSetup(message: "Add your Perplexity API key.")
        }
        _ = apiKey
        return .ready
    }

    public func generate(systemInstructions: String?, userPrompt: String, options: LLMGenerationOptions) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else {
            throw LLMProviderError.missingAPIKey(provider: kind)
        }
        let url = URL.verified("https://api.perplexity.ai/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var messages: [[String: String]] = []
        if let systemInstructions, !systemInstructions.isEmpty {
            messages.append(["role": "system", "content": systemInstructions])
        }
        messages.append(["role": "user", "content": userPrompt])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": max(0.0, min(1.0, options.temperature ?? 0.2))
        ]
        if let maxTokens = options.maxTokens {
            body["max_tokens"] = maxTokens
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await LLMURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.requestFailed(statusCode: 0, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMProviderError.requestFailed(
                statusCode: http.statusCode,
                body: LLMResponseRedactor.redact(String(data: data, encoding: .utf8))
            )
        }
        do {
            let envelope = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
            guard let content = envelope.choices.first?.message.content else {
                throw LLMProviderError.decodingFailed("No content in first choice.")
            }
            return content
        } catch let error as LLMProviderError {
            throw error
        } catch {
            throw LLMProviderError.decodingFailed(String(describing: error))
        }
    }

    private struct ChatCompletionsResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Message
        }
        struct Message: Decodable {
            let content: String
        }
    }
}
