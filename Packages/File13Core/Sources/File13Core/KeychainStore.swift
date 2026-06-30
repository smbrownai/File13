import Foundation
import Security

public enum KeychainStore {
    public static let service = "com.shawnbrown.File13"

    public enum KeychainError: Error {
        case unhandled(OSStatus)
        case decodingFailure
    }

    /// Whether new Keychain writes should opt into iCloud Keychain sync.
    /// Mirrors `SettingsStore.iCloudKeychainSyncEnabled` and is set by the
    /// store at launch and whenever the user toggles the preference.
    ///
    /// Reads/deletes always match both flavors (`kSecAttrSynchronizableAny`)
    /// so we can find items written under either mode. Saves use whatever
    /// value this flag has at the moment of the write.
    nonisolated(unsafe) public static var iCloudSyncEnabled: Bool = false

    public static func savePassword(_ password: String, for accountId: UUID) throws {
        try saveItem(password, account: passwordAccount(accountId))
    }

    public static func loadPassword(for accountId: UUID) throws -> String? {
        try loadItem(account: passwordAccount(accountId))
    }

    /// `Data`-returning variant of `loadPassword`. Preferred for callers in
    /// the credentials path so the secret never has to round-trip through
    /// a `String` (which can't be zeroed) on its way to the IMAP layer.
    /// The returned `Data` is the literal Keychain payload bytes and can
    /// be cleared with `memset_s` after use — see
    /// `AccountCredentials.clearSecrets()`.
    public static func loadPasswordData(for accountId: UUID) throws -> Data? {
        try loadItemData(account: passwordAccount(accountId))
    }

    public static func deletePassword(for accountId: UUID) throws {
        try deleteItem(account: passwordAccount(accountId))
    }

    /// Rewrite this account's password into the keychain with the given sync mode.
    /// No-op if no password is stored for the account.
    ///
    /// `kSecAttrSynchronizable` is part of the keychain item's primary key, so we
    /// can't change the flag via `SecItemUpdate` — we have to delete and re-add.
    public static func migrateAccountPassword(for accountId: UUID, toSynchronizable enabled: Bool) throws {
        try migrateItem(account: passwordAccount(accountId), toSynchronizable: enabled)
    }

    private static func passwordAccount(_ accountId: UUID) -> String {
        "imap-password-\(accountId.uuidString)"
    }

    // MARK: AI provider keys

    public static func saveAIKey(_ key: String, for provider: AIProviderKind) throws {
        try saveItem(key, account: aiKeyAccount(provider))
    }

    public static func loadAIKey(for provider: AIProviderKind) throws -> String? {
        try loadItem(account: aiKeyAccount(provider))
    }

    public static func deleteAIKey(for provider: AIProviderKind) throws {
        try deleteItem(account: aiKeyAccount(provider))
    }

    /// Rewrite this AI provider's key into the keychain with the given sync mode.
    /// No-op if no key is stored for the provider.
    public static func migrateAIKey(for provider: AIProviderKind, toSynchronizable enabled: Bool) throws {
        try migrateItem(account: aiKeyAccount(provider), toSynchronizable: enabled)
    }

    private static func aiKeyAccount(_ provider: AIProviderKind) -> String {
        "ai-key-\(provider.rawValue)"
    }

    // MARK: OAuth tokens

    /// Persisted OAuth state for one File13 account: a current access
    /// token, its expiry, and a long-lived refresh token used to mint new
    /// access tokens when the current one ages out.
    public struct OAuthTokens: Codable, Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date

        public init(accessToken: String, refreshToken: String, expiresAt: Date) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }

        /// True when the access token has expired or is within 60 seconds
        /// of expiring. Conservative window — refreshing slightly early is
        /// far cheaper than failing an IMAP auth and reconnecting.
        public var isExpired: Bool {
            Date().addingTimeInterval(60) >= expiresAt
        }
    }

    public static func saveOAuthTokens(_ tokens: OAuthTokens, for accountId: UUID) throws {
        // Encode straight into `Data` and write via the Data-taking helper
        // so the JSON payload never materializes as a Swift `String`
        // (which is not zeroable and would linger on the heap with the
        // access/refresh tokens visible until the allocator reused the
        // page). After the Keychain write succeeds we still overwrite our
        // local copy with `memset_s`-style zeros — Apple's `SecItemAdd`
        // copies the bytes internally, so the in-process plaintext is no
        // longer load-bearing once it returns. Matches the discipline
        // documented on `AccountCredentials.clearSecrets()` in
        // `IMAPClient.swift`.
        var data = try JSONEncoder().encode(tokens)
        defer { Self.zero(&data) }
        try saveItemData(data, account: oauthAccount(accountId))
    }

    public static func loadOAuthTokens(for accountId: UUID) throws -> OAuthTokens? {
        guard var data = try loadItemData(account: oauthAccount(accountId)) else { return nil }
        defer { Self.zero(&data) }
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    /// Overwrite a `Data` buffer with zeros via `memset_s`. Same caveats
    /// as `AccountCredentials.clearSecrets()`: copy-on-write means only
    /// the buffer we hold gets zeroed — callers should pass a `Data`
    /// they own outright (i.e. just-allocated, refcount 1) for this to
    /// matter.
    private static func zero(_ data: inout Data) {
        data.withUnsafeMutableBytes { buf in
            if let base = buf.baseAddress, buf.count > 0 {
                _ = memset_s(base, buf.count, 0, buf.count)
            }
        }
        data = Data()
    }

    public static func deleteOAuthTokens(for accountId: UUID) throws {
        try deleteItem(account: oauthAccount(accountId))
    }

    /// Same toggle-aware rewrite as `migrateAccountPassword`. OAuth tokens
    /// are valuable cross-device (so the user doesn't have to redo the sign-in
    /// flow on every Mac), so they participate in the same iCloud Keychain
    /// preference as IMAP passwords and AI API keys.
    public static func migrateOAuthTokens(for accountId: UUID, toSynchronizable enabled: Bool) throws {
        try migrateItem(account: oauthAccount(accountId), toSynchronizable: enabled)
    }

    private static func oauthAccount(_ accountId: UUID) -> String {
        "oauth-tokens-\(accountId.uuidString)"
    }

    // MARK: Generic helpers

    /// Force every query through the **data-protection keychain** on macOS
    /// instead of the legacy file-based login keychain. Same fix
    /// `CachedHeadersIntegrity` already applies for its HMAC key: the
    /// file-based login keychain attaches a per-binary ACL to each item, so
    /// a re-signed binary (TestFlight build, notarized release, fresh dev
    /// build) prompts the user for the "login" password the first time it
    /// reads an item created by a different-vintage signature. The
    /// data-protection keychain is scoped by access group (granted via the
    /// `keychain-access-groups` entitlement) and doesn't carry per-binary
    /// ACLs, so re-signs are transparent.
    ///
    /// Items written before this change live in the legacy keychain;
    /// `loadItemData` falls back to a legacy read on a data-protection miss
    /// and lazily migrates the row over. Each existing item therefore
    /// prompts at most one more time — when the new build first reads it
    /// — and is silent afterwards.
    private static func dataProtectionAttrs() -> [String: Any] {
        [kSecUseDataProtectionKeychain as String: true]
    }

    /// Accessibility class used for newly-written items, paired with the current
    /// sync flag. Synchronizable items can't use `*ThisDeviceOnly`; non-synced
    /// items stay device-bound for the strongest local protection.
    private static var currentAccessibility: CFString {
        iCloudSyncEnabled ? kSecAttrAccessibleWhenUnlocked
                          : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    private static func saveItem(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.decodingFailure }
        try saveItemData(data, account: account)
    }

    /// Lower-level write that takes the raw `Data` payload. The
    /// String-accepting `saveItem` builds on top of this so we have one
    /// place that does the `SecItemUpdate` / `SecItemAdd` dance. Secret-
    /// bearing callers (OAuth tokens, anything that wants to zero the
    /// JSON bytes after writing) should use this directly to avoid
    /// materializing the secret as a Swift `String`, which is not
    /// zeroable.
    private static func saveItemData(_ data: Data, account: String) throws {
        // Include `kSecAttrSynchronizable` in the lookup so an update only matches
        // items already in the chosen sync mode. If the item exists in the other
        // mode it won't be found here and we'll fall into the add branch — which
        // would collide. Callers that flip the sync flag are expected to migrate
        // existing items first via `migrateAccountPassword` / `migrateAIKey`.
        var baseQuery = dataProtectionAttrs()
        baseQuery[kSecClass as String]            = kSecClassGenericPassword
        baseQuery[kSecAttrService as String]      = service
        baseQuery[kSecAttrAccount as String]      = account
        baseQuery[kSecAttrSynchronizable as String] = iCloudSyncEnabled
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = currentAccessibility
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        default:
            throw KeychainError.unhandled(updateStatus)
        }
    }

    private static func loadItem(account: String) throws -> String? {
        guard let data = try loadItemData(account: account) else { return nil }
        guard let s = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailure
        }
        return s
    }

    /// Lower-level read that returns the raw Keychain payload as `Data`.
    /// The String-returning `loadItem` builds on top of this so we have
    /// exactly one place that calls `SecItemCopyMatching` and exactly one
    /// place that does the UTF-8 decode. Secret-bearing callers should
    /// use this directly so the bytes can be zeroed later.
    ///
    /// Read order:
    /// 1. Data-protection keychain (current write target — no ACL prompt).
    /// 2. Legacy login keychain (pre-migration items). May trigger the
    ///    one-time `login.keychain` password prompt the first time this
    ///    build reads a legacy item; after that the OS remembers our
    ///    access.
    /// 3. On a legacy hit, rewrite the item into the data-protection
    ///    keychain and delete the legacy copy. Subsequent reads find it
    ///    in step 1 with no prompt.
    private static func loadItemData(account: String) throws -> Data? {
        if let data = try readItemData(account: account, legacy: false) {
            return data
        }
        guard let legacy = try readItemData(account: account, legacy: true) else {
            return nil
        }
        // Best-effort migration: if either side fails, we just lose the
        // optimization for this item, never the data itself. The legacy
        // copy is only deleted after the data-protection write returns
        // success.
        do {
            try addItem(data: legacy, account: account)
            try deleteLegacyItem(account: account)
        } catch {
            // Swallow — the read succeeded; migration is a nice-to-have.
        }
        return legacy
    }

    private static func readItemData(account: String, legacy: Bool) throws -> Data? {
        var query: [String: Any] = legacy ? [:] : dataProtectionAttrs()
        query[kSecClass as String]           = kSecClassGenericPassword
        query[kSecAttrService as String]     = service
        query[kSecAttrAccount as String]     = account
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecMatchLimit as String]      = kSecMatchLimitOne
        query[kSecReturnData as String]      = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.decodingFailure
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    /// Direct `SecItemAdd` into the data-protection keychain — used by the
    /// migration path in `loadItemData` to seed a freshly-discovered legacy
    /// item. Distinct from `saveItem` because we already know there's no
    /// data-protection row to update, and we want to preserve the
    /// caller-observed sync state at write time (the `iCloudSyncEnabled`
    /// flag).
    private static func addItem(data: Data, account: String) throws {
        var addQuery = dataProtectionAttrs()
        addQuery[kSecClass as String]            = kSecClassGenericPassword
        addQuery[kSecAttrService as String]      = service
        addQuery[kSecAttrAccount as String]      = account
        addQuery[kSecAttrSynchronizable as String] = iCloudSyncEnabled
        addQuery[kSecAttrAccessible as String]   = currentAccessibility
        addQuery[kSecValueData as String]        = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KeychainError.unhandled(status)
        }
    }

    /// Delete a legacy-keychain row by account (without the
    /// data-protection flag). Used only by the lazy migration path —
    /// regular `deleteItem` deletes from both backends via the same
    /// `kSecAttrSynchronizableAny` matcher.
    private static func deleteLegacyItem(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    private static func deleteItem(account: String) throws {
        // Delete from both backends. The legacy delete is best-effort: an
        // unmigrated item still in the login keychain should disappear when
        // the user explicitly removes the account, even if the lazy
        // migration never got a chance to copy it across.
        var primary = dataProtectionAttrs()
        primary[kSecClass as String]           = kSecClassGenericPassword
        primary[kSecAttrService as String]     = service
        primary[kSecAttrAccount as String]     = account
        primary[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let primaryStatus = SecItemDelete(primary as CFDictionary)
        guard primaryStatus == errSecSuccess || primaryStatus == errSecItemNotFound else {
            throw KeychainError.unhandled(primaryStatus)
        }
        try? deleteLegacyItem(account: account)
    }

    private static func migrateItem(account: String, toSynchronizable enabled: Bool) throws {
        // Load through the Data path and zero it after the rewrite, instead of
        // materializing the secret as a non-zeroable Swift String. This runs
        // for every password / API key / OAuth token on an iCloud-Keychain
        // sync toggle, so it must match the same `Data` + `memset_s` discipline
        // the rest of this file uses (see `saveOAuthTokens` / `clearSecrets`).
        guard var data = try loadItemData(account: account) else { return }
        defer { zero(&data) }
        try deleteItem(account: account)
        let accessible: CFString = enabled
            ? kSecAttrAccessibleWhenUnlocked
            : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var addQuery = dataProtectionAttrs()
        addQuery[kSecClass as String]            = kSecClassGenericPassword
        addQuery[kSecAttrService as String]      = service
        addQuery[kSecAttrAccount as String]      = account
        addQuery[kSecAttrSynchronizable as String] = enabled
        addQuery[kSecAttrAccessible as String]   = accessible
        addQuery[kSecValueData as String]        = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
    }
}
