import FoundationModels
import Foundation

/// On-device LLM via Apple's FoundationModels framework. No API key, no third-party network
/// traffic — prompts run on the device's Apple Intelligence model (or, for hard requests, via
/// Apple's Private Cloud Compute).
public struct AppleFoundationModelsProvider: LLMProvider {
    public init() {}

    public var kind: AIProviderKind { .appleFoundation }
    public var displayName: String { kind.label }

    public func availability() async -> ProviderAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unsupported(message: "This Mac doesn't support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .needsSetup(message: "Apple Intelligence isn't enabled. Turn it on in System Settings → Apple Intelligence & Siri, then come back here.")
            case .modelNotReady:
                return .needsSetup(message: "Apple Intelligence is still downloading. Try again in a few minutes.")
            @unknown default:
                return .unsupported(message: "Apple Intelligence is unavailable on this Mac.")
            }
        }
    }

    public func generate(systemInstructions: String?, userPrompt: String, options: LLMGenerationOptions) async throws -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                throw LLMProviderError.unsupported(message: "This Mac doesn't support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                throw LLMProviderError.unsupported(message: "Apple Intelligence isn't enabled in System Settings.")
            case .modelNotReady:
                throw LLMProviderError.unsupported(message: "Apple Intelligence is still downloading.")
            @unknown default:
                throw LLMProviderError.unsupported(message: "Apple Intelligence is unavailable.")
            }
        }

        let session = LanguageModelSession {
            if let systemInstructions, !systemInstructions.isEmpty {
                systemInstructions
            }
        }
        do {
            let response: LanguageModelSession.Response<String>
            if let generationOptions = Self.generationOptions(from: options) {
                response = try await session.respond(to: Prompt(userPrompt), options: generationOptions)
            } else {
                response = try await session.respond(to: Prompt(userPrompt))
            }
            return response.content
        } catch {
            throw LLMProviderError.unsupported(message: Self.friendlyMessage(for: error))
        }
    }

    /// Convert a thrown error from `LanguageModelSession` into a sentence the
    /// user can act on. The framework throws errors in two shapes:
    ///
    /// 1. The Swift `LanguageModelSession.GenerationError` enum, which we
    ///    pattern-match by case-name (extracted via `String(describing:)`) to
    ///    avoid coupling to specific case identifiers across SDK versions.
    /// 2. A raw `NSError` with domain
    ///    `"FoundationModels.LanguageModelSession.GenerationError"` and a
    ///    numeric code — what users actually see on iOS 26 simulators today,
    ///    surfacing as "(FoundationModels.LanguageModelSession.GenerationError
    ///    error -1.)". For these we name the code and steer the user toward a
    ///    cloud provider, since the error has no useful text and code -1 in
    ///    practice means "the on-device session failed for an unspecified
    ///    reason" (most often: Apple Intelligence isn't fully provisioned on
    ///    the simulator's host Mac).
    public static func friendlyMessage(for error: Error) -> String {
        // Swift enum path — the case name is the most informative thing.
        let described = String(describing: error)
        let caseName = String(described.prefix { $0 != "(" && $0 != " " })
        if let mapped = mapGenerationErrorCase(caseName) {
            return mapped
        }

        // NSError-bridged path — domain identifies it, code is all we get.
        let ns = error as NSError
        if ns.domain.contains("FoundationModels") || ns.domain.contains("GenerationError") {
            switch ns.code {
            case -1:
                return "Apple Intelligence couldn't complete this request (internal error). On the iOS Simulator this usually means the on-device model isn't fully provisioned — open the Simulator's Settings → Apple Intelligence & Siri and confirm it's enabled, or switch to a cloud provider in Settings → AI Integration."
            default:
                return "Apple Intelligence raised an internal error (code \(ns.code)). Try again, or switch to a cloud provider in Settings → AI Integration."
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func mapGenerationErrorCase(_ caseName: String) -> String? {
        switch caseName {
        case "assetsUnavailable":
            return "Apple Intelligence model assets aren't ready yet. Check Settings → Apple Intelligence & Siri to confirm the on-device model has finished downloading, then try again."
        case "decodingFailure":
            return "Apple Intelligence couldn't produce a well-formed response. Try again."
        case "exceededContextWindowSize":
            return "This sender has too much input for the on-device model. Try a sender with fewer messages, or switch to a cloud provider in Settings → AI Integration."
        case "guardrailViolation":
            return "Apple Intelligence's safety system declined this request."
        case "unsupportedGuide":
            return "Apple Intelligence doesn't support one of this request's response constraints. Try another provider in Settings → AI Integration."
        case "unsupportedLanguageOrLocale":
            return "Apple Intelligence doesn't support this device's language for this task yet."
        case "rateLimited":
            return "Too many on-device AI requests in a short span. Wait a few seconds and try again."
        case "concurrentRequests":
            return "Another AI request is already running. Try again when it finishes."
        case "refusal":
            return "Apple Intelligence declined to answer this request."
        default:
            return nil
        }
    }

    /// Build a FoundationModels `GenerationOptions` from our `LLMGenerationOptions`, or `nil`
    /// if neither knob is set (in which case we let the framework use its defaults).
    public static func generationOptions(from options: LLMGenerationOptions) -> GenerationOptions? {
        if options.temperature == nil && options.maxTokens == nil { return nil }
        return GenerationOptions(
            temperature: options.temperature,
            maximumResponseTokens: options.maxTokens
        )
    }
}
