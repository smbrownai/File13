import ArgumentParser
import File13Core
import Foundation
import SwiftData

/// `file13 mail delete|archive|move` — sender-scoped mail operations.
///
/// Resolves the target sender set from the same flag soup `senders list` uses
/// (`--sender`, `--senders-file`, stdin pipe, `--domain`, `--category`, `--vip`),
/// loads matching headers from the SwiftData cache, then commits to IMAP via
/// SwiftMailIMAPClient. No buffered/optimistic pattern — the GUI's undo buffer is a
/// view-side affordance; the CLI commits synchronously and reports per-account counts.
///
/// Protections honored by default:
///   - `protectTransactionalFromDeletion` skips transactional headers from `delete`
///     unless `--no-protect` is passed (which requires `--yes`).
///   - VIP protection on rule runs is unchanged — manual `mail` commands deliberately
///     don't auto-skip VIPs (the user typing the command is explicit).
struct MailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Delete, archive, or move messages by sender (or group of senders).",
        subcommands: [Delete.self, Archive.self, Move.self]
    )

    // MARK: - Sender selection (shared across delete/archive/move)

    struct SenderSelection: ParsableArguments {
        @Option(name: .long, help: "Comma-separated sender addresses (repeatable). e.g. `--sender a@x.com,b@y.com`.")
        var sender: [String] = []

        @Option(name: .long, help: "File of sender addresses, one per line. Use `-` for stdin.")
        var sendersFile: String?

        @Option(name: .long, help: "Sender domain (case-insensitive @<domain> suffix). Repeatable.")
        var domain: [String] = []

        @Option(name: .long, help: "AI category (personal, work, finance, commerce, news, social, promotional, notifications, other).")
        var category: String?

        @Flag(name: .long, help: "Include all current VIP senders. Combine with --yes for destructive ops.")
        var vip: Bool = false

        @Option(name: .long, help: "Limit to one account UUID. Default: every account.")
        var account: String?

        @Option(name: .long, help: "Mailbox to operate on. Default: INBOX.")
        var mailbox: String = "INBOX"
    }

    struct CommonOptions: ParsableArguments {
        @Flag(name: .long, help: "Show what would happen without committing.")
        var dryRun: Bool = false

        @Flag(name: .shortAndLong, help: "Skip confirmation prompts.")
        var yes: Bool = false

        @Flag(name: .long, help: "Skip the implicit refresh before evaluating the cache.")
        var noRefresh: Bool = false

        @Flag(name: .long, help: "Emit a JSON report instead of plain text.")
        var json: Bool = false
    }

    // MARK: - Subcommands

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Permanently delete messages from the chosen senders.")
        @OptionGroup var senders: SenderSelection
        @OptionGroup var common: CommonOptions
        @Flag(name: .long, help: "Bypass `protectTransactionalFromDeletion`. Requires --yes.")
        var noProtect: Bool = false

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            try await Mail.execute(operation: .delete(noProtect: noProtect), selection: senders, common: common)
        }
    }

    struct Archive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move messages from the chosen senders to the account's Archive folder.")
        @OptionGroup var senders: SenderSelection
        @OptionGroup var common: CommonOptions

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            try await Mail.execute(operation: .archive, selection: senders, common: common)
        }
    }

    struct Move: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move messages from the chosen senders to a named folder.")
        @OptionGroup var senders: SenderSelection
        @OptionGroup var common: CommonOptions
        @Option(name: .long, help: "Destination folder (mailbox path on the server).")
        var to: String

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            try await Mail.execute(operation: .move(folder: to), selection: senders, common: common)
        }
    }
}

// MARK: - Engine

private enum Mail {
    enum Operation {
        case delete(noProtect: Bool)
        case archive
        case move(folder: String)

        var verb: String {
            switch self {
            case .delete:  "delete"
            case .archive: "archive"
            case .move:    "move"
            }
        }
    }

    @MainActor
    static func execute(operation: Operation,
                        selection: MailCommand.SenderSelection,
                        common: MailCommand.CommonOptions) async throws {
        // Lock first.
        let lock = LockFile()
        switch lock.tryAcquire() {
        case .acquired: break
        case .heldByOther:
            FileHandle.standardError.write(Data("File13.app is running — close it before mail operations.\n".utf8))
            throw ExitCode(2)
        case .error(let m):
            FileHandle.standardError.write(Data("lock error: \(m)\n".utf8))
            throw ExitCode(3)
        }
        defer { lock.release() }

        // Stores.
        let accountStore = AccountStore()
        let categoryStore = SenderCategoryStore()
        let vipStore = VIPStore()
        let settings = SettingsStore()

        // Account scope.
        let accountFilter: UUID?
        if let raw = selection.account {
            guard let uuid = UUID(uuidString: raw) else {
                FileHandle.standardError.write(Data("not a valid UUID: \(raw)\n".utf8))
                throw ExitCode(2)
            }
            accountFilter = uuid
        } else {
            accountFilter = nil
        }
        let accounts: [Account]
        if let accountFilter {
            accounts = accountStore.accounts.filter { $0.id == accountFilter }
            if accounts.isEmpty {
                FileHandle.standardError.write(Data("no account with id \(accountFilter.uuidString)\n".utf8))
                throw ExitCode(2)
            }
        } else {
            accounts = accountStore.accounts
        }
        if accounts.isEmpty {
            print("(no accounts configured)")
            return
        }

        // Resolve the sender address set from every flag.
        var senderAddresses = Set<String>()
        for s in selection.sender {
            for piece in s.split(separator: ",") {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !trimmed.isEmpty { senderAddresses.insert(trimmed) }
            }
        }
        if let path = selection.sendersFile {
            let content: String
            if path == "-" {
                content = String(data: FileHandle.standardInput.availableData, encoding: .utf8) ?? ""
            } else {
                content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            }
            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !trimmed.isEmpty, !trimmed.hasPrefix("#") { senderAddresses.insert(trimmed) }
            }
        }
        // Auto-detect a piped stdin (no terminal): treat as senders-file when nothing else
        // narrowed the selection. Avoids a stuck read when stdin is the user's terminal.
        if selection.sender.isEmpty, selection.sendersFile == nil,
           selection.domain.isEmpty, selection.category == nil, !selection.vip,
           isatty(fileno(stdin)) == 0 {
            let content = String(data: FileHandle.standardInput.availableData, encoding: .utf8) ?? ""
            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !trimmed.isEmpty, !trimmed.hasPrefix("#") { senderAddresses.insert(trimmed) }
            }
        }

        // Domain expansion needs cached senders, handled below.
        let domainFilters = Set(selection.domain.map { $0.lowercased() })

        // Category filter.
        let categoryFilter: SenderCategory?
        if let raw = selection.category {
            guard let parsed = SenderCategory(rawValue: raw.lowercased()) else {
                FileHandle.standardError.write(Data("unknown category: \(raw)\n".utf8))
                throw ExitCode(2)
            }
            categoryFilter = parsed
        } else {
            categoryFilter = nil
        }

        // Open the SwiftData store so we can resolve sender → message ids.
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

        // Optionally refresh first so the cache reflects the live mailbox state.
        if !common.noRefresh {
            for acc in accounts {
                let creds: AccountCredentials
                do {
                    creds = try await accountStore.credentials(for: acc)
                } catch {
                    FileHandle.standardError.write(Data("[\(acc.displayName)] credential load failed: \(error.localizedDescription)\n".utf8))
                    continue
                }
                let session = AccountSession(account: acc, cache: cache)
                await session.connect(credentials: creds)
                await session.refresh()
                await session.disconnect()
            }
        }

        // Build the per-account work plan.
        struct Plan {
            let account: Account
            var headers: [MessageHeader]   // matching, post-filter, post-protection
            var skipped: Int               // protected/excluded, for the report
        }
        var plans: [Plan] = []
        let dryRun = common.dryRun || settings.dryRunMode
        let respectTransactional: Bool = {
            switch operation {
            case .delete(let noProtect):
                if noProtect { return false }
                // Protection waived if user is sending to Trash anyway.
                return settings.protectTransactionalFromDeletion && !settings.softDeleteToTrash
            case .archive, .move:
                return false
            }
        }()
        let respectVIPs: Bool = {
            switch operation {
            case .delete(let noProtect):
                if noProtect { return false }
                return settings.protectVIPsFromRules
            case .archive, .move:
                return false
            }
        }()
        let vipSet: Set<String> = respectVIPs ? vipStore.effective : []

        for acc in accounts {
            let allHeaders = cache.loadHeaders(accountId: acc.id, mailbox: selection.mailbox)
            let senders = allHeaders.groupedBySender()

            var matchedSenderIds = Set<String>()
            for s in senders {
                let addr = s.address.lowercased()
                if senderAddresses.contains(addr) { matchedSenderIds.insert(s.id); continue }
                if domainFilters.contains(where: { addr.hasSuffix("@\($0)") }) { matchedSenderIds.insert(s.id); continue }
                if let cat = categoryFilter, categoryStore.category(for: s.id) == cat { matchedSenderIds.insert(s.id); continue }
                if selection.vip, vipStore.isVIP(senderId: s.id) { matchedSenderIds.insert(s.id); continue }
            }
            let candidate = allHeaders.filter { matchedSenderIds.contains($0.senderAddress.lowercased()) }
            let kept: [MessageHeader]
            let skipped: Int
            if respectTransactional || !vipSet.isEmpty {
                let safe = candidate.filter { header in
                    if respectTransactional, header.isLikelyTransactional { return false }
                    if !vipSet.isEmpty, vipSet.contains(header.senderAddress.lowercased()) { return false }
                    return true
                }
                kept = safe
                skipped = candidate.count - safe.count
            } else {
                kept = candidate
                skipped = 0
            }
            plans.append(Plan(account: acc, headers: kept, skipped: skipped))
        }

        let totalAffected = plans.reduce(0) { $0 + $1.headers.count }
        let totalSenders = Set(plans.flatMap { $0.headers.map { $0.senderAddress.lowercased() } }).count
        let totalSkipped = plans.reduce(0) { $0 + $1.skipped }

        if totalAffected == 0 {
            if common.json {
                let dict: [String: Any] = ["operation": operation.verb, "messageCount": 0, "senderCount": 0, "skipped": totalSkipped, "dryRun": dryRun]
                let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                print("(nothing to \(operation.verb) — no headers matched)")
                if totalSkipped > 0 {
                    print("\(totalSkipped) message(s) were skipped due to transactional protection")
                }
            }
            return
        }

        // Confirmation gate.
        if !dryRun, !common.yes, isatty(fileno(stdin)) != 0 {
            let promptShouldFire: Bool = {
                switch operation {
                case .delete:  return settings.confirmBeforeDelete
                case .archive, .move: return false
                }
            }()
            if promptShouldFire {
                print("\(operation.verb.capitalized) \(totalAffected) message(s) from \(totalSenders) sender(s) across \(plans.count) account(s)? [y/N] ", terminator: "")
                let ans = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard ans == "y" || ans == "yes" else {
                    print("aborted")
                    throw ExitCode(0)
                }
            }
        }

        // Execute.
        var perAccount: [[String: Any]] = []
        for plan in plans where !plan.headers.isEmpty {
            let line = "[\(plan.account.displayName)]"
            let uids = plan.headers.compactMap { $0.uid }
            let messageCount = plan.headers.count
            let senderCount = Set(plan.headers.map { $0.senderAddress.lowercased() }).count

            if dryRun {
                if !common.json {
                    print("\(line) would \(operation.verb) \(messageCount) message(s) from \(senderCount) sender(s) (skipped: \(plan.skipped))")
                }
                perAccount.append([
                    "accountId": plan.account.id.uuidString,
                    "messageCount": messageCount,
                    "senderCount": senderCount,
                    "skipped": plan.skipped,
                    "committed": false
                ])
                continue
            }

            // Live: open IMAP session, commit, close.
            let creds: AccountCredentials
            do {
                creds = try await accountStore.credentials(for: plan.account)
            } catch {
                FileHandle.standardError.write(Data("\(line) credential load failed: \(error.localizedDescription)\n".utf8))
                perAccount.append([
                    "accountId": plan.account.id.uuidString,
                    "ok": false,
                    "error": error.localizedDescription
                ])
                continue
            }
            // Mutable copy so we can zero the secret bytes once connect
            // returns. Same rationale as `AccountSession.connect`.
            var workingCreds = creds
            defer { workingCreds.clearSecrets() }

            let client = SwiftMailIMAPClient()
            do {
                try await client.connect(workingCreds)
            } catch {
                let msg = IMAPClientError.describe(error)
                FileHandle.standardError.write(Data("\(line) connect failed: \(msg)\n".utf8))
                perAccount.append(["accountId": plan.account.id.uuidString, "ok": false, "error": msg])
                continue
            }
            // Pin the operation to the UIDVALIDITY the cached headers were
            // captured under. Server-side UIDVALIDITY rotation between the
            // last refresh and now causes the IMAP client to throw rather
            // than silently mutate whatever the recycled UIDs now point to.
            let expectedValidity = cache.loadUIDValidity(
                accountId: plan.account.id,
                mailbox: selection.mailbox
            )

            do {
                switch operation {
                case .delete:
                    if settings.softDeleteToTrash {
                        // Soft-delete = move to Trash. Look up the Trash mailbox via list.
                        let mailboxes = try await client.listMailboxes()
                        let trash = mailboxes.first { $0.kind == .trash }?.name
                        if let trash {
                            try await client.moveMessages(
                                uids: uids,
                                from: selection.mailbox,
                                to: trash,
                                expectedUIDValidity: expectedValidity
                            )
                        } else {
                            try await client.deleteMessages(
                                uids: uids,
                                in: selection.mailbox,
                                expectedUIDValidity: expectedValidity
                            )
                        }
                    } else {
                        try await client.deleteMessages(
                            uids: uids,
                            in: selection.mailbox,
                            expectedUIDValidity: expectedValidity
                        )
                    }
                case .archive:
                    let mailboxes = try await client.listMailboxes()
                    guard let archive = mailboxes.first(where: { $0.kind == .archive })?.name else {
                        let msg = "no Archive mailbox on the server"
                        FileHandle.standardError.write(Data("\(line) \(msg)\n".utf8))
                        perAccount.append(["accountId": plan.account.id.uuidString, "ok": false, "error": msg])
                        await client.disconnect()
                        continue
                    }
                    try await client.moveMessages(
                        uids: uids,
                        from: selection.mailbox,
                        to: archive,
                        expectedUIDValidity: expectedValidity
                    )
                case .move(let folder):
                    try await client.moveMessages(
                        uids: uids,
                        from: selection.mailbox,
                        to: folder,
                        expectedUIDValidity: expectedValidity
                    )
                }
            } catch {
                let msg = IMAPClientError.describe(error)
                FileHandle.standardError.write(Data("\(line) IMAP error: \(msg)\n".utf8))
                perAccount.append(["accountId": plan.account.id.uuidString, "ok": false, "error": msg])
                await client.disconnect()
                continue
            }
            await client.disconnect()

            // Sync local cache so the next senders-list reflects reality without forcing
            // a fresh refresh (the IMAP commit already happened; the headers we just
            // affected are no longer in the source mailbox).
            try? cache.applyDiff(
                accountId: plan.account.id,
                mailbox: selection.mailbox,
                deletedUIDs: Set(uids),
                flagUpdates: [:],
                insertedHeaders: []
            )

            if !common.json {
                print("\(line) \(operation.verb)d \(messageCount) message(s) from \(senderCount) sender(s)")
            }
            perAccount.append([
                "accountId": plan.account.id.uuidString,
                "messageCount": messageCount,
                "senderCount": senderCount,
                "skipped": plan.skipped,
                "committed": true,
                "ok": true
            ])
        }

        if common.json {
            let report: [String: Any] = [
                "operation": operation.verb,
                "messageCount": totalAffected,
                "senderCount": totalSenders,
                "skipped": totalSkipped,
                "dryRun": dryRun,
                "perAccount": perAccount
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else if dryRun {
            print("")
            print("dry run: would \(operation.verb) \(totalAffected) message(s) from \(totalSenders) sender(s) across \(plans.count) account(s) (skipped: \(totalSkipped))")
        }
    }
}
