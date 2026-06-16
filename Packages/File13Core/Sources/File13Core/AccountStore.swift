import Foundation
import Observation

@Observable
@MainActor
public final class AccountStore {
    private static let storageKey = "File13.accounts.v1"

    public private(set) var accounts: [Account]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = SharedDefaults.suite) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            self.accounts = decoded
        } else {
            self.accounts = []
        }
    }

    public func add(_ account: Account, password: String) throws {
        try KeychainStore.savePassword(password, for: account.id)
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        persist()
    }

    /// Update the metadata for an existing account (display name, host,
    /// port, username). Does not touch the Keychain — credential changes go
    /// through `KeychainStore.savePassword` directly. No-op if no account
    /// with the matching id is currently in the store.
    public func update(_ account: Account) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i] = account
        persist()
    }

    public func remove(_ accountId: UUID) {
        try? KeychainStore.deletePassword(for: accountId)
        try? KeychainStore.deleteOAuthTokens(for: accountId)
        accounts.removeAll { $0.id == accountId }
        persist()
    }

    /// Persist an OAuth-authenticated account. No password write — credentials
    /// live in the OAuth token blob, not in the password slot.
    public func addOAuth(_ account: Account, tokens: KeychainStore.OAuthTokens) throws {
        try KeychainStore.saveOAuthTokens(tokens, for: account.id)
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        persist()
    }

    /// Resolve current credentials for an account. For password accounts this
    /// is a single Keychain read. For OAuth accounts it loads stored tokens,
    /// refreshes them via the provider's token endpoint when expired, and
    /// persists the refreshed pair back to the Keychain before handing the
    /// access token to the IMAP layer.
    ///
    /// Async because OAuth refresh is a network call. Callers in synchronous
    /// contexts (the CLI's password-only flows) can still call this — the
    /// password branch resolves without hitting the network.
    public func credentials(for account: Account) async throws -> AccountCredentials {
        switch account.authKind {
        case .password:
            // Read directly into `Data` so the password never round-trips
            // through a Swift `String` between the Keychain and IMAP layer.
            // See `AccountCredentials.clearSecrets()` for the zero-on-drop
            // contract this enables.
            guard let pw = try KeychainStore.loadPasswordData(for: account.id) else {
                throw AccountStoreError.missingPassword
            }
            return AccountCredentials.resolved(
                host: account.host,
                port: account.port,
                username: account.username,
                passwordData: pw
            )

        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.storageKey)
            CloudKVSync.markDirty(Self.storageKey, defaults: defaults)
        }
    }

    /// Apply a JSON-encoded account list that arrived via iCloud sync,
    /// after the user has approved the change via the pending-sync
    /// banner. Used by `PendingSyncChangesBanner` to commit a remote
    /// account snapshot without going through the regular `add` /
    /// `remove` path (which would re-trigger an iCloud push and could
    /// race with the apply).
    ///
    /// Why this exists as a separate method: `accounts.v1` is in the
    /// `SyncedSensitiveKeys` set because an attacker who flips the
    /// `host` of an existing account can exfiltrate the user's IMAP
    /// password on the next refresh. The mirror routes incoming
    /// account changes through `PendingSyncChangesStore` rather than
    /// applying directly; this method is the explicit "the user
    /// reviewed the change and approves it" commit path.
    public func applySyncedAccounts(from data: Data) {
        guard let decoded = try? JSONDecoder().decode([Account].self, from: data) else { return }
        accounts = decoded
        defaults.set(data, forKey: Self.storageKey)
        // Don't mark dirty — the synced source is already authoritative.
    }
}

public enum AccountStoreError: LocalizedError {
    case missingPassword
    case missingOAuthTokens
    public var errorDescription: String? {
        switch self {
        case .missingPassword:    "No password found in Keychain for this account."
        case .missingOAuthTokens: "No OAuth tokens found for this account — sign in again from Settings."
        }
    }
}
