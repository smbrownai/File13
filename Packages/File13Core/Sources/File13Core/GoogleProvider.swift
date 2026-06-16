import Foundation

/// Calls the Google Gemini Generative Language API. The API key goes on the URL as a query
/// parameter, the system prompt is its own top-level field, and request/response use a
/// `contents → parts → text` shape.
public struct GoogleProvider: LLMProvider {
    public let apiKey: String?
    public let model: String

    public var kind: AIProviderKind { .google }
    public var displayName: String { kind.label }

    public init(apiKey: String?, model: String = AIProviderKind.google.defaultModel) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? AIProviderKind.google.defaultModel : model
    }

    public func availability() async -> ProviderAvailability {
        guard let apiKey, !apiKey.isEmpty else {
            return .needsSetup(message: "Add your Google AI Studio API key.")
        }
        _ = apiKey
        return .ready
    }

    public func generate(systemInstructions: String?, userPrompt: String, options: LLMGenerationOptions) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else {
            throw LLMProviderError.missingAPIKey(provider: kind)
        }
        // Model name is interpolated into the URL **path**, not the body —
        // so unlike the other providers, a maliciously-crafted model
        // string (e.g. from a syncing iCloud compromise) can break or
        // re-target the request. Restrict to the conservative character
        // set Google actually uses in model identifiers: letters, digits,
        // dot, dash, underscore. Anything else is a configuration error
        // (or an attack) and we refuse rather than ship the request.
        guard Self.isValidModelIdentifier(model) else {
            throw LLMProviderError.requestFailed(
                statusCode: 0,
                body: "Invalid model identifier — only letters, digits, '.', '-', and '_' are allowed."
            )
        }
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw LLMProviderError.requestFailed(statusCode: 0, body: "Couldn't build request URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": [["text": userPrompt]]]
            ]
        ]
        if let systemInstructions, !systemInstructions.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemInstructions]]]
        }
        var generationConfig: [String: Any] = [:]
        if let temperature = options.temperature {
            generationConfig["temperature"] = max(0.0, min(1.0, temperature))
        }
        if let maxTokens = options.maxTokens {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if !generationConfig.isEmpty {
            body["generationConfig"] = generationConfig
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
            let envelope = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
            // Pick the first candidate's first text part. Gemini can emit multiple parts
            // (function calls, inline data, etc.) — we want the plain text.
            guard let text = envelope.candidates.first?.content.parts
                    .compactMap(\.text)
                    .joined(separator: "\n"),
                  !text.isEmpty else {
                throw LLMProviderError.decodingFailed("No text content in Gemini response.")
            }
            return text
        } catch let error as LLMProviderError {
            throw error
        } catch {
            throw LLMProviderError.decodingFailed(String(describing: error))
        }
    }

    private struct GenerateContentResponse: Decodable {
        let candidates: [Candidate]
        struct Candidate: Decodable {
            let content: Content
        }
        struct Content: Decodable {
            let parts: [Part]
        }
        struct Part: Decodable {
            let text: String?
        }
    }

    /// Conservative allowlist of characters legitimate Google model
    /// identifiers ever contain. Rejecting anything else stops a synced
    /// (or careless) `modelOverride` value from path-traversing
    /// (`../../`), opening a query string (`?key=other`), starting a URL
    /// fragment (`#…`), or otherwise re-shaping the request URL away
    /// from the `models/<name>:generateContent` form Google expects.
    static func isValidModelIdentifier(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let isLetter = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            let isDigit = v >= 0x30 && v <= 0x39
            let isAllowedPunct = v == 0x2D /* - */ || v == 0x2E /* . */ || v == 0x5F /* _ */
            if !(isLetter || isDigit || isAllowedPunct) {
                return false
            }
        }
        return true
    }
}
