import Foundation
import Darwin

/// How the IMAP layer should authenticate to the server. Two flavors today:
/// classic password (or app-specific password) and OAuth2 bearer token via
/// SASL XOAUTH2 (Gmail, Microsoft). The token, when present, is a *current*
/// access token — refreshing happens one layer up at connect time.
///
/// The secret is carried as `Data` (UTF-8 bytes) rather than `String` so we
/// can explicitly zero the underlying buffer when the credentials go out of
/// use. Swift `String` storage is heap-allocated and isn't zeroed on ARC
/// release; the bytes linger until something else allocates over them. For
/// a long-running GUI session that window is hours. `Data` lets us call
/// `memset_s` ourselves at the end of a connect attempt — see
/// `AccountCredentials.clearSecrets()`.
public enum AccountAuth: Sendable {
    case password(Data)
    case oauth2(accessToken: Data)
}

public struct AccountCredentials: Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public var auth: AccountAuth
    public let useTLS: Bool

    public init(host: String, port: Int, username: String, auth: AccountAuth, useTLS: Bool) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.useTLS = useTLS
    }

    /// Byte length of the active secret. Used by diagnostic code paths
    /// (e.g. the CLI's `accounts test`) that previously called `.password.count`
    /// to print a redacted length without leaking the value. Doesn't
    /// materialize a `String`, so the bytes never leave the `Data` buffer.
    public var secretByteCount: Int {
        switch auth {
        case .password(let d):          d.count
        case .oauth2(let d):            d.count
        }
    }

    /// All File13-initiated IMAP connections require TLS. We always pass
    /// `useTLS: true` (implicit TLS on 993, STARTTLS on 143) — the previous
    /// port-derived heuristic silently disabled TLS for any port other than
    /// 993, so a user who typed `143` in the port field was sending their
    /// password in cleartext. The public `init` still accepts `useTLS`, but
    /// the factories every UI / refresh path goes through now pin it on.
    public static func resolved(host: String, port: Int, username: String, password: String) -> AccountCredentials {
        AccountCredentials(
            host: host,
            port: port,
            username: username,
            auth: .password(Data(password.utf8)),
            useTLS: true
        )
    }

    /// Variant that accepts the password already in `Data` form — preferred
    /// path for `AccountStore.credentials(for:)` which reads the Keychain
    /// directly into `Data`, so the secret never has to round-trip through
    /// a `String` between Keychain and IMAP.
    public static func resolved(host: String, port: Int, username: String, passwordData: Data) -> AccountCredentials {
        AccountCredentials(
            host: host,
            port: port,
            username: username,
            auth: .password(passwordData),
            useTLS: true
        )
    }

    public static func resolvedOAuth(host: String, port: Int, username: String, accessToken: String) -> AccountCredentials {
        AccountCredentials(
            host: host,
            port: port,
            username: username,
            auth: .oauth2(accessToken: Data(accessToken.utf8)),
            useTLS: true
        )
    }

    /// Materialize the secret as a UTF-8 `String` just long enough to pass
    /// to a synchronous body, then drop it. The String exists in heap
    /// memory for the duration of `body` only — Swift can't zero String
    /// storage, but the lifetime is bounded by the closure scope. The IMAP
    /// layer's `s.login(...)` call uses this so the password String lives
    /// only across the single LOGIN command, not for the rest of the
    /// connection.
    public func withSecretString<T>(_ body: (String) throws -> T) rethrows -> T? {
        let data: Data
        switch auth {
        case .password(let d): data = d
        case .oauth2(let d):   data = d
        }
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        return try body(s)
    }

    /// Async variant for callers in an `async throws` context (the IMAP
    /// connect path).
    public func withSecretString<T>(_ body: (String) async throws -> T) async rethrows -> T? {
        let data: Data
        switch auth {
        case .password(let d): data = d
        case .oauth2(let d):   data = d
        }
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        return try await body(s)
    }

    /// Zero the underlying secret bytes. Call after the credentials have
    /// been consumed (typically right after `IMAPClientProtocol.connect`
    /// returns or throws). Replaces the case payload with empty `Data`
    /// after overwriting the original buffer with zeros via `memset_s`.
    ///
    /// Caveat: Swift's `Data` is copy-on-write with reference-counted
    /// storage. If multiple references to the same underlying buffer
    /// exist, only ours is zeroed — other references keep their copy.
    /// That's why the contract is "call before the credentials go out of
    /// scope" — at that point ARC should have us at refcount 1.
    public mutating func clearSecrets() {
        switch auth {
        case .password(var data):
            data.withUnsafeMutableBytes { buf in
                if let base = buf.baseAddress, buf.count > 0 {
                    _ = memset_s(base, buf.count, 0, buf.count)
                }
            }
            self.auth = .password(Data())
        case .oauth2(var data):
            data.withUnsafeMutableBytes { buf in
                if let base = buf.baseAddress, buf.count > 0 {
                    _ = memset_s(base, buf.count, 0, buf.count)
                }
            }
            self.auth = .oauth2(accessToken: Data())
        }
    }
}

public struct HeadersFetch: Sendable {
    public let totalCount: Int
    public let stream: AsyncThrowingStream<MessageHeader, Error>

    public init(totalCount: Int, stream: AsyncThrowingStream<MessageHeader, Error>) {
        self.totalCount = totalCount
        self.stream = stream
    }
}

public struct UIDFlagsSnapshot: Sendable {
    public let uidValidity: UInt64
    public let messageCount: Int
    public let entries: [Entry]

    public init(uidValidity: UInt64, messageCount: Int, entries: [Entry]) {
        self.uidValidity = uidValidity
        self.messageCount = messageCount
        self.entries = entries
    }

    public struct Entry: Sendable {
        public let uid: UInt32
        public let isRead: Bool

        public init(uid: UInt32, isRead: Bool) {
            self.uid = uid
            self.isRead = isRead
        }
    }
}

public protocol IMAPClientProtocol: Sendable {
    func connect(_ credentials: AccountCredentials) async throws
    func disconnect() async

    func fetchHeaders(accountId: UUID, mailbox: String) async throws -> HeadersFetch
    func fetchHeaders(uids: Set<UInt32>, accountId: UUID, mailbox: String) async throws -> HeadersFetch
    func fetchUIDFlags(accountId: UUID, mailbox: String) async throws -> UIDFlagsSnapshot
    /// Delete by UID. `expectedUIDValidity` — when non-nil — pins the operation
    /// to the UIDVALIDITY the caller's UIDs were captured under. The
    /// implementation re-selects the mailbox, reads the server's current
    /// UIDVALIDITY, and throws `IMAPClientError.uidValidityChanged` if they
    /// don't match. Pass `nil` only when there's no prior validity to compare
    /// against (e.g. ad-hoc tooling that built UIDs in the same call).
    func deleteMessages(uids: [UInt32], in mailbox: String, expectedUIDValidity: UInt64?) async throws
    /// Move by UID. Same UIDVALIDITY semantics as `deleteMessages`.
    func moveMessages(uids: [UInt32], from source: String, to destination: String, expectedUIDValidity: UInt64?) async throws
    func listMailboxes() async throws -> [Mailbox]
    func createMailbox(_ name: String) async throws
    func deleteMailbox(_ name: String) async throws
    func renameMailbox(from source: String, to destination: String) async throws
    func mailboxStatus(_ name: String) async throws -> MailboxStatus
    /// Permanently remove every message in `mailbox`. Used by the
    /// "Empty Trash" action — flags everything `\Deleted` and EXPUNGEs in
    /// one selection. Returns the number of messages that were present at
    /// selection time (best-effort: server may have changed it concurrently).
    func emptyMailbox(_ name: String) async throws -> Int
}

/// Validates user-typed mailbox names before they reach the IMAP wire
/// serializer. Rejects characters IMAP forbids in mailbox names (RFC 3501
/// §5.1) — CR, LF, NUL, and the other C0 controls plus DEL.
///
/// This is defense in depth against a specific class of input attack: a
/// pasted (or hostile) folder name containing embedded `\r\n` could break
/// IMAP's command framing and let an attacker append a second tag-prefixed
/// command (e.g. `\r\nA002 DELETE INBOX\r\n`). The IMAP encoder downstream
/// (NIOIMAPCore inside SwiftMail) should already reject these, but
/// enforcing the rule at our boundary means we don't depend on encoder
/// behavior in any specific release of the upstream library.
///
/// Wildcards (`*`, `%`) and hierarchy delimiters (`/`, `.`) are deliberately
/// allowed — they're permitted in mailbox names per RFC 3501 §5.1.2, and a
/// user-typed `Receipts/2026` is a legitimate nested folder.
public enum IMAPMailboxName {
    /// Throws `IMAPClientError.invalidMailboxName` when `name` contains a
    /// character that's unsafe to ship to an IMAP server. Otherwise returns.
    public static func validate(_ name: String) throws {
        guard !name.isEmpty else {
            throw IMAPClientError.invalidMailboxName("Folder name is empty.")
        }
        for scalar in name.unicodeScalars {
            let v = scalar.value
            if v < 0x20 {
                throw IMAPClientError.invalidMailboxName(
                    "Folder names can't contain control characters (including newlines)."
                )
            }
            if v == 0x7F {
                throw IMAPClientError.invalidMailboxName(
                    "Folder names can't contain the DEL character."
                )
            }
        }
    }

    /// Non-throwing convenience for UI live-validation. Returns `nil` when
    /// the name is acceptable, or a user-facing reason when it isn't.
    public static func validationError(_ name: String) -> String? {
        do {
            try validate(name)
            return nil
        } catch let IMAPClientError.invalidMailboxName(reason) {
            return reason
        } catch {
            return error.localizedDescription
        }
    }
}

public enum IMAPClientError: LocalizedError {
    case notConnected
    case fetchFailed(String)
    case authFailed(String)
    case underlying(Error)
    /// The mailbox's UIDVALIDITY changed server-side between when the caller
    /// captured the UIDs (`expected`) and when the operation was about to
    /// commit (`actual`). The operation is refused — those UIDs no longer
    /// refer to the messages the caller intended. Caller should refresh and
    /// surface the error to the user.
    case uidValidityChanged(expected: UInt64, actual: UInt64)
    /// Caller passed a mailbox name containing characters IMAP forbids
    /// (CR, LF, NUL, other control bytes). Refused at the client boundary
    /// rather than passed to the encoder — defense in depth against CRLF
    /// command-injection through pasted-in or hostile folder names.
    case invalidMailboxName(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:        "Not connected to a mail server."
        case .fetchFailed(let m):  "Couldn't fetch messages: \(DisplaySanitizer.sanitizeForLog(m))"
        case .authFailed(let m):   "Sign-in failed: \(DisplaySanitizer.sanitizeForLog(m))"
        case .underlying(let e):   IMAPClientError.describe(e)
        case .uidValidityChanged:
            "The mailbox changed on the server. Please refresh and try again — File13 refused to act on stale message IDs."
        case .invalidMailboxName(let reason):
            "That folder name isn't valid: \(reason)"
        }
    }

    public static func describe(_ error: Error) -> String {
        let localized = error.localizedDescription
        let raw: String
        if localized.hasPrefix("The operation couldn't be completed") {
            raw = String(describing: error)
        } else {
            raw = localized
        }
        // A hostile or just-buggy IMAP server can return error text that
        // is arbitrarily long, includes ANSI escapes, or contains other
        // control bytes. The reason string lands in `lastError` (visible
        // in the UI) and in CLI stderr; both are corruption surfaces.
        // Cap and sanitize before propagating.
        return DisplaySanitizer.sanitizeForLog(raw)
    }
}
