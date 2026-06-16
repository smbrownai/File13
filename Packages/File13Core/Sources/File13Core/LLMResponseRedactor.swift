import Foundation

/// Redacts plausible API-key patterns from third-party LLM provider response
/// bodies before they get captured into error messages or logs.
///
/// Why this exists: providers' 401/403 responses routinely echo back a
/// fingerprint of the offending key — OpenAI's *"Incorrect API key provided:
/// sk-proj-***...xyz"* is the canonical example. That body lands in
/// `LLMProviderError.requestFailed(body:)`, is shown in the UI when an AI
/// action fails, and is the most-likely thing for a user to copy into a
/// support email. Partial keys + the provider's name are enough to narrow a
/// brute-force search or seed a social-engineering pass against the
/// provider's account-recovery flow.
///
/// We redact at the boundary where the body becomes an Error, not at the
/// display layer, so every downstream consumer (UI, logs, copy-paste) gets
/// the cleaned version.
public enum LLMResponseRedactor {
    private static let patterns: [NSRegularExpression] = {
        let raw = [
            // OpenAI / Anthropic / Perplexity — "sk-" prefix, optionally
            // namespaced (sk-proj-, sk-ant-, sk-or-...). Match 16+ chars of
            // the payload so we don't false-positive on prose that happens
            // to contain "sk-".
            #"sk-[A-Za-z0-9_-]{16,}"#,
            // OpenAI session/project-scoped prefixes that appear in some
            // errors.
            #"sk-proj-[A-Za-z0-9_-]{8,}"#,
            // OpenAI organization tokens.
            #"org-[A-Za-z0-9]{16,}"#,
            // Generic "pk_" prefix some providers use.
            #"pk_[A-Za-z0-9]{16,}"#,
            // Google API keys — typically `AIza` prefix + 35 chars.
            #"AIza[0-9A-Za-z_-]{30,}"#,
            // Long base64url runs (40+ chars without `=` padding) — covers
            // Bearer tokens in body text.
            #"\b[A-Za-z0-9_-]{40,}\b"#,
            // 32+ char hex runs (catches some legacy / Google formats).
            #"\b[0-9a-fA-F]{32,}\b"#
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Maximum number of characters of body text we'll keep. A pathological
    /// provider response (or attacker-controlled response if the API host
    /// is compromised) shouldn't be able to blow up an error message log
    /// just because someone left a `print` of `error.localizedDescription`
    /// in.
    public static let bodyLimit = 1024

    /// Redact and length-cap a response body. Pass `nil` through.
    public static func redact(_ body: String?) -> String? {
        guard var body, !body.isEmpty else { return body }
        if body.count > bodyLimit {
            body = String(body.prefix(bodyLimit)) + "…"
        }
        for pattern in patterns {
            let range = NSRange(body.startIndex..., in: body)
            body = pattern.stringByReplacingMatches(
                in: body,
                options: [],
                range: range,
                withTemplate: "<redacted>"
            )
        }
        return body
    }
}
