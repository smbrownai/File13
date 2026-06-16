import ArgumentParser
import File13Core
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `file13 accounts` — manage IMAP accounts that the GUI app connects to.
///
/// All reads/writes go through the shared `AccountStore` (UserDefaults suite for the
/// account records, Keychain Access Group for the passwords). Adding or editing an
/// account from the CLI is immediately visible to the GUI on its next launch / refresh.
struct AccountsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accounts",
        abstract: "List, add, edit, and delete IMAP accounts.",
        subcommands: [List.self, Add.self, Delete.self, Test.self]
    )

    // MARK: - List

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print all configured IMAP accounts."
        )

        @Flag(name: .long, help: "Emit JSON instead of plain text.")
        var json: Bool = false

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            let store = AccountStore()
            if json {
                let dicts: [[String: Any]] = store.accounts.map { acc in
                    [
                        "id": acc.id.uuidString,
                        "displayName": acc.displayName,
                        "address": acc.address,
                        "host": acc.host,
                        "port": acc.port,
                        "username": acc.username,
                        "provider": acc.provider.rawValue,
                        "hasPassword": (try? KeychainStore.loadPassword(for: acc.id)) != nil
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: dicts, options: [.sortedKeys, .prettyPrinted])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                if store.accounts.isEmpty {
                    print("(no accounts configured — `file13 accounts add` to add one)")
                    return
                }
                let nameWidth = max(4, store.accounts.map(\.displayName.count).max() ?? 0)
                let hostWidth = max(4, store.accounts.map(\.host.count).max() ?? 0)
                for acc in store.accounts {
                    let name = acc.displayName.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                    let host = "\(acc.host):\(acc.port)".padding(toLength: hostWidth + 6, withPad: " ", startingAt: 0)
                    let pw = (try? KeychainStore.loadPassword(for: acc.id)) != nil ? "key set" : "NO KEY"
                    print("\(acc.id.uuidString)  \(name)  \(host)  \(acc.username)  [\(pw)]")
                }
            }
        }
    }

    // MARK: - Add

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a new IMAP account; password is read from stdin (never argv).",
            discussion: """
            Pipe the password in: `printf '%s' 'app-password' | file13 accounts add ...`
            or interactive: file13 accounts add ...   (it prompts on a TTY).

            The password is stored in the shared Keychain immediately — the GUI sees it
            on its next launch.
            """
        )

        @Option(name: .long, help: "Display name (e.g. \"Personal\").")
        var name: String

        @Option(name: .long, help: "IMAP host (e.g. imap.fastmail.com).")
        var host: String

        @Option(name: .long, help: "IMAP port. 993 for IMAPS, 143 for STARTTLS.")
        var port: Int = 993

        @Option(name: .long, help: "IMAP username (often your email address).")
        var username: String

        @Option(name: .long, help: "Email address shown in the UI. Defaults to username if it looks like an email.")
        var address: String?

        @Option(name: .long, help: "Provider hint: gmail | outlook | icloud | imap.")
        var provider: String = "imap"

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            guard let providerKind = Account.Provider(rawValue: provider) else {
                FileHandle.standardError.write(Data("unknown provider: \(provider)\n".utf8))
                FileHandle.standardError.write(Data("valid: gmail, outlook, icloud, imap\n".utf8))
                throw ExitCode(2)
            }
            let resolvedAddress = address ?? username
            let password = Self.readPassword()
            guard !password.isEmpty else {
                FileHandle.standardError.write(Data("empty password — aborting\n".utf8))
                throw ExitCode(2)
            }
            let account = Account(
                displayName: name,
                address: resolvedAddress,
                host: host,
                port: port,
                username: username,
                provider: providerKind
            )
            let store = AccountStore()
            do {
                try store.add(account, password: password)
            } catch {
                FileHandle.standardError.write(Data("failed to save account: \(error.localizedDescription)\n".utf8))
                throw ExitCode(3)
            }
            print("added: \(account.id.uuidString)  \(account.displayName)  \(account.host):\(account.port)")
        }

        private static func readPassword() -> String {
            TTYInput.readSecret(prompt: "Password: ")
        }
    }

    // MARK: - Delete

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete an account (UUID) and remove its Keychain password."
        )

        @Argument(help: "Account UUID (from `file13 accounts list`).")
        var id: String

        @Flag(name: .shortAndLong, help: "Skip the confirmation prompt.")
        var yes: Bool = false

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            guard let uuid = UUID(uuidString: id) else {
                FileHandle.standardError.write(Data("not a valid UUID: \(id)\n".utf8))
                throw ExitCode(2)
            }
            let store = AccountStore()
            guard let acc = store.accounts.first(where: { $0.id == uuid }) else {
                FileHandle.standardError.write(Data("no account with id \(uuid.uuidString)\n".utf8))
                throw ExitCode(2)
            }
            if !yes {
                if isatty(fileno(stdin)) == 0 {
                    FileHandle.standardError.write(Data("non-interactive: pass --yes to confirm deletion\n".utf8))
                    throw ExitCode(2)
                }
                print("Delete \(acc.displayName) (\(acc.host):\(acc.port))? [y/N] ", terminator: "")
                let answer = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard answer == "y" || answer == "yes" else {
                    print("aborted")
                    throw ExitCode(0)
                }
            }
            store.remove(uuid)
            print("deleted: \(acc.id.uuidString)")
        }
    }

    // MARK: - Test

    struct Test: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Verify that an account's Keychain password loads (does not connect to IMAP).",
            discussion: """
            This is a credential-presence check — it confirms the shared Keychain Access
            Group is hooked up and the password for this account loads from the same
            keychain entry the GUI wrote. A real network connect-and-NOOP probe is part
            of the IMAP-layer phase (currently outside File13Core).
            """
        )

        @Argument(help: "Account UUID (from `file13 accounts list`).")
        var id: String

        @MainActor
        func run() async throws {
            try CLILicenseReader.requirePro()
            guard let uuid = UUID(uuidString: id) else {
                FileHandle.standardError.write(Data("not a valid UUID: \(id)\n".utf8))
                throw ExitCode(2)
            }
            let store = AccountStore()
            guard let acc = store.accounts.first(where: { $0.id == uuid }) else {
                FileHandle.standardError.write(Data("no account with id \(uuid.uuidString)\n".utf8))
                throw ExitCode(2)
            }
            do {
                let creds = try await store.credentials(for: acc)
                // `secretByteCount` reports the byte length of the active
                // secret (password or OAuth access token) without
                // materializing a Swift `String` — see
                // `AccountCredentials.clearSecrets()` for why we avoid
                // unnecessary String copies of secrets.
                print("\(acc.displayName): credentials OK — host=\(creds.host) port=\(creds.port) tls=\(creds.useTLS) user=\(creds.username) password=(redacted, \(creds.secretByteCount) bytes)")
            } catch {
                FileHandle.standardError.write(Data("\(acc.displayName): \(error.localizedDescription)\n".utf8))
                throw ExitCode(3)
            }
        }
    }
}
