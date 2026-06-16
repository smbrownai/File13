import Foundation
import Observation

public enum RuleSchedule: String, CaseIterable, Identifiable, Hashable, Sendable {
    case manual, onLaunch, hourly, daily
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .manual:   "Manual"
        case .onLaunch: "When File13 launches"
        case .hourly:   "Every hour"
        case .daily:    "Daily at 3 AM"
        }
    }
    public var explainer: String {
        switch self {
        case .manual:   "Rules only run when you click \"Run All Rules Now\" or use ⌘⇧R."
        case .onLaunch: "Rules run once after each session finishes its initial sync."
        case .hourly:   "Rules run every hour while File13 is open."
        case .daily:    "Rules run nightly at 3 AM local time while File13 is open."
        }
    }
}

@Observable
@MainActor
public final class RuleStore {
    public private(set) var rules: [Rule] = []
    public var schedule: RuleSchedule {
        didSet {
            defaults.set(schedule.rawValue, forKey: Self.scheduleKey)
            CloudKVSync.markDirty(Self.scheduleKey, defaults: defaults)
        }
    }
    public private(set) var lastRunAt: Date?
    public private(set) var lastRunReport: RuleRunReport?

    private let fileURL: URL
    private let defaults: UserDefaults
    private static let scheduleKey = "File13.rulesSchedule"
    private static let legacyRunOnLaunchKey = "File13.rulesRunOnLaunch"
    /// UserDefaults key holding the JSON blob of all rules. Moved here from
    /// the legacy `rules.json` file so iCloud key-value sync can carry the
    /// rules across the user's Macs without filesystem plumbing. The legacy
    /// file is migrated in-place on first launch (see `load()`).
    private static let rulesKey = "File13.rules.v1"

    public init(defaults: UserDefaults = SharedDefaults.suite) {
        self.defaults = defaults
        let dir = URL.applicationSupportDirectory.appending(path: "File13")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appending(path: "rules.json")

        // Migrate the older Bool-only "run on launch" toggle.
        if let raw = defaults.string(forKey: Self.scheduleKey),
           let parsed = RuleSchedule(rawValue: raw) {
            self.schedule = parsed
        } else if defaults.bool(forKey: Self.legacyRunOnLaunchKey) {
            self.schedule = .onLaunch
            defaults.set(RuleSchedule.onLaunch.rawValue, forKey: Self.scheduleKey)
            defaults.removeObject(forKey: Self.legacyRunOnLaunchKey)
        } else {
            self.schedule = .manual
        }

        load()
    }

    public var enabledRules: [Rule] { rules.filter { $0.enabled && !$0.conditions.isEmpty } }

    public func upsert(_ rule: Rule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i] = rule
        } else {
            rules.append(rule)
        }
        save()
    }

    public func remove(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
        save()
    }

    public func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    public func move(from offsets: IndexSet, to destination: Int) {
        rules.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    public func setEnabled(id: UUID, enabled: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].enabled = enabled
        save()
    }

    public func recordRun(_ report: RuleRunReport) {
        lastRunAt = .now
        lastRunReport = report
    }

    /// Apply a JSON-encoded rule list that arrived via iCloud sync, after
    /// the user has approved the change via the pending-sync banner.
    ///
    /// Why this exists as a separate method: `rules.v1` is in the
    /// `SyncedSensitiveKeys` set because rules run *automatically* on
    /// the user's schedule — `runRulesOnLaunchIfNeeded` fires at app
    /// launch when the schedule is `.onLaunch`, and the hourly/daily
    /// loops fire while the app is open. An attacker who can inject a
    /// rule via iCloud (account compromise) gets mass-deletion at the
    /// next tick with no undo buffer in the rule path. The mirror
    /// routes incoming rule changes through `PendingSyncChangesStore`;
    /// this method is the explicit "user reviewed and approves" commit.
    public func applySyncedRules(from data: Data) {
        guard let decoded = try? JSONDecoder().decode([Rule].self, from: data) else { return }
        rules = decoded
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let reencoded = try? encoder.encode(rules) {
            defaults.set(reencoded, forKey: Self.rulesKey)
        }
        // Don't mark dirty — the synced source is authoritative for this
        // accepted change. Also write the legacy file so a downgrade
        // still works.
        let prettyEncoder = JSONEncoder()
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let pretty = try? prettyEncoder.encode(rules) {
            try? pretty.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        // Primary path: UserDefaults JSON blob (so iCloud sync can carry it).
        if let data = defaults.data(forKey: Self.rulesKey),
           let decoded = try? JSONDecoder().decode([Rule].self, from: data) {
            rules = decoded
            return
        }
        // Fallback: legacy `rules.json` file. Read it once, then migrate the
        // contents into UserDefaults via `save()`. Leave the file alone so a
        // downgrade to an older build still finds its rules.
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Rule].self, from: data) else { return }
        rules = decoded
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rules) else { return }
        defaults.set(data, forKey: Self.rulesKey)
        CloudKVSync.markDirty(Self.rulesKey, defaults: defaults)
        // Also keep `rules.json` written so a user reverting to an older
        // build still sees their rules. Pretty-printed for readability.
        let prettyEncoder = JSONEncoder()
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let pretty = try? prettyEncoder.encode(rules) {
            try? pretty.write(to: fileURL, options: .atomic)
        }
    }
}

public struct RuleRunReport: Sendable, Hashable {
    public struct Action: Identifiable, Sendable, Hashable {
        public let id: UUID
        public let ruleName: String
        public let count: Int
        public let outcomeLabel: String
        public init(id: UUID, ruleName: String, count: Int, outcomeLabel: String) {
            self.id = id
            self.ruleName = ruleName
            self.count = count
            self.outcomeLabel = outcomeLabel
        }
    }
    public let actions: [Action]
    public let skipReason: String?
    /// Messages that matched a rule's conditions but were spared because the user has the
    /// "Protect transactional" setting on (receipts, invoices, etc.).
    public var protectedFromRules: Int = 0

    public init(actions: [Action], skipReason: String?, protectedFromRules: Int = 0) {
        self.actions = actions
        self.skipReason = skipReason
        self.protectedFromRules = protectedFromRules
    }

    public var totalAffected: Int { actions.reduce(0) { $0 + $1.count } }
    public var ranAnything: Bool { !actions.isEmpty }
}
