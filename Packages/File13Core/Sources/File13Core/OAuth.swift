import Foundation

/// Per-provider OAuth2 configuration: authorize endpoint, token endpoint,
/// the scopes File13 needs (IMAP access + `email` for the user-info call
/// + `offline_access` where required), and the user-info endpoint we hit
/// after a successful token exchange to learn the authenticated email
/// address. Providers like Gmail/Microsoft only return tokens in the OAuth
/// response — the IMAP SASL XOAUTH2 challenge needs the email separately.
public struct OAuthProviderConfig: Sendable {
    public let kind: Account.AuthKind
    public let authorizeURL: URL
    public let tokenURL: URL
    public let userInfoURL: URL
    public let scopes: [String]
    public let clientID: String
    /// URL scheme `ASWebAuthenticationSession` watches for in the callback.
    /// Must match the scheme component of `redirectURI` and must appear in
    /// `CFBundleURLSchemes` in `Info.plist` — without the plist registration
    /// the system rejects the callback.
    public let redirectScheme: String
    /// Exact redirect URI passed to the provider's authorize endpoint.
    /// Stored verbatim (not built from scheme + path) because providers
    /// disagree on form: Google's iOS OAuth client expects
    /// `<bundle-id>:/<path>` with a single slash, while Microsoft and the
    /// RFC use `<scheme>://<host>/<path>`.
    public let redirectURI: String

    public init(
        kind: Account.AuthKind,
        authorizeURL: URL,
        tokenURL: URL,
        userInfoURL: URL,
        scopes: [String],
        clientID: String,
        redirectScheme: String,
        redirectURI: String
    ) {
        self.kind = kind
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.userInfoURL = userInfoURL
        self.scopes = scopes
        self.clientID = clientID
        self.redirectScheme = redirectScheme
        self.redirectURI = redirectURI
    }
}

/// No OAuth providers are wired up right now. Each candidate hit a
/// distribution-time wall that wasn't worth paying:
///
/// - **Gmail**: `https://mail.google.com/` is a *restricted* scope. Removing
///   the "unverified app" warning requires an annual CASA security audit
///   (~$15k+/year). No narrower scope supports IMAP mutations.
/// - **Microsoft (Outlook)**: multi-tenant apps now require Publisher
///   Verification before users outside the home tenant can consent. The
///   Microsoft Cloud Partner Program signup gating verification requires a
///   work/school account or paid Microsoft 365 Business subscription —
///   unavailable to indie developers without ties to an existing tenant.
///   Microsoft also retired basic-auth IMAP for personal accounts
///   (outlook.com / hotmail.com / live.com) in September 2024, so even
///   the app-password fallback is mostly dead for those.
/// - **iCloud**: no IMAP OAuth flow exists (Apple requires app-specific
///   passwords).
/// - **Yahoo / AOL**: third-party OAuth program is effectively closed to
///   new developer applicants.
///
/// The supporting code — `AccountCredentials.auth`, XOAUTH2 routing in
/// `SwiftMailIMAPClient`, `OAuth2Client`, `OAuthFlow`,
/// `KeychainStore.OAuthTokens`, the iCloud-Keychain migrator for tokens —
/// is intentionally left in place so a future viable provider can be
/// wired up by adding a new `Account.AuthKind` case and a config here.
public enum OAuthProviderCatalog {
    public static func config(for kind: Account.AuthKind) -> OAuthProviderConfig? {
        switch kind {
        case .password: return nil
        }
    }
}

public enum OAuthError: LocalizedError {
    case configurationMissing(String)
    case authorizationFailed(String)
    case tokenExchangeFailed(String)
    case userInfoFailed(String)
    case malformedResponse(String)
    case userCancelled

    public var errorDescription: String? {
        switch self {
        case .configurationMissing(let m): return "OAuth not configured: \(m)"
        case .authorizationFailed(let m):  return "Sign-in didn't finish: \(m)"
        case .tokenExchangeFailed(let m):  return "Couldn't get a token: \(m)"
        case .userInfoFailed(let m):       return "Couldn't read your account info: \(m)"
        case .malformedResponse(let m):    return "Unexpected response from the provider: \(m)"
        case .userCancelled:               return "Sign-in was cancelled."
        }
    }
}

/// Outcome of a successful OAuth flow — the tokens we'll persist plus the
/// email/username we resolved via the provider's user-info endpoint.
public struct OAuthGrant: Sendable {
    public let email: String
    public let tokens: KeychainStore.OAuthTokens

    public init(email: String, tokens: KeychainStore.OAuthTokens) {
        self.email = email
        self.tokens = tokens
    }
}

/// Provider-agnostic OAuth2 client: handles PKCE, the token exchange, and
/// refresh. Doesn't open the auth UI itself — that's `OAuthFlow`, which
/// drives `ASWebAuthenticationSession`. Split so the network logic is
/// testable without a real browser.
public struct OAuth2Client: Sendable {
    public let config: OAuthProviderConfig
    public let urlSession: URLSession

    /// Defaults to the hardened `LLMURLSession.shared` (no redirects,
    /// ephemeral) — same rationale as the AI providers: a 3xx from a token
    /// or user-info endpoint shouldn't be silently followed, because OAuth
    /// tokens we just minted ride the next request.
    public init(config: OAuthProviderConfig, urlSession: URLSession = LLMURLSession.shared) {
        self.config = config
        self.urlSession = urlSession
    }

    /// Build the authorize URL with PKCE. The returned `state` and
    /// `codeVerifier` are caller-owned: the caller verifies `state` against
    /// the redirect query and feeds `codeVerifier` back into `exchange`.
    public func authorizeURL(state: String, codeVerifier: String) throws -> URL {
        guard !config.clientID.contains("REPLACE_WITH") else {
            throw OAuthError.configurationMissing(
                "client ID not set — see comments in OAuth.swift for how to register File13 with the provider"
            )
        }
        var comps = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)!
        let codeChallenge = OAuth2Client.codeChallenge(for: codeVerifier)
        comps.queryItems = [
            URLQueryItem(name: "client_id",             value: config.clientID),
            URLQueryItem(name: "redirect_uri",          value: config.redirectURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state",                 value: state),
            URLQueryItem(name: "code_challenge",        value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Google requires `access_type=offline` + `prompt=consent` to
            // reliably return a refresh token. Microsoft uses
            // `offline_access` as a scope (already added above) and ignores
            // these query params, so leaving them in is harmless.
            URLQueryItem(name: "access_type",           value: "offline"),
            URLQueryItem(name: "prompt",                value: "consent")
        ]
        guard let url = comps.url else {
            throw OAuthError.malformedResponse("Couldn't build authorize URL")
        }
        return url
    }

    /// Exchange the authorization code returned by the provider for an
    /// access + refresh token pair.
    public func exchange(authorizationCode code: String, codeVerifier: String) async throws -> KeychainStore.OAuthTokens {
        let body: [String: String] = [
            "client_id":     config.clientID,
            "redirect_uri":  config.redirectURI,
            "grant_type":    "authorization_code",
            "code":          code,
            "code_verifier": codeVerifier
        ]
        return try await postForTokens(body, errorKind: .tokenExchangeFailed)
    }

    /// Use a refresh token to mint a new access token (and possibly a new
    /// refresh token — Google rotates them sporadically; Microsoft rotates
    /// every refresh). Preserves the previous refresh token if the response
    /// omits one, since some providers (Google) only return it on first
    /// consent.
    public func refresh(_ tokens: KeychainStore.OAuthTokens) async throws -> KeychainStore.OAuthTokens {
        let body: [String: String] = [
            "client_id":     config.clientID,
            "grant_type":    "refresh_token",
            "refresh_token": tokens.refreshToken
        ]
        var refreshed = try await postForTokens(body, errorKind: .tokenExchangeFailed)
        if refreshed.refreshToken.isEmpty {
            refreshed.refreshToken = tokens.refreshToken
        }
        return refreshed
    }

    /// Hit the provider's user-info endpoint to resolve the email of the
    /// signed-in user. Gmail uses OIDC `email`; Microsoft Graph uses
    /// `userPrincipalName` (falls back to `mail` for personal accounts).
    public func fetchEmail(using accessToken: String) async throws -> String {
        var request = URLRequest(url: config.userInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthError.userInfoFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.malformedResponse("user-info wasn't JSON")
        }
        if let email = payload["email"] as? String, !email.isEmpty { return email }
        if let upn = payload["userPrincipalName"] as? String, !upn.isEmpty { return upn }
        if let mail = payload["mail"] as? String, !mail.isEmpty { return mail }
        throw OAuthError.userInfoFailed("no email field in response")
    }

    // MARK: - Internals

    private enum PostErrorKind { case tokenExchangeFailed }

    private func postForTokens(_ body: [String: String], errorKind: PostErrorKind) async throws -> KeychainStore.OAuthTokens {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\(percentEscape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(text)")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.malformedResponse("token response wasn't JSON")
        }
        guard let accessToken = payload["access_token"] as? String, !accessToken.isEmpty else {
            throw OAuthError.malformedResponse("token response missing access_token")
        }
        // Microsoft returns expires_in as a number; Google sometimes returns
        // it as a string. Tolerate both.
        let expiresIn: TimeInterval
        if let n = payload["expires_in"] as? Double { expiresIn = n }
        else if let s = payload["expires_in"] as? String, let n = Double(s) { expiresIn = n }
        else { expiresIn = 3600 }
        let refresh = (payload["refresh_token"] as? String) ?? ""
        return KeychainStore.OAuthTokens(
            accessToken: accessToken,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    /// RFC 7636 §4.2: code_challenge = BASE64URL(SHA256(code_verifier)).
    public static func codeChallenge(for verifier: String) -> String {
        let hashed = SHA256.hash(of: Data(verifier.utf8))
        return base64URLEncode(hashed)
    }

    public static func generateCodeVerifier() -> String {
        // 32 bytes → 43 chars after base64url (within RFC 7636's [43,128] window).
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    public static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func percentEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - SHA-256

import CryptoKit

private enum SHA256 {
    static func hash(of data: Data) -> Data {
        Data(CryptoKit.SHA256.hash(data: data))
    }
}
