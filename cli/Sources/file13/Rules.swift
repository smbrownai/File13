import ArgumentParser
import File13Core
import Foundation

/// `file13 rules` — inspect, enable/disable, schedule, and dry-run cleanup rules.
///
/// All operations go through the shared `RuleStore`. Live execution (`run` without
/// `--dry-run`) requires the IMAP layer that still lives in the GUI, so for now this
/// command can dry-run against the existing cached headers and report what *would*
/// happen — but the actual archive/delete commits stay in the GUI until the
/// AccountSession + SwiftMailIMAPClient are moved into File13Core.
struct RulesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "List, enable/disable, schedule, and dry-run cleanup rules.",
        subcommands: [List.self, Show.self, Enable.self, Disable.self, Schedule.self, Run.self]
    )

    // MARK: - List

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print every rule, with id, enabled flag, outcome, and conditions."
        )

        @Flag(name: .long, help: "Emit JSON.")
        var json: Bool = false

        @Flag(name: .long, help: "Only enabled rules.")
        var enabledOnly: Bool = false

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            let store = RuleStore()
            let rules = enabledOnly ? store.enabledRules : store.rules
            if json {
                let dicts: [[String: Any]] = rules.map { r in
                    [
                        "id": r.id.uuidString,
                        "name": r.name,
                        "enabled": r.enabled,
                        "outcome": r.outcome.label,
                        "conditions": r.conditions.summary,
                        "scope": r.effectiveScope.summary,
                        "createdAt": ISO8601DateFormatter().string(from: r.createdAt)
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: dicts, options: [.sortedKeys, .prettyPrinted])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                if rules.isEmpty {
                    print("(no rules \(enabledOnly ? "enabled" : "configured"))")
                    print("schedule: \(store.schedule.rawValue) — \(store.schedule.label)")
                    return
                }
                let nameWidth = max(4, rules.map(\.name.count).max() ?? 0)
                let outcomeWidth = max(4, rules.map(\.outcome.label.count).max() ?? 0)
                for r in rules {
                    let mark = r.enabled ? "[x]" : "[ ]"
                    let name = r.name.isEmpty ? "(unnamed)" : r.name
                    let paddedName = name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                    let outcome = r.outcome.label.padding(toLength: outcomeWidth, withPad: " ", startingAt: 0)
                    print("\(mark) \(r.id.uuidString)  \(paddedName)  \(outcome)  \(r.conditions.summary)")
                }
                print("")
                print("schedule: \(store.schedule.rawValue) — \(store.schedule.label)")
            }
        }
    }

    // MARK: - Show

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a single rule with full conditions and outcome."
        )

        @Argument(help: "Rule UUID.")
        var id: String

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            guard let uuid = UUID(uuidString: id) else {
                FileHandle.standardError.write(Data("not a valid UUID: \(id)\n".utf8))
                throw ExitCode(2)
            }
            let store = RuleStore()
            guard let rule = store.rules.first(where: { $0.id == uuid }) else {
                FileHandle.standardError.write(Data("no rule with id \(uuid.uuidString)\n".utf8))
                throw ExitCode(2)
            }
            print("id:         \(rule.id.uuidString)")
            print("name:       \(rule.name.isEmpty ? "(unnamed)" : rule.name)")
            print("enabled:    \(rule.enabled)")
            print("outcome:    \(rule.outcome.label)")
            print("conditions: \(rule.conditions.summary)")
            print("scope:      \(rule.effectiveScope.summary)")
            print("created:    \(rule.createdAt)")
        }
    }

    // MARK: - Enable / Disable

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn on a rule.")
        @Argument(help: "Rule UUID.") var id: String
        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            try await RulesCommand.toggle(id: id, enabled: true)
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn off a rule.")
        @Argument(help: "Rule UUID.") var id: String
        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            try await RulesCommand.toggle(id: id, enabled: false)
        }
    }

    // MARK: - Schedule

    /// Combines the GUI-side `RuleSchedule` (when File13.app runs rules itself) with
    /// the headless launchd integration (when an OS-managed agent runs `file13 rules
    /// run` on a cron-style schedule). Get/set apply to the GUI schedule;
    /// install/remove/status apply to the launchd plist.
    struct Schedule: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Inspect or change scheduled rule execution (GUI + launchd).",
            subcommands: [Get.self, Set.self, Install.self, Remove.self, Status.self]
        )

        struct Get: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Print the GUI's current schedule (manual | onLaunch | hourly | daily).")
            @MainActor
            func run() async throws {
                try CLILicenseReader.requirePro()
                print(RuleStore().schedule.rawValue)
            }
        }

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Set the GUI's rule-run schedule.")
            @Argument(help: "manual | onLaunch | hourly | daily")
            var value: String
            @MainActor
            func run() async throws {
                try CLILicenseReader.requirePro()
                guard let parsed = RuleSchedule(rawValue: value) else {
                    FileHandle.standardError.write(Data("unknown schedule: \(value)\n".utf8))
                    FileHandle.standardError.write(Data("valid: manual, onLaunch, hourly, daily\n".utf8))
                    throw ExitCode(2)
                }
                RuleStore().schedule = parsed
                print("GUI schedule set to: \(parsed.rawValue) — \(parsed.label)")
                if parsed != .manual {
                    FileHandle.standardError.write(Data(
                        "note: this fires only while File13.app is open. For headless runs,\n      use `file13 rules schedule install --interval hourly|daily`.\n".utf8))
                }
            }
        }

        struct Install: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Install a launchd agent that runs `file13 rules run` on a schedule.",
                discussion: """
                Writes a plist to `~/Library/LaunchAgents/com.shawnbrown.File13.rules.plist`
                and loads it via `launchctl bootstrap`. The agent runs as your user (not
                root), so it can reach the same App Group container and Keychain.

                --interval hourly        StartInterval = 3600
                --interval daily         StartCalendarInterval Hour=3 Minute=0  (3 AM local)
                --interval every5Minutes StartInterval = 300

                The `file13` binary path is resolved at install time and embedded in the
                plist. Re-run install after moving or upgrading the binary.
                """
            )

            @Option(name: .long, help: "How often to fire (hourly | daily | every5Minutes).")
            var interval: String

            @Flag(name: .long, help: "Print the plist that would be written; don't load it.")
            var dryRun: Bool = false

            @MainActor
            func run() async throws {
                try CLILicenseReader.requirePro()
                guard let parsed = LaunchdInterval(rawValue: interval) else {
                    FileHandle.standardError.write(Data("unknown interval: \(interval)\n".utf8))
                    FileHandle.standardError.write(Data("valid: hourly, daily, every5Minutes\n".utf8))
                    throw ExitCode(2)
                }
                try LaunchdAgent.install(interval: parsed, dryRun: dryRun)
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Unload and delete the launchd plist.")
            @MainActor
            func run() async throws {
                try CLILicenseReader.requirePro()
                try LaunchdAgent.remove()
            }
        }

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Report whether the launchd agent is installed/loaded.")
            @MainActor
            func run() async throws {
                try CLILicenseReader.requirePro()
                try LaunchdAgent.status()
            }
        }
    }

    // MARK: - Run

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run all enabled rules: refresh each account, evaluate, commit.",
            discussion: """
            Per account: refreshes cached headers, evaluates every enabled rule (or
            just `--rule <uuid>` if specified), commits deletes / archives / moves to
            IMAP, disconnects. Reports per-rule counts at the end.

            Protections always applied:
              - `protectVIPsFromRules` (settings) — VIPs are never auto-touched
              - `protectTransactionalFromDeletion` (settings) — receipts/invoices
                skip delete-only rules unless `softDeleteToTrash` is on
              - `unsubscribe` rule outcomes are no-ops (use `file13 mail` if
                needed; CLI never auto-unsubscribes)

            Lock-protected; bails exit 2 if File13.app is open.
            """
        )

        @Flag(name: .long, help: "Show what would happen without committing.")
        var dryRun: Bool = false

        @Option(name: .long, help: "Limit to one rule by id.")
        var rule: String?

        @Option(name: .long, help: "Limit to one account by id.")
        var account: String?

        @Flag(name: .long, help: "Skip the implicit refresh.")
        var noRefresh: Bool = false

        @Flag(name: .long, help: "Emit a JSON report.")
        var json: Bool = false

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            try await RulesRunEngine.execute(
                ruleId: rule.flatMap(UUID.init(uuidString:)),
                accountId: account.flatMap(UUID.init(uuidString:)),
                dryRun: dryRun,
                noRefresh: noRefresh,
                json: json
            )
        }
    }


    // MARK: - Helpers

    @MainActor
    fileprivate static func toggle(id: String, enabled: Bool) async throws {
        guard let uuid = UUID(uuidString: id) else {
            FileHandle.standardError.write(Data("not a valid UUID: \(id)\n".utf8))
            throw ExitCode(2)
        }
        let store = RuleStore()
        guard let rule = store.rules.first(where: { $0.id == uuid }) else {
            FileHandle.standardError.write(Data("no rule with id \(uuid.uuidString)\n".utf8))
            throw ExitCode(2)
        }
        if rule.enabled == enabled {
            print("\(rule.id.uuidString): already \(enabled ? "enabled" : "disabled")")
            return
        }
        store.setEnabled(id: uuid, enabled: enabled)
        print("\(rule.id.uuidString): \(enabled ? "enabled" : "disabled")")
    }
}
