import ArgumentParser
import File13Core
import Foundation
import FoundationModels

/// `file13 doctor` — environment / capability check, including the day-1 spike from the
/// CLI spec: does Apple Foundation Models work in a CLI process?
///
/// What we report:
///   - macOS version
///   - Apple Foundation Models availability (the spike — runs `SystemLanguageModel.default.availability`)
///   - Whether each HTTP provider's API key is reachable from environment variables
///   - App Group container path (if entitled — currently not, surfaced as "not configured")
///
/// We deliberately keep this self-contained: it doesn't link against the GUI app's source
/// or share any state. It just answers "would this CLI binary be capable of running AI
/// triage in the current environment?".
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnose CLI capabilities — Apple Intelligence, AI provider keys, App Group access.",
        discussion: """
        Run this after building the CLI to verify the spike result for Apple Foundation Models.
        If 'Apple Foundation Models' reports 'available', a non-GUI binary CAN drive on-device
        inference. If it reports needsSetup/unsupported/error, the CLI must fall back to HTTP
        providers (Anthropic / OpenAI / Google / Perplexity) using API keys from the environment
        or, once integrated, the shared Keychain Access Group.
        """
    )

    @Flag(name: .long, help: "Emit JSON instead of plain text.")
    var json: Bool = false

    @Flag(name: .long, help: "Skip the Apple Foundation Models check (useful on machines without Apple Intelligence).")
    var skipAppleFM: Bool = false

    func run() async throws {
        var report: [String: Any] = [:]

        // Platform
        let v = ProcessInfo.processInfo.operatingSystemVersion
        report["macOS"] = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"

        // Apple Foundation Models — THE SPIKE
        if skipAppleFM {
            report["appleFoundationModels"] = "skipped"
        } else {
            report["appleFoundationModels"] = await checkAppleFoundationModels()
        }

        // HTTP provider env keys — does NOT validate the key, just checks presence
        report["providerEnvKeys"] = checkProviderEnvKeys()

        // App Group — until the entitlement is configured, this will report "not configured"
        report["appGroupContainer"] = checkAppGroupContainer()

        if json {
            let data = try JSONSerialization.data(
                withJSONObject: report,
                options: [.sortedKeys, .prettyPrinted]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            printPlain(report)
        }
    }

    // MARK: - Apple Foundation Models spike

    private func checkAppleFoundationModels() async -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            // Try a tiny round-trip so we surface entitlement / sandbox failures here
            // instead of much later inside a real triage call.
            do {
                let session = LanguageModelSession {
                    "Reply with just the word: pong"
                }
                let response = try await session.respond(to: Prompt("ping"))
                let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return "available — round-trip ok (\(trimmed.prefix(40)))"
            } catch {
                return "advertised available, but round-trip failed: \(error.localizedDescription)"
            }
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "unsupported — this Mac doesn't support Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "needsSetup — Apple Intelligence not enabled in System Settings"
            case .modelNotReady:
                return "needsSetup — Apple Intelligence model still downloading"
            @unknown default:
                return "unsupported — unknown reason"
            }
        }
    }

    // MARK: - Provider env keys

    private func checkProviderEnvKeys() -> [String: Bool] {
        // Once Keychain Access Group sharing is wired up, we'll also check that path. For
        // now, env vars are the only credential source the bare CLI scaffold can read.
        let keys: [(String, String)] = [
            ("anthropic",  "ANTHROPIC_API_KEY"),
            ("openai",     "OPENAI_API_KEY"),
            ("google",     "GOOGLE_API_KEY"),
            ("perplexity", "PERPLEXITY_API_KEY")
        ]
        var out: [String: Bool] = [:]
        for (provider, env) in keys {
            let value = ProcessInfo.processInfo.environment[env]
            out[provider] = !(value ?? "").isEmpty
        }
        return out
    }

    // MARK: - App Group container

    private func checkAppGroupContainer() -> String {
        let groupId = SharedDefaults.appGroupId
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else {
            return "not configured — add App Group entitlement '\(groupId)' to this binary and to File13.app, signed by the same Team ID"
        }
        // Path resolution alone doesn't prove entitled write access — macOS will hand back a
        // URL for any group id you ask about. Verify by writing a sentinel file.
        let sentinel = url.appendingPathComponent(".file13-doctor-write-check")
        do {
            try Data().write(to: sentinel, options: .atomic)
            try? FileManager.default.removeItem(at: sentinel)
            return "ok — \(url.path) (write verified)"
        } catch {
            return "path resolves but write failed (\(error.localizedDescription)) — entitlement likely missing on this binary"
        }
    }

    // MARK: - Plain output

    private func printPlain(_ report: [String: Any]) {
        for key in report.keys.sorted() {
            let value = report[key]
            switch value {
            case let dict as [String: Bool]:
                print("\(key):")
                for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                    print("  \(k): \(v ? "set" : "unset")")
                }
            default:
                print("\(key): \(value ?? "")")
            }
        }
    }
}
