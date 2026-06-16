import Foundation

/// Calls Anthropic's Messages API (RFC: https://docs.anthropic.com/en/api/messages) with the
/// user's API key. System prompts go in the top-level `system` field, not in messages.
public struct AnthropicProvider: LLMProvider {
    public let apiKey: String?
    public let model: String

    public var kind: AIProviderKind { .anthropic }
    public var displayName: String { kind.label }

    public init(apiKey: String?, model: String = AIProviderKind.anthropic.defaultModel) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? AIProviderKind.anthropic.defaultModel : model
    }

    public func availability() async -> ProviderAvailability {
        guard let apiKey, !apiKey.isEmpty else {
            return .needsSetup(message: "Add your Anthropic API key.")
        }
        _ = apiKey
        return .ready
    }

    public func generate(systemInstructions: String?, userPrompt: String, options: LLMGenerationOptions) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else {
            throw LLMProviderError.missingAPIKey(provider: kind)
        }
        let url = URL.verified("https://api.anthropic.com/v1/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        // Anthropic requires `max_tokens`; preserve the existing 1024 default when the caller
        // hasn't overridden. Temperature is optional and only goes on the request when set.
        var body: [String: Any] = [
            "model": model,
            "max_tokens": options.maxTokens ?? 1024,
            "messages": [["role": "user", "content": userPrompt]]
        ]
        if let temperature = options.temperature {
            body["temperature"] = max(0.0, min(1.0, temperature))
        }
        if let systemInstructions, !systemInstructions.isEmpty {
            body["system"] = systemInstructions
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
            let envelope = try JSONDecoder().decode(MessagesResponse.self, from: data)
            // Concatenate all text-typed content blocks.
            let text = envelope.content
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined(separator: "\n")
            guard !text.isEmpty else {
                throw LLMProviderError.decodingFailed("No text content in Anthropic response.")
            }
            return text
        } catch let error as LLMProviderError {
            throw error
        } catch {
            throw LLMProviderError.decodingFailed(String(describing: error))
        }
    }

    private struct MessagesResponse: Decodable {
        let content: [Block]
        struct Block: Decodable {
            let type: String
            let text: String?
        }
    }
}
