import ArgumentParser
import File13Core
import Foundation

/// `file13 config export|import` — round-trip everything but secrets.
///
/// The JSON shape covers settings, accounts (no passwords), AI provider+model (no
/// keys), rules, VIPs, sender categories, and the rules schedule. Secrets stay in
/// Keychain — `import` either inherits them (when the account/provider already exists)
/// or prompts on a TTY for newly-introduced ones.
struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Export and import the full File13 configuration as JSON.",
        subcommands: [Export.self, Import.self]
    )

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the current configuration as JSON. Secrets are omitted."
        )

        @Argument(help: "Output file path. Use `-` (or omit) to write to stdout.")
        var output: String?

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            let snapshot = try ConfigSnapshot.capture()
            let data = try JSONSerialization.data(
                withJSONObject: snapshot.toJSON(),
                options: [.sortedKeys, .prettyPrinted]
            )
            switch output {
            case nil, .some("-"):
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            case .some(let path):
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                print("wrote \(data.count) bytes to \(path)")
            }
        }
    }

    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Apply a configuration JSON file (no passwords/keys are read from it).",
            discussion: """
            Default mode is `merge`: settings overwrite key-by-key; rules upsert by id;
            accounts add new entries by address (existing entries inherit their stored
            Keychain password); VIPs union into pinned/excluded sets; categories merge
            in. `--mode replace` clears each section before applying — useful for
            seeding a fresh machine from a known-good config dump.

            When `import` introduces an account address that doesn't already have a
            stored password, it prompts on a TTY (`getpass`-style, no echo) or fails
            with exit 2 in non-interactive environments. Pre-seed those passwords with
            `file13 accounts add` first to keep the import non-interactive.
            """
        )

        @Argument(help: "JSON file path. Use `-` to read from stdin.")
        var input: String

        @Option(name: .long, help: "merge (default) | replace")
        var mode: String = "merge"

        @Flag(name: .long, help: "Skip the accounts section entirely (use existing accounts as-is).")
        var skipAccounts: Bool = false

        @Flag(name: .long, help: "Print what would be applied without actually writing anything.")
        var dryRun: Bool = false

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            guard let parsedMode = ImportMode(rawValue: mode) else {
                FileHandle.standardError.write(Data("unknown mode: \(mode) (valid: merge, replace)\n".utf8))
                throw ExitCode(2)
            }
            let raw: Data
            if input == "-" {
                raw = FileHandle.standardInput.availableData
            } else {
                raw = try Data(contentsOf: URL(fileURLWithPath: input))
            }
            let json = try JSONSerialization.jsonObject(with: raw, options: [])
            guard let dict = json as? [String: Any] else {
                FileHandle.standardError.write(Data("config root must be a JSON object\n".utf8))
                throw ExitCode(2)
            }
            try await ConfigSnapshot.apply(json: dict, mode: parsedMode, skipAccounts: skipAccounts, dryRun: dryRun)
        }
    }
}

// MARK: - Snapshot

enum ImportMode: String { case merge, replace }

@MainActor
struct ConfigSnapshot {
    let settings: SettingsStore
    let accounts: [Account]
    let rules: [Rule]
    let categories: [String: SenderCategory]
    let vipsPinned: [String]
    let vipsExcluded: [String]
    let rulesSchedule: RuleSchedule

    static func capture() throws -> ConfigSnapshot {
        ConfigSnapshot(
            settings: SettingsStore(),
            accounts: AccountStore().accounts,
            rules: RuleStore().rules,
            categories: SenderCategoryStore().categories,
            vipsPinned: Array(VIPStore().pinned).sorted(),
            vipsExcluded: Array(VIPStore().excluded).sorted(),
            rulesSchedule: RuleStore().schedule
        )
    }

    func toJSON() -> [String: Any] {
        var settingsDict: [String: Any] = [
            "appearance": settings.appearance.rawValue,
            "refreshSchedule": settings.refreshSchedule.rawValue,
            "accentPalette": settings.accentPalette.rawValue,
            "undoBufferSeconds": settings.undoBufferSeconds,
            "confirmBeforeDelete": settings.confirmBeforeDelete,
            "confirmBeforeUnsubscribe": settings.confirmBeforeUnsubscribe,
            "dryRunMode": settings.dryRunMode,
            "softDeleteToTrash": settings.softDeleteToTrash,
            "protectTransactionalFromDeletion": settings.protectTransactionalFromDeletion,
            "protectVIPsFromRules": settings.protectVIPsFromRules,
            "autoCategorizeNewSenders": settings.autoCategorizeNewSenders,
            "launchAtLogin": settings.launchAtLogin,
            "defaultInboxScope": settings.defaultInboxScope.rawString
        ]
        if let id = settings.preferredMailClientBundleId, !id.isEmpty {
            settingsDict["preferredMailClientBundleId"] = id
        }
        if let id = settings.preferredBrowserBundleId, !id.isEmpty {
            settingsDict["preferredBrowserBundleId"] = id
        }

        let aiDict: [String: Any] = [
            "provider": settings.aiProvider.rawValue,
            "model": settings.aiModel
            // intentional: no `providers.<n>.apiKey` — secrets are not part of export
        ]

        let accountsArr: [[String: Any]] = accounts.map { acc in
            // No "password" field by design.
            [
                "id": acc.id.uuidString,
                "displayName": acc.displayName,
                "address": acc.address,
                "host": acc.host,
                "port": acc.port,
                "username": acc.username,
                "provider": acc.provider.rawValue
            ]
        }

        let rulesArr: [[String: Any]] = rules.map { r in
            var dict: [String: Any] = [
                "id": r.id.uuidString,
                "name": r.name,
                "enabled": r.enabled,
                "outcome": Self.encode(outcome: r.outcome),
                "createdAt": ISO8601DateFormatter().string(from: r.createdAt)
            ]
            dict["match"] = Self.encode(conditions: r.conditions)
            return dict
        }

        let categoriesDict: [String: String] = Dictionary(
            uniqueKeysWithValues: categories.map { ($0.key, $0.value.rawValue) }
        )

        return [
            "settings": settingsDict,
            "ai": aiDict,
            "accounts": accountsArr,
            "rules": rulesArr,
            "vips": [
                "pinned": vipsPinned,
                "excluded": vipsExcluded
            ],
            "categories": categoriesDict,
            "schedule": ["rules": rulesSchedule.rawValue]
        ]
    }

    private static func encode(outcome: Rule.Outcome) -> Any {
        switch outcome {
        case .delete:                  return "delete"
        case .archive:                 return "archive"
        case .moveToFolder(let dest):  return ["move": dest]
        case .unsubscribe:             return "unsubscribe"
        }
    }

    private static func encode(conditions: Rule.Conditions) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let v = conditions.fromAddressOrDomain { dict["fromAddressOrDomain"] = v }
        if let v = conditions.subjectContains    { dict["subjectContains"] = v }
        if let v = conditions.olderThanDays      { dict["olderThanDays"] = v }
        if let v = conditions.isUnread           { dict["isUnread"] = v }
        if let v = conditions.category           { dict["category"] = v.rawValue }
        return dict
    }

    // MARK: - Apply

    static func apply(json: [String: Any], mode: ImportMode, skipAccounts: Bool, dryRun: Bool) async throws {
        let lock = LockFile()
        switch lock.tryAcquire() {
        case .acquired: break
        case .heldByOther:
            FileHandle.standardError.write(Data("File13.app is running — close it before `file13 config import`.\n".utf8))
            throw ExitCode(2)
        case .error(let m):
            FileHandle.standardError.write(Data("lock error: \(m)\n".utf8))
            throw ExitCode(3)
        }
        defer { lock.release() }

        if dryRun {
            print("dry run: would apply config in \(mode.rawValue) mode")
        }

        // Settings
        if let s = json["settings"] as? [String: Any] {
            try applySettings(s, mode: mode, dryRun: dryRun)
        }
        // AI provider+model (no keys)
        if let ai = json["ai"] as? [String: Any] {
            try applyAI(ai, dryRun: dryRun)
        }
        // Accounts
        if !skipAccounts, let accs = json["accounts"] as? [[String: Any]] {
            try applyAccounts(accs, mode: mode, dryRun: dryRun)
        }
        // Rules
        if let rs = json["rules"] as? [[String: Any]] {
            try applyRules(rs, mode: mode, dryRun: dryRun)
        }
        // Categories
        if let cats = json["categories"] as? [String: String] {
            try applyCategories(cats, mode: mode, dryRun: dryRun)
        }
        // VIPs
        if let vips = json["vips"] as? [String: Any] {
            try applyVIPs(vips, mode: mode, dryRun: dryRun)
        }
        // Schedule
        if let sched = json["schedule"] as? [String: Any], let raw = sched["rules"] as? String {
            try applySchedule(raw, dryRun: dryRun)
        }

        if !dryRun {
            print("config import complete (\(mode.rawValue) mode)")
        }
    }

    private static func applySettings(_ dict: [String: Any], mode: ImportMode, dryRun: Bool) throws {
        let settings = SettingsStore()
        var changes = 0
        // Each known key is read individually so unknown keys in the JSON
        // don't crash the import. `merge` writes only the keys present in the
        // file; `replace` first resets every importable setting to its
        // default, so the file fully defines them and anything it omits
        // reverts to default.
        if mode == .replace && !dryRun {
            settings.resetToDefaults()
        }
        if let v = dict["appearance"] as? String, let parsed = SettingsStore.AppearanceMode(rawValue: v) {
            if !dryRun { settings.appearance = parsed }; changes += 1
        }
        if let v = dict["refreshSchedule"] as? String, let parsed = SettingsStore.RefreshSchedule(rawValue: v) {
            if !dryRun { settings.refreshSchedule = parsed }; changes += 1
        }
        if let v = dict["accentPalette"] as? String, let parsed = SettingsStore.AccentPalette(rawValue: v) {
            if !dryRun { settings.accentPalette = parsed }; changes += 1
        }
        if let v = dict["undoBufferSeconds"] as? Int {
            if !dryRun { settings.undoBufferSeconds = v }; changes += 1
        }
        if let v = dict["confirmBeforeDelete"] as? Bool {
            if !dryRun { settings.confirmBeforeDelete = v }; changes += 1
        }
        if let v = dict["confirmBeforeUnsubscribe"] as? Bool {
            if !dryRun { settings.confirmBeforeUnsubscribe = v }; changes += 1
        }
        if let v = dict["dryRunMode"] as? Bool {
            if !dryRun { settings.dryRunMode = v }; changes += 1
        }
        if let v = dict["softDeleteToTrash"] as? Bool {
            if !dryRun { settings.softDeleteToTrash = v }; changes += 1
        }
        if let v = dict["protectTransactionalFromDeletion"] as? Bool {
            if !dryRun { settings.protectTransactionalFromDeletion = v }; changes += 1
        }
        if let v = dict["protectVIPsFromRules"] as? Bool {
            if !dryRun { settings.protectVIPsFromRules = v }; changes += 1
        }
        if let v = dict["autoCategorizeNewSenders"] as? Bool {
            if !dryRun { settings.autoCategorizeNewSenders = v }; changes += 1
        }
        if let v = dict["launchAtLogin"] as? Bool {
            if !dryRun { settings.launchAtLogin = v }; changes += 1
        }
        if let v = dict["defaultInboxScope"] as? String, let parsed = SettingsStore.DefaultInboxScope(rawString: v) {
            if !dryRun { settings.defaultInboxScope = parsed }; changes += 1
        }
        if let v = dict["preferredMailClientBundleId"] as? String {
            if !dryRun { settings.preferredMailClientBundleId = v }; changes += 1
        }
        if let v = dict["preferredBrowserBundleId"] as? String {
            if !dryRun { settings.preferredBrowserBundleId = v }; changes += 1
        }
        print("settings: \(dryRun ? "would apply" : "applied") \(changes) keys")
    }

    private static func applyAI(_ dict: [String: Any], dryRun: Bool) throws {
        let settings = SettingsStore()
        var changes = 0
        if let v = dict["provider"] as? String, let parsed = AIProviderKind(rawValue: v) {
            if !dryRun { settings.aiProvider = parsed }; changes += 1
        }
        if let v = dict["model"] as? String {
            if !dryRun { settings.aiModel = v }; changes += 1
        }
        print("ai: \(dryRun ? "would apply" : "applied") \(changes) keys (no API keys imported — set via `file13 providers set-key` once that lands)")
    }

    private static func applyAccounts(_ arr: [[String: Any]], mode: ImportMode, dryRun: Bool) throws {
        let store = AccountStore()
        let existingByAddress = Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.address.lowercased(), $0) })
        let incomingAddresses = Set(arr.compactMap { ($0["address"] as? String)?.lowercased() })

        // replace mode: drop accounts not present in the imported set
        if mode == .replace {
            for acc in store.accounts where !incomingAddresses.contains(acc.address.lowercased()) {
                if !dryRun { store.remove(acc.id) }
                print("accounts: \(dryRun ? "would remove" : "removed") \(acc.displayName) <\(acc.address)>")
            }
        }

        for raw in arr {
            guard
                let displayName = raw["displayName"] as? String,
                let address = raw["address"] as? String,
                let host = raw["host"] as? String,
                let port = raw["port"] as? Int,
                let username = raw["username"] as? String,
                let providerRaw = raw["provider"] as? String,
                let provider = Account.Provider(rawValue: providerRaw)
            else {
                FileHandle.standardError.write(Data("accounts: skipping incomplete entry: \(raw)\n".utf8))
                continue
            }
            if existingByAddress[address.lowercased()] != nil {
                print("accounts: \(dryRun ? "would keep" : "keeping") \(displayName) <\(address)> (already configured)")
                continue
            }
            // New account — needs a password.
            if dryRun {
                print("accounts: would add \(displayName) <\(address)> (would prompt for password)")
                continue
            }
            let password: String
            if isatty(fileno(stdin)) != 0 {
                guard let cstr = getpass("Password for \(address): ") else {
                    FileHandle.standardError.write(Data("accounts: aborted (no password)\n".utf8))
                    throw ExitCode(2)
                }
                password = String(cString: cstr)
            } else {
                FileHandle.standardError.write(Data("accounts: \(address) is new but stdin is not a TTY — pre-add the account with `file13 accounts add` or run import interactively\n".utf8))
                throw ExitCode(2)
            }
            guard !password.isEmpty else {
                FileHandle.standardError.write(Data("accounts: empty password for \(address) — aborting\n".utf8))
                throw ExitCode(2)
            }
            // Use the imported id when present so re-imports are stable; otherwise mint a new one.
            let id: UUID = (raw["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            let account = Account(id: id, displayName: displayName, address: address, host: host, port: port, username: username, provider: provider)
            try store.add(account, password: password)
            print("accounts: added \(displayName) <\(address)>")
        }
    }

    private static func applyRules(_ arr: [[String: Any]], mode: ImportMode, dryRun: Bool) throws {
        let store = RuleStore()
        if mode == .replace {
            // Drop everything first so the imported set is authoritative.
            for r in store.rules {
                if !dryRun { store.remove(id: r.id) }
            }
        }
        var added = 0
        for raw in arr {
            guard
                let id = (raw["id"] as? String).flatMap(UUID.init(uuidString:)),
                let name = raw["name"] as? String,
                let enabled = raw["enabled"] as? Bool,
                let outcome = decodeOutcome(raw["outcome"])
            else {
                FileHandle.standardError.write(Data("rules: skipping incomplete entry: \(raw)\n".utf8))
                continue
            }
            let conditions = decodeConditions(raw["match"] as? [String: Any] ?? [:])
            let createdAt: Date = {
                if let s = raw["createdAt"] as? String, let d = ISO8601DateFormatter().date(from: s) { return d }
                return .now
            }()
            let rule = Rule(id: id, name: name, enabled: enabled, conditions: conditions, outcome: outcome, createdAt: createdAt)
            if !dryRun { store.upsert(rule) }
            added += 1
        }
        print("rules: \(dryRun ? "would upsert" : "upserted") \(added) rule(s)")
    }

    private static func applyCategories(_ dict: [String: String], mode: ImportMode, dryRun: Bool) throws {
        let store = SenderCategoryStore()
        if mode == .replace {
            if !dryRun { store.clearAll() }
        }
        var map: [String: SenderCategory] = [:]
        for (key, value) in dict {
            if let cat = SenderCategory(rawValue: value) { map[key.lowercased()] = cat }
        }
        if !dryRun { store.merge(map) }
        print("categories: \(dryRun ? "would merge" : "merged") \(map.count) sender(s)")
    }

    private static func applyVIPs(_ dict: [String: Any], mode: ImportMode, dryRun: Bool) throws {
        let store = VIPStore()
        if mode == .replace {
            if !dryRun { store.clearAll() }
        }
        if let pinned = dict["pinned"] as? [String] {
            for sid in pinned where !dryRun { store.pin(senderId: sid) }
            print("vips: \(dryRun ? "would pin" : "pinned") \(pinned.count)")
        }
        if let excluded = dict["excluded"] as? [String] {
            for sid in excluded where !dryRun { store.unpin(senderId: sid) }
            print("vips: \(dryRun ? "would exclude" : "excluded") \(excluded.count)")
        }
    }

    private static func applySchedule(_ raw: String, dryRun: Bool) throws {
        guard let parsed = RuleSchedule(rawValue: raw) else {
            FileHandle.standardError.write(Data("schedule: unknown value '\(raw)' — skipping\n".utf8))
            return
        }
        if !dryRun { RuleStore().schedule = parsed }
        print("schedule: \(dryRun ? "would set" : "set") rules schedule to \(parsed.rawValue)")
    }

    // MARK: - Decoders

    private static func decodeOutcome(_ raw: Any?) -> Rule.Outcome? {
        if let s = raw as? String {
            switch s {
            case "delete":      return .delete
            case "archive":     return .archive
            case "unsubscribe": return .unsubscribe
            default:            return nil
            }
        }
        if let d = raw as? [String: Any], let dest = d["move"] as? String, !dest.isEmpty {
            return .moveToFolder(dest)
        }
        return nil
    }

    private static func decodeConditions(_ raw: [String: Any]) -> Rule.Conditions {
        var c = Rule.Conditions()
        if let v = raw["fromAddressOrDomain"] as? String, !v.isEmpty { c.fromAddressOrDomain = v }
        if let v = raw["subjectContains"]    as? String, !v.isEmpty { c.subjectContains = v }
        if let v = raw["olderThanDays"]      as? Int                { c.olderThanDays = v }
        if let v = raw["isUnread"]           as? Bool               { c.isUnread = v }
        if let v = raw["category"]           as? String,
           let cat = SenderCategory(rawValue: v.lowercased())       { c.category = cat }
        return c
    }
}
