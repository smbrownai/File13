import File13Core
import SwiftUI

/// Generic banner showing one or more pending iCloud-delivered changes
/// that require local approval before they're applied. Built once,
/// instantiated by domain-specific wrappers (`PendingAIChangesBanner`,
/// `PendingAccountChangesBanner`, `PendingRuleChangesBanner`) that each
/// own their own filter + apply logic.
///
/// **Why this exists** — defends against the iCloud-account-compromise
/// scenario where an attacker who gains write access to the user's
/// iCloud Key-Value Store could otherwise:
/// - silently re-route the user's AI traffic to a different provider
/// - rewrite an IMAP account's `host` to exfiltrate the user's password
/// - inject a destructive rule that auto-fires on the next scheduled run
///
/// With these banners, every such change has to pass through an explicit
/// user confirmation on this device. See `SyncedSensitiveKeys` for the
/// list of keys this protects.
struct PendingSyncChangesBanner: View {
    /// Configuration provided by each call site so the banner stays
    /// agnostic about *which* setting changed.
    struct Config {
        /// Display title for the banner — e.g. "AI settings changed
        /// on another device."
        let title: String
        /// One-liner under the title.
        let summary: String
        /// Filters `PendingSyncChangesStore.loadAll()` to the keys this
        /// banner is responsible for.
        let keys: Set<String>
        /// Human-readable per-key label for the diff list.
        /// `@MainActor`: only ever invoked while rendering the banner, and
        /// some implementations read main-actor state (`SharedDefaults.suite`).
        let labelForKey: @MainActor (String) -> String
        /// Human-readable "current → incoming" summary line for one
        /// pending item.
        let diffSummary: @MainActor (PendingSyncChangesStore.Pending) -> String
        /// Apply one pending item to the corresponding store. Called
        /// synchronously from the main actor.
        let apply: @MainActor (PendingSyncChangesStore.Pending) -> Void
    }

    let config: Config

    @State private var pending: [String: PendingSyncChangesStore.Pending] = [:]

    var body: some View {
        if !pending.isEmpty {
            content
                .task { reload() }
                .onReceive(NotificationCenter.default.publisher(for: .pendingSyncChangesUpdated)) { _ in
                    reload()
                }
        } else {
            // Still subscribe so the banner appears when a remote change
            // arrives while this view is on-screen.
            Color.clear
                .frame(height: 0)
                .task { reload() }
                .onReceive(NotificationCenter.default.publisher(for: .pendingSyncChangesUpdated)) { _ in
                    reload()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 4) {
                    Text(config.title)
                        .font(.headline)
                    Text(config.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(pending.keys.sorted()), id: \.self) { key in
                    if let item = pending[key] {
                        diffRow(for: item)
                    }
                }
            }
            .padding(.leading, 28)

            HStack {
                Spacer()
                Button("Discard", role: .destructive) {
                    discardAll()
                }
                Button("Apply") {
                    applyAll()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3))
        )
    }

    @ViewBuilder
    private func diffRow(for item: PendingSyncChangesStore.Pending) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.labelForKey(item.key))
                    .font(.system(size: 13, weight: .medium))
                Text(config.diffSummary(item))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func applyAll() {
        for item in pending.values {
            config.apply(item)
            PendingSyncChangesStore.clear(item.key)
        }
        reload()
        NotificationCenter.default.post(name: .pendingSyncChangesUpdated, object: nil)
    }

    private func discardAll() {
        // Mark every dropped key dirty so the *local* (unchanged) value
        // gets pushed back to iCloud on the next flush. Other devices
        // then converge on this device's choice, undoing the attempted
        // remote change.
        for key in pending.keys {
            CloudKVSync.markDirty(key)
            PendingSyncChangesStore.clear(key)
        }
        reload()
        NotificationCenter.default.post(name: .pendingSyncChangesUpdated, object: nil)
    }

    private func reload() {
        let all = PendingSyncChangesStore.loadAll()
        pending = all.filter { config.keys.contains($0.key) }
    }
}

// MARK: - AI settings wrapper

/// Pending-changes banner for the AI tab: provider, model, per-feature
/// tuning. See `PendingSyncChangesBanner` and `SyncedSensitiveKeys` for
/// the threat model.
struct PendingAIChangesBanner: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        PendingSyncChangesBanner(config: .init(
            title: "AI settings changed on another device",
            summary: "These changes haven't been applied on this Mac. Review them before accepting — they affect which provider sees your email metadata.",
            keys: SyncedSensitiveKeys.aiKeys,
            labelForKey: { Self.label(for: $0) },
            diffSummary: { Self.summary(for: $0) },
            apply: { item in self.apply(item: item) }
        ))
    }

    private static func label(for key: String) -> String {
        switch key {
        case SyncedSensitiveKeys.aiProvider:      "Provider"
        case SyncedSensitiveKeys.aiModel:         "Model"
        case SyncedSensitiveKeys.aiFeatureTuning: "Per-feature tuning (custom instructions / overrides)"
        default:                                   key
        }
    }

    private static func summary(for item: PendingSyncChangesStore.Pending) -> String {
        let defaults = SharedDefaults.suite
        switch item.key {
        case SyncedSensitiveKeys.aiProvider:
            let current = defaults.string(forKey: item.key) ?? "(default)"
            let incoming = (item.decodedRemote() as? String) ?? "(default)"
            return "\(current)  →  \(incoming)"
        case SyncedSensitiveKeys.aiModel:
            let local = defaults.string(forKey: item.key) ?? ""
            let incomingRaw = (item.decodedRemote() as? String) ?? ""
            let current = local.isEmpty ? "(default)" : local
            let incoming = incomingRaw.isEmpty ? "(default)" : incomingRaw
            return "\(current)  →  \(incoming)"
        case SyncedSensitiveKeys.aiFeatureTuning:
            return "tuning differs — inspect per-feature rows after applying"
        default:
            return "value changed"
        }
    }

    private func apply(item: PendingSyncChangesStore.Pending) {
        switch item.key {
        case SyncedSensitiveKeys.aiProvider:
            if let rawValue = item.decodedRemote() as? String,
               let kind = AIProviderKind(rawValue: rawValue) {
                settings.aiProvider = kind
            }
        case SyncedSensitiveKeys.aiModel:
            if let model = item.decodedRemote() as? String {
                settings.aiModel = model
            }
        case SyncedSensitiveKeys.aiFeatureTuning:
            if let data = item.decodedRemote() as? Data,
               let decoded = try? JSONDecoder().decode([String: AIFeatureTuning].self, from: data) {
                settings.aiFeatureTuning = decoded
            }
        default:
            break
        }
    }
}

// MARK: - Accounts wrapper

/// Pending-changes banner for the Accounts tab. Protects against the
/// `host`-hijack-via-iCloud attack: rewriting an account's host would
/// otherwise leak the user's IMAP password to the attacker's server on
/// the next refresh, because the password is keyed by account UUID in
/// the Keychain — not by host. This banner gates that change behind an
/// explicit user-on-this-device confirmation.
struct PendingAccountChangesBanner: View {
    @Bindable var accountStore: AccountStore

    var body: some View {
        PendingSyncChangesBanner(config: .init(
            title: "Account list changed on another device",
            summary: "iCloud delivered changes to your account list — host, port, or username. Review before accepting; an attacker with access to your iCloud account could otherwise rewrite an account's host and capture your password on the next refresh.",
            keys: SyncedSensitiveKeys.accountKeys,
            labelForKey: { _ in "Accounts list (host / port / username)" },
            diffSummary: { Self.summary(for: $0) },
            apply: { item in self.apply(item: item) }
        ))
    }

    /// Per-account diff line. The default summary used to be a useless
    /// "incoming list has N accounts" — which is exactly what the
    /// `host`-hijack attack relies on the user not looking at. This now
    /// names every account that's being added, removed, or modified, and
    /// for modified ones lists the field-level change (with a special
    /// callout for `host`, `port`, `username` since those are the ones an
    /// attacker would use to redirect the next refresh to their server).
    private static func summary(for item: PendingSyncChangesStore.Pending) -> String {
        guard let data = item.decodedRemote() as? Data,
              let incoming = try? JSONDecoder().decode([Account].self, from: data) else {
            return "accounts differ — couldn't decode incoming snapshot"
        }
        let local = Self.localAccounts()
        return Self.renderDiff(local: local, incoming: incoming)
    }

    /// Reads the locally-persisted accounts snapshot directly from the
    /// shared defaults rather than via `AccountStore`, so the static
    /// `summary` closure doesn't have to capture an `@Bindable` store.
    /// `summary` runs synchronously inside the banner's body — a stale
    /// read here is fine because the banner is invalidated the moment the
    /// user clicks Apply or Discard.
    private static func localAccounts() -> [Account] {
        guard let data = SharedDefaults.suite.data(forKey: SyncedSensitiveKeys.accounts),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Multi-line, monospaced-friendly diff. Order: removed first
    /// (security-critical — "where did my account go?"), then modified
    /// (host/port/user changes — the host-hijack signal), then added
    /// (lowest-stakes — user can decline). Identifier for matching is
    /// the account UUID; an attacker who reuses an existing UUID but
    /// rewrites the host shows up as "modified", which is what we want
    /// to highlight.
    private static func renderDiff(local: [Account], incoming: [Account]) -> String {
        // `uniquingKeysWith` (not `uniqueKeysWithValues`) so a malicious
        // payload with duplicate UUIDs doesn't trap the renderer. Last
        // value wins on collision — good enough for a diff display.
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let incomingByID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let allIDs = Set(localByID.keys).union(incomingByID.keys)

        var removed: [String] = []
        var modified: [String] = []
        var added: [String] = []

        for id in allIDs {
            switch (localByID[id], incomingByID[id]) {
            case (let .some(lhs), nil):
                removed.append("removed: \(lhs.displayName) <\(lhs.address)>")
            case (nil, let .some(rhs)):
                added.append("added: \(rhs.displayName) <\(rhs.address)>  →  \(rhs.username)@\(rhs.host):\(rhs.port)")
            case (let .some(lhs), let .some(rhs)):
                let fieldDiffs = Self.fieldDiffs(lhs: lhs, rhs: rhs)
                if !fieldDiffs.isEmpty {
                    let header = "modified: \(lhs.displayName) <\(lhs.address)>"
                    modified.append(([header] + fieldDiffs.map { "  • \($0)" }).joined(separator: "\n"))
                }
            case (nil, nil):
                continue
            }
        }

        let sections = removed.sorted() + modified.sorted() + added.sorted()
        if sections.isEmpty {
            return "no field-level changes (counts may have drifted)"
        }
        return sections.joined(separator: "\n")
    }

    private static func fieldDiffs(lhs: Account, rhs: Account) -> [String] {
        var lines: [String] = []
        if lhs.host != rhs.host { lines.append("host:     \(lhs.host)  →  \(rhs.host)") }
        if lhs.port != rhs.port { lines.append("port:     \(lhs.port)  →  \(rhs.port)") }
        if lhs.username != rhs.username { lines.append("username: \(lhs.username)  →  \(rhs.username)") }
        if lhs.address != rhs.address { lines.append("address:  \(lhs.address)  →  \(rhs.address)") }
        if lhs.displayName != rhs.displayName { lines.append("name:     \(lhs.displayName)  →  \(rhs.displayName)") }
        if lhs.authKind != rhs.authKind { lines.append("auth:     \(lhs.authKind.rawValue)  →  \(rhs.authKind.rawValue)") }
        if lhs.provider != rhs.provider { lines.append("provider: \(lhs.provider.rawValue)  →  \(rhs.provider.rawValue)") }
        return lines
    }

    private func apply(item: PendingSyncChangesStore.Pending) {
        guard item.key == SyncedSensitiveKeys.accounts,
              let data = item.decodedRemote() as? Data else { return }
        accountStore.applySyncedAccounts(from: data)
    }
}

// MARK: - Rules wrapper

/// Pending-changes banner for the Rules tab. Protects against rule
/// injection via iCloud: an `enabled: true` rule with `outcome: .delete`
/// fires at the next scheduled run (or app launch, for `.onLaunch`)
/// **without** an undo buffer. This banner gates that change behind an
/// explicit user-on-this-device confirmation.
struct PendingRuleChangesBanner: View {
    @Bindable var ruleStore: RuleStore

    var body: some View {
        PendingSyncChangesBanner(config: .init(
            title: "Rules changed on another device",
            summary: "iCloud delivered changes to your rules. Rules can delete, archive, or move mail automatically — review carefully. An attacker with access to your iCloud account could otherwise inject a destructive rule that fires on the next scheduled run.",
            keys: SyncedSensitiveKeys.ruleKeys,
            labelForKey: { _ in "Rules" },
            diffSummary: { Self.summary(for: $0) },
            apply: { item in self.apply(item: item) }
        ))
    }

    private static func summary(for item: PendingSyncChangesStore.Pending) -> String {
        guard let data = item.decodedRemote() as? Data,
              let incoming = try? JSONDecoder().decode([Rule].self, from: data) else {
            return "rules differ"
        }
        let count = incoming.count
        let enabled = incoming.filter { $0.enabled }.count
        return "incoming list has \(count) rule\(count == 1 ? "" : "s") — \(enabled) enabled"
    }

    private func apply(item: PendingSyncChangesStore.Pending) {
        guard item.key == SyncedSensitiveKeys.rules,
              let data = item.decodedRemote() as? Data else { return }
        ruleStore.applySyncedRules(from: data)
    }
}

// MARK: - Safety toggles wrapper

/// Pending-changes banner for Actions & Safety: undo buffer, dry-run,
/// soft-delete-to-trash, confirm-before-delete/unsubscribe, the two
/// "protect from rules" toggles. These don't change the *contents* of
/// rules — the rule banner covers that — but they govern the guard rails
/// rules execute under. A synced flip to `protectVIPsFromRules = false`
/// or `undoBufferSeconds = 5` weakens those guard rails silently
/// otherwise.
struct PendingSafetyChangesBanner: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        PendingSyncChangesBanner(config: .init(
            title: "Safety settings changed on another device",
            summary: "iCloud delivered changes to your destructive-action guard rails — undo buffer, confirmations, dry-run, or VIP / transactional protection. Review before accepting; weakening these is how a compromised iCloud account would make subsequent rule runs unsafe.",
            keys: SyncedSensitiveKeys.safetyKeys,
            labelForKey: { Self.label(for: $0) },
            diffSummary: { Self.summary(for: $0) },
            apply: { item in self.apply(item: item) }
        ))
    }

    private static func label(for key: String) -> String {
        switch key {
        case SyncedSensitiveKeys.undoBufferSeconds:          "Undo buffer (seconds)"
        case SyncedSensitiveKeys.confirmBeforeDelete:        "Confirm before delete"
        case SyncedSensitiveKeys.confirmBeforeUnsubscribe:   "Confirm before unsubscribe"
        case SyncedSensitiveKeys.dryRunMode:                 "Dry-run mode"
        case SyncedSensitiveKeys.softDeleteToTrash:          "Handling of deleted items"
        case SyncedSensitiveKeys.protectVIPsFromRules:       "Protect VIPs from deletion"
        case SyncedSensitiveKeys.protectTransactionalFromRules: "Protect transactions from deletion"
        default:                                              key
        }
    }

    private static func summary(for item: PendingSyncChangesStore.Pending) -> String {
        let defaults = SharedDefaults.suite
        let incoming = item.decodedRemote()
        switch item.key {
        case SyncedSensitiveKeys.undoBufferSeconds:
            let current = (defaults.object(forKey: item.key) as? Int) ?? 30
            let next = (incoming as? Int) ?? current
            return "\(current)s  →  \(next)s"
        case SyncedSensitiveKeys.softDeleteToTrash:
            let current = (defaults.object(forKey: item.key) as? Bool) ?? false
            let next = (incoming as? Bool) ?? current
            return "\(current ? "Move to Trash" : "Delete permanently")  →  \(next ? "Move to Trash" : "Delete permanently")"
        default:
            let current = (defaults.object(forKey: item.key) as? Bool) ?? false
            let next = (incoming as? Bool) ?? current
            return "\(current ? "On" : "Off")  →  \(next ? "On" : "Off")"
        }
    }

    private func apply(item: PendingSyncChangesStore.Pending) {
        let value = item.decodedRemote()
        switch item.key {
        case SyncedSensitiveKeys.undoBufferSeconds:
            if let v = value as? Int { settings.undoBufferSeconds = v }
        case SyncedSensitiveKeys.confirmBeforeDelete:
            if let v = value as? Bool { settings.confirmBeforeDelete = v }
        case SyncedSensitiveKeys.confirmBeforeUnsubscribe:
            if let v = value as? Bool { settings.confirmBeforeUnsubscribe = v }
        case SyncedSensitiveKeys.dryRunMode:
            if let v = value as? Bool { settings.dryRunMode = v }
        case SyncedSensitiveKeys.softDeleteToTrash:
            if let v = value as? Bool { settings.softDeleteToTrash = v }
        case SyncedSensitiveKeys.protectVIPsFromRules:
            if let v = value as? Bool { settings.protectVIPsFromRules = v }
        case SyncedSensitiveKeys.protectTransactionalFromRules:
            if let v = value as? Bool { settings.protectTransactionalFromDeletion = v }
        default:
            break
        }
    }
}

// MARK: - VIPs wrapper

/// Pending-changes banner for the VIP set. Synced VIP changes can
/// silently remove VIP-protection from senders (additions to `excluded`)
/// or drop user pins. Gated behind explicit user-on-this-device
/// confirmation — same pattern as accounts / rules.
struct PendingVIPChangesBanner: View {
    @Bindable var vipStore: VIPStore

    var body: some View {
        PendingSyncChangesBanner(config: .init(
            title: "VIP list changed on another device",
            summary: "iCloud delivered changes to your VIPs — pinned, excluded, or auto-detected. Review before accepting; an attacker with access to your iCloud account could otherwise add senders to the excluded list, bypassing the VIP-protection-from-rules guard rail.",
            keys: SyncedSensitiveKeys.vipKeys,
            labelForKey: { _ in "VIP set (pinned / excluded / auto-detected)" },
            diffSummary: { Self.summary(for: $0) },
            apply: { item in self.apply(item: item) }
        ))
    }

    private static func summary(for item: PendingSyncChangesStore.Pending) -> String {
        guard let data = item.decodedRemote() as? Data,
              let incoming = try? JSONDecoder().decode(VIPStoredStateView.self, from: data) else {
            return "VIP set differs"
        }
        return "incoming: \(incoming.pinned.count) pinned, \(incoming.excluded.count) excluded, \(incoming.autoDetected.count) auto-detected"
    }

    private func apply(item: PendingSyncChangesStore.Pending) {
        guard item.key == SyncedSensitiveKeys.vipSenders,
              let data = item.decodedRemote() as? Data else { return }
        vipStore.applySyncedState(from: data)
    }
}

/// Decode-only mirror of `VIPStore.StoredState` so the banner can show
/// the diff without reaching into the store's private nested type. The
/// JSON shape must match — Swift's default Codable synthesis on both
/// sides uses alphabetical keys, so this stays in sync as long as the
/// property names match.
private struct VIPStoredStateView: Decodable {
    var autoDetected: Set<String>
    var pinned: Set<String>
    var excluded: Set<String>
    var lastDetectionAt: Date?
}

// MARK: - Replied-messages wrapper

/// Pending-changes banner for the per-account replied-message index.
/// `VIPDetector`'s reply path auto-promotes a sender to VIP after >=2
/// recorded replies — a forged "user replied to them" record arriving
/// via iCloud can elevate an attacker to VIP-status. Gated behind
/// explicit user-on-this-device confirmation.
struct PendingRepliedMessagesChangesBanner: View {
    @Bindable var repliedStore: RepliedMessagesStore

    var body: some View {
        PendingSyncChangesBanner(config: .init(
            title: "Replied-message records changed on another device",
            summary: "iCloud delivered changes to the per-account list of messages you've replied to. Review before accepting; replied-to senders can be auto-promoted to VIP, which an attacker could exploit to elevate a sender they control.",
            keys: SyncedSensitiveKeys.repliedKeys,
            labelForKey: { _ in "Replied-messages index" },
            diffSummary: { Self.summary(for: $0) },
            apply: { item in self.apply(item: item) }
        ))
    }

    private static func summary(for item: PendingSyncChangesStore.Pending) -> String {
        guard let data = item.decodedRemote() as? Data,
              let incoming = try? JSONDecoder().decode([UUID: Set<String>].self, from: data) else {
            return "replied-messages map differs"
        }
        let accounts = incoming.count
        let total = incoming.values.reduce(0) { $0 + $1.count }
        return "incoming: \(total) replied-message id\(total == 1 ? "" : "s") across \(accounts) account\(accounts == 1 ? "" : "s")"
    }

    private func apply(item: PendingSyncChangesStore.Pending) {
        guard item.key == SyncedSensitiveKeys.repliedMessages,
              let data = item.decodedRemote() as? Data else { return }
        repliedStore.applySyncedState(from: data)
    }
}

// MARK: - Sender-categories wrapper

/// Pending-changes banner for sender-category sync. Flipping a sender's
/// category (e.g. promotional → personal) can re-route which rules apply.
/// Lower-impact than VIPs / replied because categories are visible in the
/// Activity dashboard, but worth gating anyway.
struct PendingCategoriesChangesBanner: View {
    @Bindable var categoryStore: SenderCategoryStore

    var body: some View {
        PendingSyncChangesBanner(config: .init(
            title: "Sender categories changed on another device",
            summary: "iCloud delivered changes to the AI-assigned sender categories. Category-conditional rules apply differently when categories flip — review before accepting.",
            keys: SyncedSensitiveKeys.categoryKeys,
            labelForKey: { _ in "Sender categories" },
            diffSummary: { Self.summary(for: $0) },
            apply: { item in self.apply(item: item) }
        ))
    }

    private static func summary(for item: PendingSyncChangesStore.Pending) -> String {
        guard let data = item.decodedRemote() as? Data,
              let incoming = SenderCategoryStore.decodeSnapshot(data) else {
            return "categories differ"
        }
        let local = SenderCategoryStore.decodeSnapshot(
            SharedDefaults.suite.data(forKey: SyncedSensitiveKeys.senderCategories) ?? Data()
        ) ?? [:]
        let added = incoming.keys.filter { local[$0] == nil }.count
        let changed = incoming.filter { local[$0.key] != nil && local[$0.key] != $0.value }.count
        let removed = local.keys.filter { incoming[$0] == nil }.count
        return "incoming: +\(added) added · \(changed) changed · −\(removed) removed"
    }

    private func apply(item: PendingSyncChangesStore.Pending) {
        guard item.key == SyncedSensitiveKeys.senderCategories,
              let data = item.decodedRemote() as? Data else { return }
        categoryStore.applySyncedState(from: data)
    }
}
