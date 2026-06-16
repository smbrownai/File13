import ArgumentParser
import File13Core
import Foundation

/// `file13 ai` — power-user tuning of the AI subsystem.
///
/// Surfaces `AIFeatureTuning` per-feature: custom prompt suffix, temperature,
/// max output tokens, optional provider/model override. Defaults are sensible;
/// these knobs are for users who want to push behavior in a specific direction
/// (different model per feature, lower temp on a flaky run, custom rules in the
/// system prompt).
struct AICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ai",
        abstract: "Per-feature AI tuning (custom instructions, temperature, max tokens, provider/model override).",
        subcommands: [Tuning.self]
    )

    struct Tuning: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Inspect and edit per-feature AI tuning.",
            subcommands: [Get.self, Set.self, Unset.self, Reset.self]
        )

        // MARK: get

        struct Get: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Print the tuning for one feature (or every feature)."
            )

            @Argument(help: "senderAdvice | senderCategorize | ruleSuggest. Omit to print every feature.")
            var feature: String?

            @Flag(name: .long, help: "Emit JSON.")
            var json: Bool = false

            @MainActor
            func run() async throws {
                try CLILicenseReader.requirePro()
                let settings = SettingsStore()
                let features: [AIFeature]
                if let raw = feature {
                    guard let parsed = AIFeature(rawValue: raw) else {
                        FileHandle.standardError.write(Data("unknown feature: \(raw)\n".utf8))
                        FileHandle.standardError.write(Data("valid: \(AIFeature.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8))
                        throw ExitCode(2)
                    }
                    features = [parsed]
                } else {
                    features = AIFeature.allCases
                }

                if json {
                    let dicts: [[String: Any]] = features.map { f -> [String: Any] in
                        let t = settings.tuning(for: f)
                        var d: [String: Any] = [
                            "feature": f.rawValue,
                            "label": f.label,
                            "isDefault": t.isDefault,
                            "defaultTemperature": f.defaultTemperature,
                            "defaultMaxTokens": f.defaultMaxTokens,
                            "customInstructions": t.customInstructions
                        ]
                        if let v = t.temperature      { d["temperature"]      = v }
                        if let v = t.maxTokens        { d["maxTokens"]        = v }
                        if let v = t.providerOverride { d["providerOverride"] = v.rawValue }
                        if !t.modelOverride.isEmpty   { d["modelOverride"]    = t.modelOverride }
                        return d
                    }
                    let payload: Any = (feature == nil) ? dicts : (dicts.first ?? [:])
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                    return
                }

                for f in features {
                    let t = settings.tuning(for: f)
                    print("[\(f.rawValue)] \(f.label)")
                    print("  customInstructions: \(t.customInstructions.isEmpty ? "(none)" : t.customInstructions)")
                    print("  temperature:        \(t.temperature.map { String(format: "%.2f", $0) } ?? "default (\(String(format: "%.2f", f.defaultTemperature)))")")
                    print("  maxTokens:          \(t.maxTokens.map(String.init) ?? "default (\(f.defaultMaxTokens))")")
                    print("  providerOverride:   \(t.providerOverride?.rawValue ?? "(use global)")")
                    print("  modelOverride:      \(t.modelOverride.isEmpty ? "(provider default)" : t.modelOverride)")
                    if features.count > 1 { print("") }
                }
            }
        }

        // MARK: set

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Set one tuning field for one feature.",
                discussion: """
                Keys: customInstructions | temperature | maxTokens | providerOverride | modelOverride

                Special values:
                  - For `customInstructions`, pass `-` to read the prompt from stdin.
                  - For `temperature` / `maxTokens`, pass `default` to remove the override.
                  - For `providerOverride`, pass `global` to remove the override.
                """
            )

            @Argument(help: "senderAdvice | senderCategorize | ruleSuggest")
            var feature: String

            @Argument(help: "customInstructions | temperature | maxTokens | providerOverride | modelOverride")
            var key: String

            @Argument(help: "New value, or `default`/`global` to clear an override. Use `-` to read customInstructions from stdin.")
            var value: String

            @MainActor
            func run() async throws {
                try CLILicenseReader.requirePro()
                guard let f = AIFeature(rawValue: feature) else {
                    FileHandle.standardError.write(Data("unknown feature: \(feature)\n".utf8))
                    throw ExitCode(2)
                }
                let settings = SettingsStore()
                var tuning = settings.tuning(for: f)

                switch key {
                case "customInstructions":
                    if value == "-" {
                        let data = FileHandle.standardInput.availableData
                        tuning.customInstructions = String(data: data, encoding: .utf8) ?? ""
                    } else {
                        tuning.customInstructions = value
                    }
                case "temperature":
                    if value == "default" {
                        tuning.temperature = nil
                    } else {
                        guard let parsed = Double(value), parsed >= 0.0, parsed <= 1.0 else {
                            FileHandle.standardError.write(Data("temperature must be a Double in [0.0, 1.0]\n".utf8))
                            throw ExitCode(2)
                        }
                        tuning.temperature = parsed
                    }
                case "maxTokens":
                    if value == "default" {
                        tuning.maxTokens = nil
                    } else {
                        guard let parsed = Int(value), parsed > 0 else {
                            FileHandle.standardError.write(Data("maxTokens must be a positive integer\n".utf8))
                            throw ExitCode(2)
                        }
                        tuning.maxTokens = parsed
                    }
                case "providerOverride":
                    if value == "global" {
                        tuning.providerOverride = nil
                        tuning.modelOverride = ""
                    } else {
                        guard let parsed = AIProviderKind(rawValue: value) else {
                            FileHandle.standardError.write(Data("unknown provider: \(value)\n".utf8))
                            throw ExitCode(2)
                        }
                        tuning.providerOverride = parsed
                        // Anchor model when needed so it stays valid for the new provider.
                        if !parsed.availableModels.contains(where: { $0.id == tuning.modelOverride }) {
                            tuning.modelOverride = parsed.availableModels.first?.id ?? ""
                        }
                    }
                case "modelOverride":
                    tuning.modelOverride = value
                default:
                    FileHandle.standardError.write(Data("unknown key: \(key)\n".utf8))
                    FileHandle.standardError.write(Data("valid: customInstructions, temperature, maxTokens, providerOverride, modelOverride\n".utf8))
                    throw ExitCode(2)
                }

                settings.setTuning(tuning, for: f)
                print("[\(f.rawValue)] \(key) updated")
            }
        }

        // MARK: unset

        struct Unset: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Clear one override (alias for `set <feature> <key> default`)."
            )
            @Argument(help: "senderAdvice | senderCategorize | ruleSuggest") var feature: String
            @Argument(help: "customInstructions | temperature | maxTokens | providerOverride | modelOverride") var key: String

            @MainActor
            func run() async throws {
                try CLILicenseReader.requirePro()
                let value: String
                switch key {
                case "providerOverride": value = "global"
                case "customInstructions", "modelOverride": value = ""
                default: value = "default"
                }
                var setCommand = Set()
                setCommand.feature = feature
                setCommand.key = key
                setCommand.value = value
                try await setCommand.run()
            }
        }

        // MARK: reset

        struct Reset: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Wipe every override for one feature, returning to AIFeatureTuning() defaults."
            )
            @Argument(help: "senderAdvice | senderCategorize | ruleSuggest") var feature: String

            @MainActor
            func run() async throws {
                try CLILicenseReader.requirePro()
                guard let f = AIFeature(rawValue: feature) else {
                    FileHandle.standardError.write(Data("unknown feature: \(feature)\n".utf8))
                    throw ExitCode(2)
                }
                SettingsStore().setTuning(AIFeatureTuning(), for: f)
                print("[\(f.rawValue)] tuning reset to defaults")
            }
        }
    }
}
