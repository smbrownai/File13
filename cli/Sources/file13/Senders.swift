import ArgumentParser
import File13Core
import Foundation
import SwiftData

/// `file13 senders list` — flat list of senders aggregated from the cached headers.
///
/// Per the spec: address, message count, unread count, most-recent date. Optional flags
/// filter by category, domain, account, or minimum volume — exactly the shape that pipes
/// cleanly into `file13 mail delete --senders-file -` (once mail ops land).
///
/// The cache is the SwiftData store the GUI populated on its last refresh. The CLI
/// acquires the App Group lock first so it doesn't race with a running GUI process; if
/// the lock is held we bail with exit 2 (not blocked, since unattended scripts shouldn't
/// hang).
struct SendersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "senders",
        abstract: "List senders aggregated from the shared cache.",
        subcommands: [List.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print address, count, unread count, most-recent date for each sender."
        )

        @Option(name: .long, help: "Filter by AI category (personal, work, finance, commerce, news, social, promotional, notifications, other).")
        var category: String?

        @Option(name: .long, help: "Filter by domain (case-insensitive suffix match on @<domain>).")
        var domain: String?

        @Option(name: .long, help: "Filter to one account UUID. Default: every account.")
        var account: String?

        @Option(name: .long, help: "Minimum message count to include.")
        var minCount: Int = 1

        @Option(name: .long, help: "Mailbox name to read from. Default: INBOX.")
        var mailbox: String = "INBOX"

        @Flag(name: .long, help: "Emit JSON instead of plain text.")
        var json: Bool = false

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            // Lock first — bail immediately if the GUI is running.
            let lock = LockFile()
            switch lock.tryAcquire() {
            case .acquired:
                break
            case .heldByOther:
                FileHandle.standardError.write(Data("File13.app is running — close it (or run under `--wait` once that lands).\n".utf8))
                throw ExitCode(2)
            case .error(let message):
                FileHandle.standardError.write(Data("lock error: \(message)\n".utf8))
                throw ExitCode(3)
            }
            defer { lock.release() }

            let categoryFilter: SenderCategory?
            if let raw = category {
                guard let parsed = SenderCategory(rawValue: raw.lowercased()) else {
                    FileHandle.standardError.write(Data("unknown category: \(raw)\n".utf8))
                    FileHandle.standardError.write(Data("valid: \(SenderCategory.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8))
                    throw ExitCode(2)
                }
                categoryFilter = parsed
            } else {
                categoryFilter = nil
            }

            let accountFilter: UUID?
            if let raw = account {
                guard let uuid = UUID(uuidString: raw) else {
                    FileHandle.standardError.write(Data("not a valid UUID: \(raw)\n".utf8))
                    throw ExitCode(2)
                }
                accountFilter = uuid
            } else {
                accountFilter = nil
            }

            // Open the shared SwiftData container. Must use the same container URL the
            // GUI app uses — by default that's URL.applicationSupportDirectory/default.store
            // for ModelContainer(for:). The CLI is in a different sandbox so its
            // applicationSupportDirectory differs; we have to point it at the App Group
            // container explicitly.
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
            let categoryStore = SenderCategoryStore()
            let accountStore = AccountStore()

            // Pick which accounts to read from.
            let accountsToScan: [Account]
            if let accountFilter {
                accountsToScan = accountStore.accounts.filter { $0.id == accountFilter }
                if accountsToScan.isEmpty {
                    FileHandle.standardError.write(Data("no account with id \(accountFilter.uuidString)\n".utf8))
                    throw ExitCode(2)
                }
            } else {
                accountsToScan = accountStore.accounts
            }

            // Aggregate cached headers across all selected accounts and group by sender.
            var allHeaders: [MessageHeader] = []
            for acc in accountsToScan {
                allHeaders.append(contentsOf: cache.loadHeaders(accountId: acc.id, mailbox: mailbox))
            }
            var senders = allHeaders.groupedBySender()

            // Apply filters.
            if let categoryFilter {
                senders = senders.filter { categoryStore.category(for: $0.id) == categoryFilter }
            }
            if let domain = domain?.lowercased(), !domain.isEmpty {
                senders = senders.filter { $0.address.lowercased().hasSuffix("@\(domain)") }
            }
            if minCount > 1 {
                senders = senders.filter { $0.messageCount >= minCount }
            }

            // Newest-first by default.
            senders.sort { $0.mostRecent > $1.mostRecent }

            if json {
                let dicts: [[String: Any]] = senders.map { s in
                    var d: [String: Any] = [
                        "address": s.address,
                        "name": s.name,
                        "messageCount": s.messageCount,
                        "unreadCount": s.unreadCount,
                        "mostRecent": ISO8601DateFormatter().string(from: s.mostRecent)
                    ]
                    if let cat = categoryStore.category(for: s.id) { d["category"] = cat.rawValue }
                    return d
                }
                let data = try JSONSerialization.data(withJSONObject: dicts, options: [.sortedKeys, .prettyPrinted])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                if senders.isEmpty {
                    print("(no senders match)")
                    return
                }
                let dateFormatter = ISO8601DateFormatter()
                dateFormatter.formatOptions = [.withFullDate]
                let addrWidth = max(7, senders.map(\.address.count).max() ?? 0)
                for s in senders {
                    let addr  = s.address.padding(toLength: addrWidth, withPad: " ", startingAt: 0)
                    let date  = dateFormatter.string(from: s.mostRecent)
                    print("\(addr)  total=\(s.messageCount)  unread=\(s.unreadCount)  mostRecent=\(date)")
                }
            }
        }
    }
}

