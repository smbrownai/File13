import ArgumentParser
import File13Core
import Foundation

/// `file13 settings` — read/write the shared SettingsStore that the GUI also uses.
///
/// This is the proof-of-life for the File13Core package: the CLI calls
/// `SettingsStore()` and gets the *same* values the GUI reads, because both processes
/// are pointed at the App Group suite. Phase-2 commands (mail ops, accounts, rules)
/// build on the same pattern.
struct SettingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Read and write File13 settings (shared with the GUI app).",
        subcommands: [List.self, Get.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print every settings value as `key: value`."
        )

        @Flag(name: .long, help: "Emit JSON instead of plain text.")
        var json: Bool = false

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            let settings = SettingsStore()
            let entries = Self.entries(from: settings)
            if json {
                let dict = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
                let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                let widest = entries.map(\.key.count).max() ?? 0
                for entry in entries {
                    let padded = entry.key.padding(toLength: widest, withPad: " ", startingAt: 0)
                    print("\(padded)  \(entry.value)")
                }
            }
        }

        @MainActor
        fileprivate static func entries(from s: SettingsStore) -> [(key: String, value: String)] {
            return [
                ("appearance",                       s.appearance.rawValue),
                ("refreshSchedule",                  s.refreshSchedule.rawValue),
                ("accentPalette",                    s.accentPalette.rawValue),
                ("undoBufferSeconds",                String(s.undoBufferSeconds)),
                ("confirmBeforeDelete",              String(s.confirmBeforeDelete)),
                ("confirmBeforeUnsubscribe",         String(s.confirmBeforeUnsubscribe)),
                ("dryRunMode",                       String(s.dryRunMode)),
                ("softDeleteToTrash",                String(s.softDeleteToTrash)),
                ("protectTransactionalFromDeletion", String(s.protectTransactionalFromDeletion)),
                ("protectVIPsFromRules",             String(s.protectVIPsFromRules)),
                ("aiProvider",                       s.aiProvider.rawValue),
                ("aiModel",                          s.aiModel.isEmpty ? "(provider default)" : s.aiModel),
                ("autoCategorizeNewSenders",         String(s.autoCategorizeNewSenders)),
                ("preferredMailClientBundleId",      s.preferredMailClientBundleId ?? "(system default)"),
                ("preferredBrowserBundleId",         s.preferredBrowserBundleId ?? "(system default)"),
                ("defaultInboxScope",                s.defaultInboxScope.rawString),
                ("launchAtLogin",                    String(s.launchAtLogin))
            ]
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print one settings value by key."
        )

        @Argument(help: "Setting key (e.g. refreshSchedule, dryRunMode, aiProvider).")
        var key: String

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            let settings = SettingsStore()
            let entries = List.entries(from: settings)
            guard let entry = entries.first(where: { $0.key == key }) else {
                FileHandle.standardError.write(Data("unknown key: \(key)\n".utf8))
                FileHandle.standardError.write(Data("known keys:\n".utf8))
                for entry in entries {
                    FileHandle.standardError.write(Data("  \(entry.key)\n".utf8))
                }
                throw ExitCode(2)
            }
            print(entry.value)
        }
    }
}
