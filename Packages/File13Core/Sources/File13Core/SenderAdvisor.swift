import Foundation
import FoundationModels
import SwiftUI

/// A compact, privacy-friendly summary of one sender's mail behavior. Built from cached metadata
/// only — never any body content. Fed to the LLM as input.
public struct SenderProfile: Sendable {
    public let senderName: String
    public let senderAddress: String
    public let messageCount: Int
    public let unreadCount: Int
    public let oldestDate: Date?
    public let newestDate: Date?
    public let topSubjects: [String]
    public let isLikelyNewsletter: Bool
    public let isAutoSubmitted: Bool
    public let hasUnsubscribeLink: Bool
    public let hasTransactional: Bool

    public init(senderName: String, senderAddress: String, messageCount: Int, unreadCount: Int,
                oldestDate: Date?, newestDate: Date?, topSubjects: [String],
                isLikelyNewsletter: Bool, isAutoSubmitted: Bool, hasUnsubscribeLink: Bool, hasTransactional: Bool) {
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.oldestDate = oldestDate
        self.newestDate = newestDate
        self.topSubjects = topSubjects
        self.isLikelyNewsletter = isLikelyNewsletter
        self.isAutoSubmitted = isAutoSubmitted
        self.hasUnsubscribeLink = hasUnsubscribeLink
        self.hasTransactional = hasTransactional
    }
}

/// What the model decided about a sender. Translated into a real action the user can apply.
public struct SenderAdvice: Hashable, Sendable, Identifiable {
    public let senderId: String
    public let action: ActionKind
    public let summary: String
    public let rationale: String
    public let suitableForRule: Bool

    public var id: String { senderId }

    public init(senderId: String, action: ActionKind, summary: String, rationale: String, suitableForRule: Bool) {
        self.senderId = senderId
        self.action = action
        self.summary = summary
        self.rationale = rationale
        self.suitableForRule = suitableForRule
    }

    public enum ActionKind: String, Hashable, Sendable {
        case keep, archive, delete, unsubscribe

        public var label: String {
            switch self {
            case .keep:        "Keep"
            case .archive:     "Archive all"
            case .delete:      "Delete all"
            case .unsubscribe: "Unsubscribe"
            }
        }

        public var symbol: String {
            switch self {
            case .keep:        "tray"
            case .archive:     "archivebox"
            case .delete:      "trash"
            case .unsubscribe: "envelope.badge.shield.half.filled"
            }
        }

        public var color: SwiftUI.Color {
            switch self {
            case .keep:        .secondary
            case .archive:     .blue
            case .delete:      .red
            case .unsubscribe: .orange
            }
        }
    }
}

/// Generable mirror of `SenderAdvice` used only on the Apple Foundation Models path. Apple's
/// structured-generation produces this directly without prompt-time JSON discipline.
@Generable(description: "An inbox-triage decision about one sender, based only on metadata.")
private struct SenderAdviceGenerable {
    @Guide(description: "1–2 sentence description of what this sender typically sends, written as a direct observation to the user.")
    let summary: String

    @Guide(description: "Recommended one-time action for the existing messages from this sender. One of: keep, archive, delete, unsubscribe.")
    let action: String

    @Guide(description: "1 sentence reason for the action. Concrete, references the volume / read rate / newsletter signal where appropriate.")
    let rationale: String

    @Guide(description: "Whether the same action also makes sense as an ongoing automatic rule for future mail from this sender.")
    let suitableForRule: Bool
}

/// Builds and dispatches per-sender prompts to the configured LLM. Two backends share one prompt
/// template: Apple uses structured generation; HTTP providers get the JSON request and we parse.
@MainActor
public struct SenderAdvisor {
    public let provider: any LLMProvider
    /// Per-feature tuning — custom prompt suffix and generation knobs. Defaults to a no-op
    /// `AIFeatureTuning()` so existing call sites keep their current behavior without change.
    public var tuning: AIFeatureTuning = AIFeatureTuning()

    public init(provider: any LLMProvider, tuning: AIFeatureTuning = AIFeatureTuning()) {
        self.provider = provider
        self.tuning = tuning
    }

    private var generationOptions: LLMGenerationOptions {
        LLMGenerationOptions(
            temperature: tuning.temperature ?? AIFeature.senderAdvice.defaultTemperature,
            maxTokens: tuning.maxTokens ?? AIFeature.senderAdvice.defaultMaxTokens
        )
    }

    private var resolvedSystemInstructions: String {
        // Append the prompt-injection-defense clauses. Sender names and
        // subjects in the user prompt are wrapped in fence markers; the
        // system clause tells the model anything between those markers
        // is data, not instructions. When the user has supplied custom
        // instructions, a `postCustomReinforcement` reminder sits
        // between the custom block and the system clause so a tampered-
        // with custom block can't relax the data-handling rules.
        let custom = tuning.customInstructionsBlock
        let reinforcement = custom.isEmpty ? "" : "\n\(AIPromptFence.postCustomReinforcement)"
        return Self.systemInstructions + custom + reinforcement + "\n\n" + AIPromptFence.systemClause
    }

    public func analyze(_ profile: SenderProfile) async throws -> SenderAdvice {
        if let apple = provider as? AppleFoundationModelsProvider {
            return try await analyzeWithApple(apple, profile: profile)
        }
        return try await analyzeWithJSON(profile: profile)
    }

    // MARK: Apple structured path

    private func analyzeWithApple(
        _ provider: AppleFoundationModelsProvider,
        profile: SenderProfile
    ) async throws -> SenderAdvice {
        switch await provider.availability() {
        case .ready: break
        case .needsSetup(let m), .unsupported(let m), .error(let m):
            throw LLMProviderError.unsupported(message: m)
        }
        let session = LanguageModelSession {
            resolvedSystemInstructions
        }
        let userPrompt = Self.userPrompt(for: profile)
        let response: LanguageModelSession.Response<SenderAdviceGenerable>
        do {
            if let appleOptions = AppleFoundationModelsProvider.generationOptions(from: generationOptions) {
                response = try await session.respond(
                    to: Prompt(userPrompt),
                    generating: SenderAdviceGenerable.self,
                    options: appleOptions
                )
            } else {
                response = try await session.respond(
                    to: Prompt(userPrompt),
                    generating: SenderAdviceGenerable.self
                )
            }
        } catch {
            throw LLMProviderError.unsupported(message: AppleFoundationModelsProvider.friendlyMessage(for: error))
        }
        return Self.materialize(response.content, senderId: profile.senderAddress.lowercased())
    }

    // MARK: HTTP / JSON path

    private func analyzeWithJSON(profile: SenderProfile) async throws -> SenderAdvice {
        let prompt = Self.userPrompt(for: profile) + "\n\n" + Self.jsonResponseClause
        let raw = try await provider.generate(
            systemInstructions: resolvedSystemInstructions,
            userPrompt: prompt,
            options: generationOptions
        )
        guard let payload = Self.extractJSONObject(from: raw) else {
            throw LLMProviderError.decodingFailed("No JSON object found in response.")
        }
        do {
            let decoded = try JSONDecoder().decode(JSONResponse.self, from: payload)
            return SenderAdvice(
                senderId: profile.senderAddress.lowercased(),
                action: decoded.actionKind,
                summary: decoded.summary,
                rationale: decoded.rationale,
                suitableForRule: decoded.suitableForRule
            )
        } catch {
            throw LLMProviderError.decodingFailed(String(describing: error))
        }
    }

    private struct JSONResponse: Decodable {
        let summary: String
        let action: String
        let rationale: String
        let suitableForRule: Bool

        var actionKind: SenderAdvice.ActionKind {
            SenderAdvice.ActionKind(rawValue: action.lowercased()) ?? .keep
        }
    }

    /// Some providers wrap the JSON in markdown code fences or chat-prefix text. Pick out the
    /// first `{ … }` substring that parses.
    private static func extractJSONObject(from raw: String) -> Data? {
        if let range = raw.range(of: "{", options: []),
           let closing = raw.range(of: "}", options: .backwards) {
            let candidate = raw[range.lowerBound...closing.lowerBound]
            if let data = candidate.data(using: .utf8) { return data }
        }
        return raw.data(using: .utf8)
    }

    // MARK: Prompts (shared)

    private static let systemInstructions = """
    You are a concise inbox triage assistant. Given metadata about one sender, recommend a \
    single one-time action for the user's existing messages from that sender, and decide whether \
    the same action should run automatically going forward. Use only the metadata supplied — you \
    have no body content. Default to "keep" when uncertain.

    Allowed actions:
    - keep: leave the sender's mail alone.
    - archive: move the sender's existing mail out of the inbox to Archive.
    - delete: permanently remove the sender's existing mail.
    - unsubscribe: stop the sender via the List-Unsubscribe link, then archive existing mail.

    Be direct and specific. No filler. No emoji.
    """

    private static let jsonResponseClause = """
    Respond with strict JSON only, no other text. Schema:
    {
      "summary": "1-2 sentences",
      "action": "keep" | "archive" | "delete" | "unsubscribe",
      "rationale": "1 sentence",
      "suitableForRule": true | false
    }
    """

    private static func userPrompt(for profile: SenderProfile) -> String {
        let interval: String
        if let oldest = profile.oldestDate, let newest = profile.newestDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            interval = "\(formatter.string(from: oldest)) → \(formatter.string(from: newest))"
        } else {
            interval = "unknown"
        }
        let readRate: String
        if profile.messageCount > 0 {
            let read = profile.messageCount - profile.unreadCount
            let percent = Int((Double(read) / Double(profile.messageCount)) * 100)
            readRate = "\(percent)%"
        } else {
            readRate = "n/a"
        }

        // Strip the fence markers from every sender-controlled field so an
        // attacker can't smuggle our own closing token into their name or
        // subject to escape the untrusted-data region.
        let safeName = AIPromptFence.stripMarkers(profile.senderName)
        let safeAddress = AIPromptFence.stripMarkers(profile.senderAddress)

        var lines: [String] = []
        lines.append(AIPromptFence.begin)
        lines.append("Sender: \(safeName.isEmpty ? safeAddress : safeName) <\(safeAddress)>")
        lines.append("Volume: \(profile.messageCount.formatted()) messages over \(interval) — read rate \(readRate), \(profile.unreadCount.formatted()) unread")
        if !profile.topSubjects.isEmpty {
            lines.append("Common subjects:")
            for subject in profile.topSubjects.prefix(8) {
                lines.append("- \(AIPromptFence.stripMarkers(subject))")
            }
        }
        var signals: [String] = []
        if profile.isLikelyNewsletter      { signals.append("newsletter (List-Unsubscribe / List-ID / Auto-Submitted)") }
        if profile.hasTransactional        { signals.append("looks transactional (receipts/invoices)") }
        if profile.hasUnsubscribeLink      { signals.append("List-Unsubscribe present") }
        if !signals.isEmpty                { lines.append("Signals: \(signals.joined(separator: "; "))") }
        lines.append(AIPromptFence.end)

        return lines.joined(separator: "\n")
    }

    private static func materialize(_ generable: SenderAdviceGenerable, senderId: String) -> SenderAdvice {
        SenderAdvice(
            senderId: senderId,
            action: SenderAdvice.ActionKind(rawValue: generable.action.lowercased()) ?? .keep,
            summary: generable.summary,
            rationale: generable.rationale,
            suitableForRule: generable.suitableForRule
        )
    }
}

extension Sender {
    /// Build the metadata profile we ship to the AI for analysis. Only metadata; no body content.
    public func makeProfile(transactionalCutoff: Int = 1) -> SenderProfile {
        let oldest = messages.map(\.date).min()
        let newest = messages.map(\.date).max()
        let unread = unreadCount
        let topSubjects = Self.topSubjectPatterns(messages: messages)
        let listUnsubscribeCount = messages.lazy.filter { $0.listUnsubscribe != nil }.count
        let autoSubmittedCount = messages.lazy.filter { $0.isAutoSubmitted }.count
        let transactionalCount = messages.lazy.filter { $0.isLikelyTransactional }.count
        return SenderProfile(
            senderName: name,
            senderAddress: address,
            messageCount: messageCount,
            unreadCount: unread,
            oldestDate: oldest,
            newestDate: newest,
            topSubjects: topSubjects,
            isLikelyNewsletter: isLikelyNewsletter,
            isAutoSubmitted: autoSubmittedCount > 0,
            hasUnsubscribeLink: listUnsubscribeCount > 0,
            hasTransactional: transactionalCount >= transactionalCutoff
        )
    }

    private static func topSubjectPatterns(messages: [MessageHeader]) -> [String] {
        var counts: [String: Int] = [:]
        for message in messages {
            let canonical = SubjectNormalizer.canonical(message.subject)
            guard !canonical.isEmpty else { continue }
            counts[canonical, default: 0] += 1
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { $0.key }
    }
}
