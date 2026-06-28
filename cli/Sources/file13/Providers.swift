import ArgumentParser
import File13Core
import Foundation

/// `file13 providers` — list configured AI providers, show which has an API key, and
/// optionally do a tiny round-trip to verify a provider is actually usable.
///
/// API keys are read from the shared Keychain (set by the GUI's AI Integration tab) — the
/// CLI never asks for or stores them itself. Apple Foundation Models needs no key; its
/// availability is the on-device Apple Intelligence status.
struct ProvidersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "providers",
        abstract: "Inspect AI provider availability and credentials.",
        subcommands: [List.self, Test.self, SetKey.self, DeleteKey.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print every supported provider with availability + API-key status."
        )

        @Flag(name: .long, help: "Emit JSON instead of plain text.")
        var json: Bool = false

        @Flag(name: .long, help: "Probe each provider with availability() (no network call for HTTP providers; on-device check for Apple).")
        var probe: Bool = false

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            let settings = SettingsStore()
            var rows: [Row] = []
            for kind in AIProviderKind.allCases {
                let row = await Row.build(kind: kind, settings: settings, probe: probe)
                rows.append(row)
            }
            if json {
                let data = try JSONSerialization.data(
                    withJSONObject: rows.map(\.dict),
                    options: [.sortedKeys, .prettyPrinted]
                )
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                printPlain(rows)
            }
        }

        private func printPlain(_ rows: [Row]) {
            // Two-column-ish table: provider · model · key · availability.
            let kindWidth   = rows.map(\.kindLabel.count).max() ?? 0
            let modelWidth  = rows.map(\.model.count).max() ?? 0
            let keyWidth    = rows.map(\.keyStatus.count).max() ?? 0
            for r in rows {
                let prefix = r.isGlobalDefault ? "*" : " "
                let kind   = r.kindLabel.padding(toLength: kindWidth,  withPad: " ", startingAt: 0)
                let model  = r.model.padding(toLength: modelWidth,     withPad: " ", startingAt: 0)
                let key    = r.keyStatus.padding(toLength: keyWidth,   withPad: " ", startingAt: 0)
                print("\(prefix) \(kind)  \(model)  \(key)  \(r.availability)")
            }
            print("")
            print("* = global default (file13 settings get aiProvider)")
        }
    }

    struct Test: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a tiny round-trip against one provider to verify it actually works.",
            discussion: """
            For Apple Foundation Models this exercises the on-device model with a short
            prompt. For HTTP providers it sends a 1-token request to the configured model
            using the API key from the shared Keychain. Counts against your provider's
            quota. Use `file13 providers list --probe` for the cheap availability check.
            """
        )

        @Argument(help: "Provider to test (apple-foundation, anthropic, openai, google, perplexity).")
        var provider: String

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            guard let kind = AIProviderKind(rawValue: provider) else {
                FileHandle.standardError.write(Data("unknown provider: \(provider)\n".utf8))
                FileHandle.standardError.write(Data("known providers:\n".utf8))
                for k in AIProviderKind.allCases {
                    FileHandle.standardError.write(Data("  \(k.rawValue) — \(k.label)\n".utf8))
                }
                throw ExitCode(2)
            }
            let settings = SettingsStore()
            let providerImpl = LLMProviderFactory.make(kind: kind, settings: settings)
            switch await providerImpl.availability() {
            case .ready: break
            case .needsSetup(let m), .unsupported(let m), .error(let m):
                FileHandle.standardError.write(Data("\(kind.label): \(m)\n".utf8))
                throw ExitCode(3)
            }
            do {
                let response = try await providerImpl.generate(
                    systemInstructions: "Reply with just the word: pong",
                    userPrompt: "ping"
                )
                let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                print("\(kind.label): ok — \(trimmed.prefix(80))")
            } catch {
                FileHandle.standardError.write(Data("\(kind.label): \(error.localizedDescription)\n".utf8))
                throw ExitCode(4)
            }
        }
    }

    // MARK: - SetKey

    struct SetKey: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-key",
            abstract: "Store an API key for an HTTP provider in the user's Keychain.",
            discussion: """
            The key is read from stdin so it never lands in shell history or process
            argv. Pipe it in (`pbpaste | file13 providers set-key anthropic`) for
            scripts; on a TTY the command prompts with echo suppressed.

            Stored in the *default* user keychain at service `com.shawnbrown.File13`,
            account `ai-key-<provider>`. Not visible to the GUI app's signed copy
            (which writes to the same service+account but with a Keychain Access
            Group claim that the unentitled CLI can't read), so users running both
            still need to set keys independently. Apple Foundation Models needs no
            key — `set-key apple-foundation` is rejected with an error.
            """
        )

        @Argument(help: "Provider name (anthropic, openai, google, perplexity).")
        var provider: String

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            guard let kind = AIProviderKind(rawValue: provider) else {
                FileHandle.standardError.write(Data("unknown provider: \(provider)\n".utf8))
                FileHandle.standardError.write(Data("valid (require key): anthropic, openai, google, perplexity\n".utf8))
                throw ExitCode(2)
            }
            guard kind.requiresAPIKey else {
                FileHandle.standardError.write(Data("\(kind.label) doesn't use an API key (it runs on-device).\n".utf8))
                throw ExitCode(2)
            }
            let key = Self.readKey(prompt: "API key for \(kind.label): ")
            guard !key.isEmpty else {
                FileHandle.standardError.write(Data("empty key — aborting\n".utf8))
                throw ExitCode(2)
            }
            do {
                try KeychainStore.saveAIKey(key, for: kind)
            } catch {
                FileHandle.standardError.write(Data("keychain write failed: \(error.localizedDescription)\n".utf8))
                throw ExitCode(3)
            }
            print("\(kind.rawValue): key stored")
        }

        private static func readKey(prompt: String) -> String {
            TTYInput.readSecret(prompt: prompt)
        }
    }

    // MARK: - DeleteKey

    struct DeleteKey: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete-key",
            abstract: "Remove the stored API key for an HTTP provider."
        )

        @Argument(help: "Provider name (anthropic, openai, google, perplexity).")
        var provider: String

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            guard let kind = AIProviderKind(rawValue: provider) else {
                FileHandle.standardError.write(Data("unknown provider: \(provider)\n".utf8))
                throw ExitCode(2)
            }
            guard kind.requiresAPIKey else {
                FileHandle.standardError.write(Data("\(kind.label) doesn't use an API key.\n".utf8))
                throw ExitCode(2)
            }
            do {
                try KeychainStore.deleteAIKey(for: kind)
            } catch {
                FileHandle.standardError.write(Data("keychain delete failed: \(error.localizedDescription)\n".utf8))
                throw ExitCode(3)
            }
            print("\(kind.rawValue): key deleted")
        }
    }

    fileprivate struct Row {
        let kind: AIProviderKind
        let kindLabel: String
        let model: String
        let keyStatus: String
        let availability: String
        let isGlobalDefault: Bool

        var dict: [String: Any] {
            [
                "id": kind.rawValue,
                "label": kindLabel,
                "model": model,
                "keyStatus": keyStatus,
                "availability": availability,
                "isGlobalDefault": isGlobalDefault
            ]
        }

        @MainActor
        static func build(kind: AIProviderKind, settings: SettingsStore, probe: Bool) async -> Row {
            let model: String = {
                if kind == settings.aiProvider, !settings.aiModel.isEmpty { return settings.aiModel }
                return kind.defaultModel.isEmpty ? "(provider-managed)" : kind.defaultModel
            }()
            let keyStatus: String
            if kind.requiresAPIKey {
                let key = (try? KeychainStore.loadAIKey(for: kind)) ?? nil
                keyStatus = (key ?? "").isEmpty ? "no key" : "key set"
            } else {
                keyStatus = "n/a"
            }
            let availability: String
            if probe {
                let providerImpl = LLMProviderFactory.make(kind: kind, settings: settings)
                switch await providerImpl.availability() {
                case .ready:                    availability = "ready"
                case .needsSetup(let m):        availability = "needs setup — \(m)"
                case .unsupported(let m):       availability = "unsupported — \(m)"
                case .error(let m):             availability = "error — \(m)"
                }
            } else {
                availability = "(not probed)"
            }
            return Row(
                kind: kind,
                kindLabel: kind.label,
                model: model,
                keyStatus: keyStatus,
                availability: availability,
                isGlobalDefault: kind == settings.aiProvider
            )
        }
    }
}
