import Foundation

/// One sender's categorization result, indexed by lowercased address.
public struct SenderCategoryResult: Hashable, Sendable {
    public let senderId: String
    public let category: SenderCategory
    public init(senderId: String, category: SenderCategory) {
        self.senderId = senderId
        self.category = category
    }
}

/// Errors surfaced by `SenderCategorizer` so the UI can show the right message.
public enum SenderCategorizerError: LocalizedError {
    case providerUnavailable(String)
    case decodingFailed(String)
    case allBatchesFailed(String)

    public var errorDescription: String? {
        switch self {
        case .providerUnavailable(let m): return m
        case .decodingFailed(let m):      return "Couldn't parse AI response: \(m)"
        case .allBatchesFailed(let m):    return "Categorization failed: \(m)"
        }
    }
}

/// Calls the user's chosen LLM to bulk-categorize senders. Senders are batched (~25 per
/// request) so we make a small number of calls instead of one per sender, which matters both
/// for cost and for staying inside reasonable response sizes.
@MainActor
public struct SenderCategorizer {
    public let provider: any LLMProvider
    public var batchSize: Int = 25
    /// Per-feature tuning — custom prompt suffix and generation knobs. Defaults to a no-op
    /// `AIFeatureTuning()` so existing call sites keep their current behavior without change.
    public var tuning: AIFeatureTuning = AIFeatureTuning()

    public init(provider: any LLMProvider, batchSize: Int = 25, tuning: AIFeatureTuning = AIFeatureTuning()) {
        self.provider = provider
        self.batchSize = batchSize
        self.tuning = tuning
    }

    private var generationOptions: LLMGenerationOptions {
        LLMGenerationOptions(
            temperature: tuning.temperature ?? AIFeature.senderCategorize.defaultTemperature,
            maxTokens: tuning.maxTokens ?? AIFeature.senderCategorize.defaultMaxTokens
        )
    }

    /// Classify the given senders, returning `(map, errors)`. Partial success is the norm:
    /// if one batch fails we still apply the categorizations from the batches that succeeded.
    public func categorize(
        _ senders: [Sender],
        progress: ((_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> (results: [String: SenderCategory], errors: [Error]) {
        guard !senders.isEmpty else { return ([:], []) }
        switch await provider.availability() {
        case .ready: break
        case .needsSetup(let m), .unsupported(let m), .error(let m):
            throw SenderCategorizerError.providerUnavailable(m)
        }

        var combined: [String: SenderCategory] = [:]
        var errors: [Error] = []
        let batches = senders.chunked(into: batchSize)
        var completed = 0

        for batch in batches {
            do {
                let batchResults = try await categorizeBatch(batch)
                for (k, v) in batchResults { combined[k] = v }
            } catch {
                errors.append(error)
            }
            completed += batch.count
            progress?(completed, senders.count)
        }

        if combined.isEmpty, let first = errors.first {
            throw SenderCategorizerError.allBatchesFailed(first.localizedDescription)
        }
        return (combined, errors)
    }

    // MARK: - Batch dispatch

    private func categorizeBatch(_ batch: [Sender]) async throws -> [String: SenderCategory] {
        let raw = try await provider.generate(
            systemInstructions: Self.systemInstructions(custom: tuning.customInstructionsBlock),
            userPrompt: Self.userPrompt(for: batch),
            options: generationOptions
        )
        guard let payload = Self.extractJSONObject(from: raw) else {
            throw SenderCategorizerError.decodingFailed("No JSON object in response.")
        }
        let decoded: JSONResponse
        do {
            decoded = try JSONDecoder().decode(JSONResponse.self, from: payload)
        } catch {
            throw SenderCategorizerError.decodingFailed(String(describing: error))
        }

        // Map back to lowercased addresses, dropping any ids the LLM hallucinated that we
        // didn't ask about — that protects the cache from junk and keeps us aligned with the
        // canonical sender keys used by `SenderCategoryStore`.
        let validIds = Set(batch.map { $0.id })
        var out: [String: SenderCategory] = [:]
        for assignment in decoded.assignments {
            let key = assignment.id.lowercased()
            guard validIds.contains(key),
                  let category = SenderCategory(rawValue: assignment.category.lowercased()) else {
                continue
            }
            out[key] = category
        }
        return out
    }

    // MARK: - JSON

    private struct JSONResponse: Decodable {
        let assignments: [Assignment]

        struct Assignment: Decodable {
            let id: String
            let category: String
        }
    }

    /// Some providers wrap JSON in markdown code fences or chat-prefix text. Pick out the first
    /// `{ … }` substring that parses, mirroring `SenderAdvisor.extractJSONObject`.
    private static func extractJSONObject(from raw: String) -> Data? {
        if let opening = raw.range(of: "{"),
           let closing = raw.range(of: "}", options: .backwards),
           opening.lowerBound < closing.lowerBound {
            let candidate = raw[opening.lowerBound...closing.lowerBound]
            return candidate.data(using: .utf8)
        }
        return raw.data(using: .utf8)
    }

    // MARK: - Prompts

    /// Body of the system prompt — rules + category list — without the JSON schema clause.
    /// Split out so per-feature `customInstructions` can be spliced between the rules and the
    /// schema, keeping the schema as the final, last-thing-the-model-reads instruction.
    private static let instructionsBody: String = {
        var lines: [String] = [
            """
            You categorize email senders for an inbox-triage app. You work from sender metadata only — \
            address, display name, and a few representative subjects. You never see message bodies.

            Pick exactly one category per sender from the list below. Be conservative: prefer "other" \
            over guessing. Use the category hints to disambiguate borderline cases.
            """,
            "",
            "Categories:"
        ]
        for category in SenderCategory.allCases {
            lines.append("- \(category.rawValue): \(category.promptHint)")
        }
        return lines.joined(separator: "\n")
    }()

    private static let schemaClause: String = """
    Respond with strict JSON only, no other text. Schema:
    {
      "assignments": [
        { "id": "<sender id from the prompt>", "category": "<one of: \(SenderCategory.allCases.map(\.rawValue).joined(separator: ", "))>" }
      ]
    }

    Include one entry per sender in the prompt. Do not invent ids that weren't asked about.
    """

    /// Compose the system prompt with the user's optional suffix between the rules body and
    /// the schema clause. `custom` is expected to already be wrapped (use
    /// `AIFeatureTuning.customInstructionsBlock`) — empty string contributes nothing.
    ///
    /// Appends `AIPromptFence.systemClause` so the model treats every
    /// sender field in `userPrompt` as untrusted data, never as an
    /// instruction. See `AIPromptFence` for the rationale.
    ///
    /// The user's `custom` block — when non-empty — is followed
    /// immediately by `AIPromptFence.postCustomReinforcement`, a short
    /// note that pins the data-handling rules as absolute even if the
    /// custom block tries to relax them. Necessary because customInstructions
    /// can be supplied by an iCloud-syncing attacker (mitigated by the
    /// per-device confirm flow) or written carelessly by the user.
    private static func systemInstructions(custom: String) -> String {
        let suffix = custom.isEmpty
            ? ""
            : "\(custom)\n\(AIPromptFence.postCustomReinforcement)\n"
        return "\(instructionsBody)\(suffix)\n\n\(schemaClause)\n\n\(AIPromptFence.systemClause)"
    }

    private static func userPrompt(for senders: [Sender]) -> String {
        var lines: [String] = [
            "Senders to categorize:",
            "",
            AIPromptFence.begin
        ]
        for sender in senders {
            // Strip both fence markers from sender-controlled fields so a
            // hostile sender can't paste in our own closing token and
            // smuggle their own pseudo-instructions out of the fenced
            // region. Then JSON-quote-escape so `"foo": "<value>"` stays
            // well-formed for the line-yaml format below.
            let safeName = AIPromptFence.stripMarkers(sender.name.isEmpty ? sender.address : sender.name)
            let safeAddress = AIPromptFence.stripMarkers(sender.address)
            lines.append("- id: \"\(escapeYAML(sender.id))\"")
            lines.append("  name: \"\(escapeYAML(safeName))\"")
            lines.append("  address: \"\(escapeYAML(safeAddress))\"")
            // 3 most-recent subjects keeps the prompt short while giving the model real signal.
            // Already pre-sorted newest-first by `groupedBySender()`.
            let subjects = sender.messages.prefix(3).map { $0.subject.isEmpty ? "(no subject)" : $0.subject }
            if !subjects.isEmpty {
                lines.append("  subjects:")
                for subject in subjects {
                    let safe = AIPromptFence.stripMarkers(subject)
                    lines.append("    - \"\(escapeYAML(safe))\"")
                }
            }
            if sender.isLikelyNewsletter {
                lines.append("  signals: list-unsubscribe / list-id / auto-submitted")
            }
        }
        lines.append(AIPromptFence.end)
        return lines.joined(separator: "\n")
    }

    private static func escapeYAML(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
