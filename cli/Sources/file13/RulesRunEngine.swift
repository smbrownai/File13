import ArgumentParser
import File13Core
import Foundation
import SwiftData

/// Engine for `file13 rules run`. Mirrors `InboxStore.runRules` from the GUI side
/// but talks to `SwiftMailIMAPClient` directly so it can run completely headless.
///
/// Per account: connect → optional refresh → for each enabled rule, filter cached
/// headers (with VIP + transactional protections), commit per-rule outcomes (delete /
/// archive / move) → disconnect.
@MainActor
enum RulesRunEngine {
    static func execute(ruleId: UUID?, accountId: UUID?, dryRun: Bool, noRefresh: Bool, json: Bool) async throws {
        // Lock first.
        let lock = LockFile()
        switch lock.tryAcquire() {
        case .acquired: break
        case .heldByOther:
            FileHandle.standardError.write(Data("File13.app is running — close it before `file13 rules run`.\n".utf8))
            throw ExitCode(2)
        case .error(let m):
            FileHandle.standardError.write(Data("lock error: \(m)\n".utf8))
            throw ExitCode(3)
        }
        defer { lock.release() }

        let settings       = SettingsStore()
        let ruleStore      = RuleStore()
        let accountStore   = AccountStore()
        let categoryStore  = SenderCategoryStore()
        let vipStore       = VIPStore()

        // Pick rules.
        var rulesToRun = ruleStore.enabledRules.filter { $0.outcome.isSupported }
        if let ruleId {
            rulesToRun = rulesToRun.filter { $0.id == ruleId }
            if rulesToRun.isEmpty {
                FileHandle.standardError.write(Data("rule \(ruleId.uuidString) is missing, disabled, or unsupported\n".utf8))
                throw ExitCode(2)
            }
        }
        if rulesToRun.isEmpty {
            print("(no enabled rules)")
            return
        }

        // Pick accounts.
        let accounts: [Account]
        if let accountId {
            accounts = accountStore.accounts.filter { $0.id == accountId }
            if accounts.isEmpty {
                FileHandle.standardError.write(Data("no account with id \(accountId.uuidString)\n".utf8))
                throw ExitCode(2)
            }
        } else {
            accounts = accountStore.accounts
        }
        if accounts.isEmpty {
            print("(no accounts configured)")
            return
        }

        // Open the shared SwiftData container.
        let modelContainer: ModelContainer
        do {
            let storeURL = SharedContainerURL.swiftDataStore()
            let config = ModelConfiguration(url: storeURL)
            modelContainer = try ModelContainer(for: CachedMessage.self, configurations: config)
        } catch {
            FileHandle.standardError.write(Data("couldn't open SwiftData container: \(error.localizedDescription)\n".utf8))
            throw ExitCode(3)
        }
        let cache = MessageCache(context: modelContainer.mainContext)

        // Snapshot the categorization and VIP sets so per-message lookups in the tight
        // filter loop don't bounce through the observable stores.
        let categoryMap = categoryStore.categories
        let categoryFor: (String) -> SenderCategory? = { categoryMap[$0.lowercased()] }
        let vipSet = vipStore.effective
        let protectVIPs = settings.protectVIPsFromRules && !vipSet.isEmpty
        let protectTransactional = settings.protectTransactionalFromDeletion && !settings.softDeleteToTrash

        // Per-rule × per-account totals for the report.
        struct Action {
            let ruleId: UUID
            let ruleName: String
            let outcomeLabel: String
            var matched: Int = 0
            var skipped: Int = 0
        }
        var actionsByRule: [UUID: Action] = [:]
        for r in rulesToRun {
            actionsByRule[r.id] = Action(
                ruleId: r.id,
                ruleName: r.name.isEmpty ? "Untitled rule" : r.name,
                outcomeLabel: r.outcome.label
            )
        }
        var perAccountReports: [[String: Any]] = []

        for account in accounts {
            let accountLine = "[\(account.displayName) <\(account.address)>]"

            // Credentials.
            let credentials: AccountCredentials
            do {
                credentials = try await accountStore.credentials(for: account)
            } catch {
                FileHandle.standardError.write(Data("\(accountLine) credential load failed: \(error.localizedDescription)\n".utf8))
                perAccountReports.append(["accountId": account.id.uuidString, "ok": false, "error": error.localizedDescription])
                continue
            }

            let session = AccountSession(account: account, cache: cache)
            await session.connect(credentials: credentials)
            if !noRefresh {
                await session.refresh()
            }
            // Resolve mailbox names once per account for archive resolution.
            let archiveName = session.archiveMailboxName

            var accountActions: [String: Int] = [:]   // ruleId.uuidString → count

            for r in rulesToRun {
                let isDeleteRule: Bool = {
                    if case .delete = r.outcome { return true }
                    return false
                }()
                let applyTransactionalProtection = protectTransactional && isDeleteRule
                let applyVIPProtection = protectVIPs && isDeleteRule

                let mailboxesForRule = mailboxesToScan(for: r, in: session)
                for mailbox in mailboxesForRule {
                    let headers = cache.loadHeaders(accountId: account.id, mailbox: mailbox)
                    if headers.isEmpty { continue }

                    let matched: [MessageHeader] = headers.filter { header in
                        if applyVIPProtection, vipSet.contains(header.senderAddress.lowercased()) { return false }
                        return RuleEvaluator.matches(header, rule: r, categoryFor: categoryFor)
                    }
                    let kept: [MessageHeader]
                    let skipped: Int
                    if applyTransactionalProtection {
                        var k: [MessageHeader] = []
                        k.reserveCapacity(matched.count)
                        for h in matched {
                            if h.isLikelyTransactional { } else { k.append(h) }
                        }
                        kept = k
                        skipped = matched.count - k.count
                    } else {
                        kept = matched
                        skipped = 0
                    }
                    actionsByRule[r.id]?.skipped += skipped
                    guard !kept.isEmpty else { continue }
                    let uids = kept.compactMap(\.uid)
                    if uids.isEmpty { continue }

                    if dryRun {
                        actionsByRule[r.id]?.matched += kept.count
                        accountActions[r.id.uuidString] = (accountActions[r.id.uuidString] ?? 0) + kept.count
                        if !json {
                            print("\(accountLine) \(r.outcome.label) \(kept.count) message(s) in \(mailbox) — \(r.name.isEmpty ? "(unnamed)" : r.name) [dry-run]")
                        }
                        continue
                    }

                    // Pin the operation to the UIDVALIDITY the local headers
                    // were captured under. If the server has rotated it, the
                    // session surfaces a "refused to delete/move" error
                    // instead of acting on stale UIDs.
                    let expectedValidity = session.uidValidity(for: mailbox)

                    switch r.outcome {
                    case .delete:
                        if settings.softDeleteToTrash, let trash = session.trashMailboxName, trash != mailbox {
                            await session.moveMessages(
                                uids: uids,
                                from: mailbox,
                                to: trash,
                                isDryRun: false,
                                expectedUIDValidity: expectedValidity
                            )
                        } else {
                            await session.deleteMessages(
                                uids: uids,
                                in: mailbox,
                                isDryRun: false,
                                expectedUIDValidity: expectedValidity
                            )
                        }
                    case .archive:
                        guard let archiveName, archiveName != mailbox else {
                            if archiveName == nil {
                                FileHandle.standardError.write(Data("\(accountLine) skipping archive — no Archive folder on this account\n".utf8))
                            }
                            continue
                        }
                        await session.moveMessages(
                            uids: uids,
                            from: mailbox,
                            to: archiveName,
                            isDryRun: false,
                            expectedUIDValidity: expectedValidity
                        )
                    case .moveToFolder(let dest):
                        guard dest != mailbox else { continue }
                        await session.moveMessages(
                            uids: uids,
                            from: mailbox,
                            to: dest,
                            isDryRun: false,
                            expectedUIDValidity: expectedValidity
                        )
                    case .unsubscribe:
                        continue
                    }
                    if let lastError = session.lastError {
                        FileHandle.standardError.write(Data("\(accountLine) \(r.outcome.label) failed in \(mailbox): \(lastError)\n".utf8))
                        continue
                    }
                    // Drop the matched ids from the local cache so the next
                    // refresh doesn't see them as "still there until the
                    // server tells us otherwise."
                    let ids = Set(kept.map(\.id))
                    let remaining = headers.filter { !ids.contains($0.id) }
                    try? cache.replaceHeaders(remaining, accountId: account.id, mailbox: mailbox)

                    actionsByRule[r.id]?.matched += kept.count
                    accountActions[r.id.uuidString] = (accountActions[r.id.uuidString] ?? 0) + kept.count
                    if !json {
                        print("\(accountLine) \(r.outcome.label) \(kept.count) message(s) in \(mailbox) — \(r.name.isEmpty ? "(unnamed)" : r.name)")
                    }
                }
            }

            await session.disconnect()
            perAccountReports.append([
                "accountId": account.id.uuidString,
                "ok": true,
                "matched": accountActions
            ])
        }

        // Summarize. `actionsByRule` was populated for every rule in
        // `rulesToRun` above, so the lookup is invariantly present —
        // but a `compactMap` here is the safer pattern in case a future
        // refactor adds an early-continue inside the population loop
        // and a rule slips through. A missing entry would just be
        // absent from the report instead of crashing the run.
        let actions = rulesToRun.compactMap { actionsByRule[$0.id] }
        let totalAffected = actions.reduce(0) { $0 + $1.matched }
        let totalSkipped  = actions.reduce(0) { $0 + $1.skipped }

        if json {
            let payload: [String: Any] = [
                "dryRun": dryRun,
                "totalAffected": totalAffected,
                "totalSkipped": totalSkipped,
                "perRule": actions.map { ["id": $0.ruleId.uuidString, "name": $0.ruleName, "outcome": $0.outcomeLabel, "matched": $0.matched, "skipped": $0.skipped] },
                "perAccount": perAccountReports
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print("")
            print("\(dryRun ? "would affect" : "affected") \(totalAffected) message(s) across \(rulesToRun.count) rule(s) (skipped: \(totalSkipped))")
        }

        if !dryRun {
            // Mirror the GUI's RuleStore.recordRun so the GUI's "last run" timestamp updates.
            let ruleActions: [RuleRunReport.Action] = actions
                .filter { $0.matched > 0 }
                .map { .init(id: $0.ruleId, ruleName: $0.ruleName, count: $0.matched, outcomeLabel: $0.outcomeLabel) }
            let report = RuleRunReport(actions: ruleActions, skipReason: nil, protectedFromRules: totalSkipped)
            ruleStore.recordRun(report)
        }
    }

    /// Resolve a rule's `RuleScope` against a session's known mailboxes. The
    /// CLI runs against whatever's already cached — it does not refresh
    /// non-active mailboxes, since `file13 rules run` is meant to be cheap
    /// and idempotent on a launchd schedule. Users who want fresh data on
    /// non-active folders should run `file13 refresh --mailbox X` first.
    @MainActor
    private static func mailboxesToScan(for rule: Rule, in session: AccountSession) -> [String] {
        switch rule.effectiveScope {
        case .currentMailbox:
            return [session.currentMailbox]
        case .folder(let name):
            // Always allow — user might be targeting a mailbox we haven't
            // listed yet. The cache lookup will return [] if nothing's there.
            return [name]
        case .allFolders:
            // Use the server's mailbox list; the cache lookup short-circuits
            // mailboxes the user hasn't synced.
            return session.mailboxes.map(\.name)
        }
    }
}
