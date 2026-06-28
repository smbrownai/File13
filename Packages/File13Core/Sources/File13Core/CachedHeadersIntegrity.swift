import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// Authenticate the cached-headers SwiftData store with an HMAC so a sibling
/// app from the same dev team that joined the App Group can't silently
/// rewrite (account, mailbox, UID-validity, headers) tuples that drive AI
/// categorization and rule matching.
///
/// The threat model is deliberately narrow: Apple's app sandbox prevents
/// arbitrary apps from reading the App Group container, and the App Store
/// review process gates which apps can request a given group ID. So this
/// only matters when *another File13-team binary* (a sibling app, a
/// staging build, a future utility) joins
/// `group.com.shawnbrown.File13` and behaves badly. That's a low-
/// likelihood scenario; the HMAC is here to make it explicit that the
/// store's contents are authenticated, not just stored.
///
/// Mechanics:
///
/// - **HMAC key** lives in the app-private Keychain — no
///   `kSecAttrAccessGroup`, no `kSecAttrSynchronizable` — so a sibling
///   App Group binary can read the SwiftData rows but not the secret
///   that authenticates them.
/// - **HMAC value** is stored alongside the key by `(accountId, mailbox)`.
///   Re-using the same Keychain item space keeps the secret and its
///   tag-derived metadata in lockstep across launches.
/// - **Canonical serialization** for the HMAC input: UTF-8
///   `accountId|mailbox`, then UID-validity as little-endian UInt64,
///   then UID-sorted `(uid|isRead|messageId|senderAddress)` for every
///   header. Fields beyond those are not authenticated — only the
///   ones that drive rule matching / AI categorization. That's a
///   performance / coverage trade-off documented here so a future
///   reviewer doesn't waste cycles trying to also authenticate
///   `subject` (which is fine: a subject-tampered row produces no
///   downstream rule effect we care about).
///
/// On verification failure, callers (in `MessageCache`) treat the affected
/// (account, mailbox) as a cache miss and force a clean re-fetch.
public enum CachedHeadersIntegrity {
    /// Bundle-relative Keychain coordinates. Sibling apps that joined the
    /// App Group share `UserDefaults` and the SwiftData store but cannot
    /// read this Keychain item — it has no access-group attribute, so it
    /// defaults to this app's signing identity only.
    private static let serviceForKey   = "File13.MessageCache.Integrity.Key"
    private static let serviceForMAC   = "File13.MessageCache.Integrity.MAC"
    private static let accountForKey   = "primary"

    /// Force every query through the **data-protection keychain** on
    /// macOS instead of the legacy file-based login keychain. The
    /// file-based keychain attaches a per-binary ACL to each item; when
    /// a re-signed binary (TestFlight, notarized release, dev build of
    /// a different vintage) tries to read an item created by a
    /// previously-signed binary, the user gets the
    /// "File13 wants to use confidential information stored in …"
    /// password prompt — one per item per launch.
    ///
    /// The data-protection keychain is the modern, iOS-style storage
    /// scoped automatically by the app's implicit keychain access group
    /// (`<team-id>.<bundle-id>`, granted by the
    /// `keychain-access-groups` entitlement on every signed File13
    /// build). No ACL prompts, transparent across re-signs.
    ///
    /// `KeychainStore` (for IMAP passwords) doesn't set this flag; its
    /// items also live in the login keychain. Those items don't prompt
    /// in practice because they're written under the same signed
    /// binary they're later read by. The integrity-key items, by
    /// contrast, get re-read on every launch from `verifyIntegrity`,
    /// surfacing the prompt anywhere the binary identity has shifted.
    /// Setting `kSecUseDataProtectionKeychain` here sidesteps that
    /// without touching the IMAP-password storage path.
    private static func baseQueryAttributes() -> [String: Any] {
        [kSecUseDataProtectionKeychain as String: true]
    }

    /// Load (or first-time create) the 256-bit HMAC key. Returns nil if the
    /// Keychain is unavailable for some reason — callers treat nil as
    /// "integrity unenforced this launch" and skip the check rather than
    /// taking down the cache. Failing-open is the right default here:
    /// an unrelated Keychain ACL glitch shouldn't wipe a 50k-message cache.
    public static func loadOrCreateHMACKey() -> SymmetricKey? {
        if let existing = loadHMACKey() {
            return existing
        }
        return createHMACKey()
    }

    private static func loadHMACKey() -> SymmetricKey? {
        var query: [String: Any] = baseQueryAttributes()
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = serviceForKey
        query[kSecAttrAccount as String] = accountForKey
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    private static func createHMACKey() -> SymmetricKey? {
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        var attrs: [String: Any] = baseQueryAttributes()
        attrs[kSecClass as String] = kSecClassGenericPassword
        attrs[kSecAttrService as String] = serviceForKey
        attrs[kSecAttrAccount as String] = accountForKey
        attrs[kSecValueData as String] = raw
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // SecItemAdd can return errSecDuplicateItem if a previous launch added
        // a key but loadHMACKey missed it (rare ACL race). In that case fall
        // back to a re-load.
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecSuccess { return key }
        if status == errSecDuplicateItem { return loadHMACKey() }
        return nil
    }

    /// Compute HMAC-SHA256 over the canonical serialization. Returns nil
    /// only when the HMAC key is unavailable.
    public static func computeMAC(
        accountId: UUID,
        mailbox: String,
        uidValidity: UInt64?,
        headers: [MessageHeader]
    ) -> Data? {
        guard let key = loadOrCreateHMACKey() else { return nil }
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: Data(accountId.uuidString.utf8))
        hmac.update(data: Data("|".utf8))
        hmac.update(data: Data(mailbox.utf8))
        hmac.update(data: Data("|".utf8))
        var uv = (uidValidity ?? 0).littleEndian
        withUnsafeBytes(of: &uv) { hmac.update(data: Data($0)) }
        // Stable order: UID ascending, breaking ties by messageId.
        let sorted = headers.sorted { a, b in
            let au = a.uid ?? 0, bu = b.uid ?? 0
            if au != bu { return au < bu }
            return a.rawMessageId < b.rawMessageId
        }
        for h in sorted {
            var uid = (h.uid ?? 0).littleEndian
            withUnsafeBytes(of: &uid) { hmac.update(data: Data($0)) }
            hmac.update(data: Data([h.isRead ? 1 : 0]))
            hmac.update(data: Data(h.rawMessageId.utf8))
            hmac.update(data: Data("|".utf8))
            hmac.update(data: Data(h.senderAddress.utf8))
            hmac.update(data: Data([0x1f]))
        }
        return Data(hmac.finalize())
    }

    /// Save the freshly-computed MAC for an (account, mailbox). Replaces
    /// any previous value. Stored without access-group / synchronizable,
    /// same scope as the key itself.
    public static func saveMAC(_ mac: Data, accountId: UUID, mailbox: String) {
        let account = keychainAccount(accountId: accountId, mailbox: mailbox)
        var baseQuery: [String: Any] = baseQueryAttributes()
        baseQuery[kSecClass as String] = kSecClassGenericPassword
        baseQuery[kSecAttrService as String] = serviceForMAC
        baseQuery[kSecAttrAccount as String] = account
        let updateAttrs: [String: Any] = [
            kSecValueData as String: mac,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addAttrs = baseQuery
            for (k, v) in updateAttrs { addAttrs[k] = v }
            _ = SecItemAdd(addAttrs as CFDictionary, nil)
        }
    }

    public static func loadMAC(accountId: UUID, mailbox: String) -> Data? {
        let account = keychainAccount(accountId: accountId, mailbox: mailbox)
        var query: [String: Any] = baseQueryAttributes()
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = serviceForMAC
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    public static func deleteMAC(accountId: UUID, mailbox: String) {
        let account = keychainAccount(accountId: accountId, mailbox: mailbox)
        var query: [String: Any] = baseQueryAttributes()
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = serviceForMAC
        query[kSecAttrAccount as String] = account
        _ = SecItemDelete(query as CFDictionary)
    }

    private static func keychainAccount(accountId: UUID, mailbox: String) -> String {
        "\(accountId.uuidString)|\(mailbox)"
    }

    /// Constant-time comparison so a timing oracle can't help an attacker
    /// converge on a forged MAC. For our threat model this is borderline
    /// paranoid (the attacker is a sibling app, not network-remote), but
    /// the cost is negligible.
    public static func macsEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
