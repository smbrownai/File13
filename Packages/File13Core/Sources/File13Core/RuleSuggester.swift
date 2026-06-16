import Foundation

/// Errors surfaced to the suggestions UI.
public enum RuleSuggesterError: LocalizedError {
    case providerUnavailable(String)
    case decodingFailed(String)
    case noSenders

    public var errorDescription: String? {
        switch self {
        case .providerUnavailable(let m): return m
        case .decodingFailed(let m):      return "Couldn't parse AI response: \(m)"
        case .noSenders:                  return "No senders to analyze yet."
        }
    }
}

/// Asks the configured LLM to look at read/unread patterns and propose concrete rules.
@MainActor
public struct RuleSuggester {
    public let provider: any LLMProvider
    public var maxSuggestions: Int = 6
    public var maxSendersInPrompt: Int = 40
    /// Per-feature tuning — custom prompt suffix and generation knobs. Defaults to a no-op
    /// `AIFeatureTuning()` so existing call sites keep their current behavior without change.
    public var tuning: AIFeatureTuning = AIFeatureTuning()

    public init(provider: any LLMProvider, maxSuggestions: Int = 6, maxSendersInPrompt: Int = 40, tuning: AIFeatureTuning = AIFeatureTuning()) {
        self.provider = provider
        self.maxSuggestions = maxSuggestions
        self.maxSendersInPrompt = maxSendersInPrompt
        self.tuning = tuning
    }

    private var generationOptions: LLMGenerationOptions {
        LLMGenerationOptions(
            temperature: tuning.temperature ?? AIFeature.ruleSuggest.defaultTemperature,
            maxTokens: tuning.maxTokens ?? AIFeature.ruleSuggest.defaultMaxTokens
        )
    }

    /// Per-sender variant. Same prompt scaffolding but scoped to a single sender, so the
    /// model can reason about that sender's pattern in detail (more subjects fed in,
    /// suggestions explicitly bounded to address/domain conditions).
    public func suggest(
        forSender sender: Sender,
        existingRules: [Rule],
        categoryFor: @escaping (String) -> SenderCategory?,
        repliedMessageIds: Set<String>,
        isVIP: @escaping (String) -> Bool,
        allHeaders: [MessageHeader]
    ) async throws -> [RuleSuggestion] {
        switch await provider.availability() {
        case .ready: break
        case .needsSetup(let m), .unsupported(let m), .error(let m):
            throw RuleSuggesterError.providerUnavailable(m)
        }
        let prompt = Self.singleSenderPrompt(
            sender: sender,
            existingRules: existingRules,
            categoryFor: categoryFor,
            repliedMessageIds: repliedMessageIds,
            isVIP: isVIP
        )
        let raw = try await provider.generate(
            systemInstructions: Self.systemInstructions(custom: tuning.customInstructionsBlock),
            userPrompt: prompt,
            options: generationOptions
        )
        guard let payload = Self.extractJSONObject(from: raw) else {
            throw RuleSuggesterError.decodingFailed("No JSON object in response.")
        }
        let decoded: JSONResponse
        do {
            decoded = try JSONDecoder().decode(JSONResponse.self, from: payload)
        } catch {
            throw RuleSuggesterError.decodingFailed(String(describing: error))
        }
        return decoded.suggestions.compactMap { item in
            guard let outcome = item.outcomeValue else { return nil }
            let conditions = item.conditionsValue
            if conditions.isEmpty { return nil }
            let matches = allHeaders.lazy.filter {
                RuleEvaluator.matches($0, rule: Rule(conditions: conditions, outcome: outcome), categoryFor: categoryFor)
            }.count
            return RuleSuggestion(
                id: UUID(),
                title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                rationale: item.rationale.trimmingCharacters(in: .whitespacesAndNewlines),
                conditions: conditions,
                outcome: outcome,
                estimatedMatches: matches
            )
        }
    }

    /// Whole-inbox variant. Same picking + scoring pipeline as the bulk path,
    /// but framed for a corpus that spans every cached mailbox (not just the
    /// currently-viewed folder). The cross-mailbox prompt nudge lets the model
    /// reason about archived-but-never-read patterns and sent-folder reply
    /// evidence — signals invisible to a single-mailbox suggestion run.
    ///
    /// Callers should feed `headers` from `InboxStore.wholeInboxCorpus()`,
    /// not `inbox.allHeaders` (which is scope-filtered).
    public func suggestWholeInbox(
        senders: [Sender],
        existingRules: [Rule],
        categoryFor: @escaping (String) -> SenderCategory?,
        repliedMessageIds: Set<String>,
        isVIP: @escaping (String) -> Bool,
        allHeaders: [MessageHeader]
    ) async throws -> [RuleSuggestion] {
        guard !senders.isEmpty else { throw RuleSuggesterError.noSenders }
        switch await provider.availability() {
        case .ready: break
        case .needsSetup(let m), .unsupported(let m), .error(let m):
            throw RuleSuggesterError.providerUnavailable(m)
        }

        let nonVIPSenders = senders.filter { !isVIP($0.id) }
        let pool = pickSendersForPrompt(from: nonVIPSenders)
        let prompt = Self.wholeInboxPrompt(
            for: pool,
            existingRules: existingRules,
            categoryFor: categoryFor,
            repliedMessageIds: repliedMessageIds,
            limit: maxSuggestions
        )
        let raw = try await provider.generate(
            systemInstructions: Self.systemInstructions(custom: tuning.customInstructionsBlock),
            userPrompt: prompt,
            options: generationOptions
        )
        guard let payload = Self.extractJSONObject(from: raw) else {
            throw RuleSuggesterError.decodingFailed("No JSON object in response.")
        }
        let decoded: JSONResponse
        do {
            decoded = try JSONDecoder().decode(JSONResponse.self, from: payload)
        } catch {
            throw RuleSuggesterError.decodingFailed(String(describing: error))
        }
        return decoded.suggestions.compactMap { item in
            guard let outcome = item.outcomeValue else { return nil }
            let conditions = item.conditionsValue
            if conditions.isEmpty { return nil }
            let matches = allHeaders.lazy.filter {
                RuleEvaluator.matches($0, rule: Rule(conditions: conditions, outcome: outcome), categoryFor: categoryFor)
            }.count
            return RuleSuggestion(
                id: UUID(),
                title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                rationale: item.rationale.trimmingCharacters(in: .whitespacesAndNewlines),
                conditions: conditions,
                outcome: outcome,
                estimatedMatches: matches
            )
        }
    }

    public func suggest(
        senders: [Sender],
        existingRules: [Rule],
        categoryFor: @escaping (String) -> SenderCategory?,
        repliedMessageIds: Set<String>,
        isVIP: @escaping (String) -> Bool,
        allHeaders: [MessageHeader]
    ) async throws -> [RuleSuggestion] {
        guard !senders.isEmpty else { throw RuleSuggesterError.noSenders }
        switch await provider.availability() {
        case .ready: break
        case .needsSetup(let m), .unsupported(let m), .error(let m):
            throw RuleSuggesterError.providerUnavailable(m)
        }

        // Defense in depth: drop VIPs from the prompt pool entirely so the model never even
        // *sees* them as candidates for archive/delete. The system prompt also forbids it,
        // but a missing input is the strongest possible "don't act on this sender" signal.
        let nonVIPSenders = senders.filter { !isVIP($0.id) }
        let pool = pickSendersForPrompt(from: nonVIPSenders)
        let prompt = Self.userPrompt(
            for: pool,
            existingRules: existingRules,
            categoryFor: categoryFor,
            repliedMessageIds: repliedMessageIds,
            limit: maxSuggestions
        )
        let raw = try await provider.generate(
            systemInstructions: Self.systemInstructions(custom: tuning.customInstructionsBlock),
            userPrompt: prompt,
            options: generationOptions
        )
        guard let payload = Self.extractJSONObject(from: raw) else {
            throw RuleSuggesterError.decodingFailed("No JSON object in response.")
        }
        let decoded: JSONResponse
        do {
            decoded = try JSONDecoder().decode(JSONResponse.self, from: payload)
        } catch {
            throw RuleSuggesterError.decodingFailed(String(describing: error))
        }

        // Build typed suggestions, computing match counts locally so the preview is accurate
        // (we don't trust the model with a count it couldn't have computed).
        return decoded.suggestions.compactMap { item in
            guard let outcome = item.outcomeValue else { return nil }
            let conditions = item.conditionsValue
            // Skip empty conditions — a rule with no conditions matches everything, which is
            // never what the user wants. Treat as model error and drop.
            if conditions.isEmpty { return nil }
            let matches = allHeaders.lazy.filter {
                RuleEvaluator.matches($0, rule: Rule(conditions: conditions, outcome: outcome), categoryFor: categoryFor)
            }.count
            return RuleSuggestion(
                id: UUID(),
                title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                rationale: item.rationale.trimmingCharacters(in: .whitespacesAndNewlines),
                conditions: conditions,
                outcome: outcome,
                estimatedMatches: matches
            )
        }
    }

    // MARK: - Sender selection

    /// Pick the senders most likely to yield interesting suggestions: a mix of high-volume and
    /// low-engagement senders, deduped, capped at `maxSendersInPrompt`. We avoid sending the
    /// whole sender list because token cost grows linearly and we don't need the long tail.
    private func pickSendersForPrompt(from senders: [Sender]) -> [Sender] {
        let byVolume = senders.sorted { $0.messageCount > $1.messageCount }
        let topVolume = Array(byVolume.prefix(maxSendersInPrompt / 2))
        let lowEngagement = byVolume
            .lazy
            .filter { $0.messageCount >= 5 }
            .sorted { lhs, rhs in
                let lr = Double(lhs.unreadCount) / Double(lhs.messageCount)
                let rr = Double(rhs.unreadCount) / Double(rhs.messageCount)
                return lr > rr   // most-unread first
            }
            .prefix(maxSendersInPrompt / 2)
        var seen: Set<String> = []
        var result: [Sender] = []
        for sender in topVolume + Array(lowEngagement) {
            if seen.insert(sender.id).inserted { result.append(sender) }
            if result.count >= maxSendersInPrompt { break }
        }
        return result
    }

    // MARK: - JSON

    private struct JSONResponse: Decodable {
        let suggestions: [SuggestionDTO]

        struct SuggestionDTO: Decodable {
            let title: String
            let rationale: String
            let match: ConditionsDTO
            let outcome: String

            var outcomeValue: Rule.Outcome? {
                switch outcome.lowercased() {
                case "delete":     return .delete
                case "archive":    return .archive
                case "move":
                    guard let folder = match.moveToFolder, !folder.isEmpty else { return nil }
                    return .moveToFolder(folder)
                default:           return nil
                }
            }

            var conditionsValue: Rule.Conditions {
                var c = Rule.Conditions()
                if let s = match.fromAddressOrDomain, !s.isEmpty { c.fromAddressOrDomain = s }
                if let s = match.subjectContains,    !s.isEmpty { c.subjectContains = s }
                if let n = match.olderThanDays,      n > 0      { c.olderThanDays = n }
                c.isUnread = match.isUnread
                if let raw = match.category, let cat = SenderCategory(rawValue: raw.lowercased()) {
                    c.category = cat
                }
                return c
            }
        }

        struct ConditionsDTO: Decodable {
            let fromAddressOrDomain: String?
            let subjectContains: String?
            let olderThanDays: Int?
            let isUnread: Bool?
            let category: String?
            let moveToFolder: String?
        }
    }

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

    /// Body of the system prompt — context and hard rules — without the JSON schema clause.
    /// Split out so per-feature `customInstructions` can be spliced between the rules and the
    /// schema, keeping the schema as the final, last-thing-the-model-reads instruction.
    private static let instructionsBody: String = """
    You suggest inbox-cleanup rules for a metadata-only email triage app. You see sender \
    addresses, names, message counts, read rates, *reply counts*, AI-assigned categories, \
    a "VIP" flag, and small samples of subjects. You never see message bodies. Suggest \
    concrete, conservative rules a user would plausibly accept.

    Hard rules:
    - NEVER propose archive, delete, or move for a sender flagged VIP. VIPs are senders the \
      user actively engages with — touching them violates trust. Skip them entirely.
    - Reply count is the strongest engagement signal. If the user has replied even once to \
      a sender, do NOT propose destructive actions for that sender.
    - Suggest only rules where the user's behavior is clear (read rate, reply count, volume, recency).
    - Do NOT suggest rules that affect transactional senders (banking, receipts, shipping).
    - Do NOT duplicate rules that already exist (the user's existing rules are listed).
    - Skip personal or work senders unless the pattern is overwhelming.
    - Prefer "archive" over "delete". Use "delete" only for clear promotional/social noise \
      with zero replies and near-zero read rate.
    - Each suggestion must reference a specific signal in the rationale (e.g. "0% read and \
      0 replies across 142 messages" or "Promotional + unread + older than 30 days").
    """

    private static let schemaClause: String = {
        let categories = SenderCategory.allCases.map(\.rawValue).joined(separator: ", ")
        return """
        Output strict JSON only, no other text. Schema:
        {
          "suggestions": [
            {
              "title": "Short rule title (≤ 6 words)",
              "rationale": "1–2 sentences citing the metric that justifies the rule",
              "outcome": "archive" | "delete" | "move",
              "match": {
                "fromAddressOrDomain": null | "<address or domain>",
                "subjectContains":    null | "<keyword>",
                "olderThanDays":      null | <positive integer>,
                "isUnread":           null | true | false,
                "category":           null | "<one of: \(categories)>",
                "moveToFolder":       null | "<destination folder name>"
              }
            }
          ]
        }

        Use null for any condition that doesn't apply. At least one condition per suggestion \
        must be non-null. `moveToFolder` is only used when `outcome` is "move". `category` is \
        more powerful than per-sender rules — prefer it when the user's read pattern is \
        consistent across an entire AI category.
        """
    }()

    /// Compose the system prompt with the user's optional suffix between the rules body and
    /// the schema clause. `custom` is expected to already be wrapped (use
    /// `AIFeatureTuning.customInstructionsBlock`) — empty string contributes nothing.
    ///
    /// Appends `AIPromptFence.systemClause` so the model treats fenced
    /// sender data in the user prompt as untrusted input, never as
    /// instructions. RuleSuggester is the highest-stakes injection target
    /// — a successful injection here could induce the model to suggest
    /// rules that protect the attacker themselves. Custom instructions
    /// are followed by `postCustomReinforcement` so a tampered-with
    /// custom block can't soften the fence rules.
    private static func systemInstructions(custom: String) -> String {
        let suffix = custom.isEmpty
            ? ""
            : "\(custom)\n\(AIPromptFence.postCustomReinforcement)\n"
        return "\(instructionsBody)\(suffix)\n\n\(schemaClause)\n\n\(AIPromptFence.systemClause)"
    }

    private static func singleSenderPrompt(
        sender: Sender,
        existingRules: [Rule],
        categoryFor: @escaping (String) -> SenderCategory?,
        repliedMessageIds: Set<String>,
        isVIP: @escaping (String) -> Bool
    ) -> String {
        var lines: [String] = []
        lines.append("Suggest 1–3 rules specifically about this sender. Conditions must include `fromAddressOrDomain` so the rule is scoped to them.")
        lines.append("")
        if !existingRules.isEmpty {
            lines.append("Existing rules (do not duplicate):")
            for rule in existingRules {
                lines.append("- \(rule.outcome.label) — \(rule.conditions.summary)")
            }
            lines.append("")
        }
        let read = sender.messageCount - sender.unreadCount
        let pct = sender.messageCount > 0
            ? Int((Double(read) / Double(sender.messageCount)) * 100)
            : 0
        let replyCount = sender.messages.lazy.filter {
            repliedMessageIds.contains($0.rawMessageId)
        }.count
        // Strip fence markers so a hostile sender can't paste in our own
        // closing token to escape the untrusted-data region.
        let safeName = AIPromptFence.stripMarkers(sender.name)
        let safeAddress = AIPromptFence.stripMarkers(sender.address)
        lines.append(AIPromptFence.begin)
        lines.append("Sender: <\(safeAddress)> \"\(safeName.isEmpty ? safeAddress : safeName)\"")
        lines.append("Stats: count=\(sender.messageCount), readRate=\(pct)%, replies=\(replyCount)")
        if let category = categoryFor(sender.id) {
            lines.append("Category: \(category.rawValue)")
        }
        var signals: [String] = []
        if isVIP(sender.id)                  { signals.append("VIP") }
        if sender.isLikelyNewsletter         { signals.append("newsletter") }
        if sender.unsubscribeAnchor != nil   { signals.append("unsubscribable") }
        if !signals.isEmpty { lines.append("Signals: \(signals.joined(separator: ", "))") }
        let subjects = sender.messages.prefix(8)
            .map { $0.subject.isEmpty ? "(no subject)" : $0.subject }
        if !subjects.isEmpty {
            lines.append("Recent subjects:")
            for subject in subjects {
                lines.append("- \(AIPromptFence.stripMarkers(subject))")
            }
        }
        lines.append(AIPromptFence.end)
        return lines.joined(separator: "\n")
    }

    /// Variant of `userPrompt` that prefaces the sender table with a note
    /// telling the model the corpus spans every cached mailbox — archive,
    /// sent, and custom folders included. Same sender encoding; the framing
    /// is what changes what the model proposes.
    private static func wholeInboxPrompt(
        for senders: [Sender],
        existingRules: [Rule],
        categoryFor: @escaping (String) -> SenderCategory?,
        repliedMessageIds: Set<String>,
        limit: Int
    ) -> String {
        let body = userPrompt(
            for: senders,
            existingRules: existingRules,
            categoryFor: categoryFor,
            repliedMessageIds: repliedMessageIds,
            limit: limit
        )
        let preface = """
        Scope: this is a WHOLE-INBOX run. The senders below were aggregated \
        across every cached mailbox the user has — Inbox, Archive, Sent, and \
        any custom folders. Counts, read rates, and reply counts therefore \
        reflect cross-folder behavior, not just what's currently in the \
        Inbox view. Prefer rules whose evidence is strongest given that \
        wider picture (for example: senders the user consistently archives \
        unread are stronger candidates than they'd look in a single-folder run).

        """
        return preface + body
    }

    private static func userPrompt(
        for senders: [Sender],
        existingRules: [Rule],
        categoryFor: @escaping (String) -> SenderCategory?,
        repliedMessageIds: Set<String>,
        limit: Int
    ) -> String {
        var lines: [String] = []
        lines.append("Suggest up to \(limit) rules.")
        lines.append("")

        // Existing rules — protect against duplicates.
        if !existingRules.isEmpty {
            lines.append("Existing rules (do not duplicate):")
            for rule in existingRules {
                lines.append("- \(rule.outcome.label) — \(rule.conditions.summary)")
            }
            lines.append("")
        }

        // Sender table. VIPs were filtered out before this point — no need to include or
        // mention them; they're simply not candidates.
        //
        // Every sender-controlled field below is stripped of fence markers
        // and wrapped in `AIPromptFence.begin`/`end`. See `AIPromptFence`.
        lines.append("Senders:")
        lines.append(AIPromptFence.begin)
        for sender in senders {
            let read = sender.messageCount - sender.unreadCount
            let pct = sender.messageCount > 0
                ? Int((Double(read) / Double(sender.messageCount)) * 100)
                : 0
            let replyCount = sender.messages.lazy.filter {
                repliedMessageIds.contains($0.rawMessageId)
            }.count
            var fields: [String] = []
            fields.append("count=\(sender.messageCount)")
            fields.append("readRate=\(pct)%")
            fields.append("replies=\(replyCount)")
            if let category = categoryFor(sender.id) {
                fields.append("category=\(category.rawValue)")
            }
            if sender.isLikelyNewsletter { fields.append("newsletter") }
            if sender.unsubscribeAnchor != nil { fields.append("unsubscribable") }
            // Most-recent-first by `groupedBySender()`.
            let subjectSample = sender.messages.prefix(2)
                .map { AIPromptFence.stripMarkers($0.subject.isEmpty ? "(no subject)" : $0.subject) }
                .joined(separator: " | ")
            let safeName = AIPromptFence.stripMarkers(sender.name)
            let safeAddress = AIPromptFence.stripMarkers(sender.address)
            lines.append("- <\(safeAddress)> \"\(safeName.isEmpty ? safeAddress : safeName)\" — \(fields.joined(separator: ", "))")
            if !subjectSample.isEmpty {
                lines.append("    subjects: \(subjectSample)")
            }
        }
        lines.append(AIPromptFence.end)

        return lines.joined(separator: "\n")
    }
}
