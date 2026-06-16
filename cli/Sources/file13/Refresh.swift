import ArgumentParser
import File13Core
import Foundation
import SwiftData

/// `file13 refresh` — IMAP sync from the command line.
///
/// Drives `AccountSession` directly (no `InboxStore` orchestrator). For each account
/// chosen by the flags, opens an `AccountSession`, calls `connect` then `refresh`, then
/// `disconnect`. Headers land in the same SwiftData store the GUI uses, so the next
/// `file13 senders list` (or the GUI's next launch) sees them.
///
/// Lock-protected: bails immediately if the GUI is open, since both processes can't
/// safely open the SwiftData container concurrently.
struct RefreshCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Run an IMAP sync against one or all accounts."
    )

    @Option(name: .long, help: "Account UUID to refresh. Default: every configured account.")
    var account: String?

    @Option(name: .long, help: "Mailbox to refresh. Default: INBOX.")
    var mailbox: String = "INBOX"

    @Flag(name: .long, help: "Wipe cached headers + UIDValidity for this account/mailbox before refreshing — forces a full re-fetch.")
    var full: Bool = false

    @Flag(name: .long, help: "Emit JSON report.")
    var json: Bool = false

    @MainActor
    func run() async throws {
        try CLILicenseReader.requirePro()
        let lock = LockFile()
        switch lock.tryAcquire() {
        case .acquired:
            break
        case .heldByOther:
            FileHandle.standardError.write(Data("File13.app is running — close it before running `file13 refresh`.\n".utf8))
            throw ExitCode(2)
        case .error(let m):
            FileHandle.standardError.write(Data("lock error: \(m)\n".utf8))
            throw ExitCode(3)
        }
        defer { lock.release() }

        let accountStore = AccountStore()
        let accounts: [Account]
        if let raw = account {
            guard let uuid = UUID(uuidString: raw) else {
                FileHandle.standardError.write(Data("not a valid UUID: \(raw)\n".utf8))
                throw ExitCode(2)
            }
            guard let acc = accountStore.accounts.first(where: { $0.id == uuid }) else {
                FileHandle.standardError.write(Data("no account with id \(uuid.uuidString)\n".utf8))
                throw ExitCode(2)
            }
            accounts = [acc]
        } else {
            accounts = accountStore.accounts
        }
        guard !accounts.isEmpty else {
            print("(no accounts configured — `file13 accounts add` to add one)")
            return
        }

        // Open the shared SwiftData container so AccountSession can persist headers.
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

        var report: [[String: Any]] = []
        for acc in accounts {
            let line = "[\(acc.displayName) <\(acc.address)>]"
            if !json { print("\(line) refreshing \(mailbox)…") }

            let credentials: AccountCredentials
            do {
                credentials = try await accountStore.credentials(for: acc)
            } catch {
                let msg = "credential load failed: \(error.localizedDescription)"
                if json {
                    report.append(["accountId": acc.id.uuidString, "ok": false, "error": msg])
                } else {
                    print("\(line) \(msg)")
                }
                continue
            }

            if full {
                cache.clearUIDValidities(accountId: acc.id)
                try? cache.purge(accountId: acc.id)
            }

            let session = AccountSession(account: acc, cache: cache)
            await session.connect(credentials: credentials)
            // performRefresh is what writes headers to cache; refresh() awaits its completion.
            await session.refresh()
            let headerCount = session.headers.count
            let lastError = session.lastError
            await session.disconnect()

            if json {
                var entry: [String: Any] = [
                    "accountId": acc.id.uuidString,
                    "displayName": acc.displayName,
                    "mailbox": mailbox,
                    "headerCount": headerCount,
                    "ok": lastError == nil
                ]
                if let lastError { entry["error"] = lastError }
                report.append(entry)
            } else {
                if let lastError {
                    print("\(line) error: \(lastError)  (cached headers: \(headerCount))")
                } else {
                    print("\(line) done — \(headerCount) headers cached for \(mailbox)")
                }
            }
        }

        if json {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
