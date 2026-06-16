import AppKit
import AuthenticationServices
import File13Core
import Foundation

/// Drives a single OAuth sign-in: opens `ASWebAuthenticationSession` against
/// the provider's authorize URL, validates the redirect, exchanges the code
/// for tokens, and resolves the user's email so we can build an `Account`
/// and persist credentials.
///
/// The class is intentionally one-shot — instantiate, call `run`, discard.
/// `ASWebAuthenticationSession` requires a presentation context provider,
/// which has to be an `NSObject`. We attach one inline.
@MainActor
final class OAuthFlow: NSObject {
    private let client: OAuth2Client
    private var session: ASWebAuthenticationSession?
    private var contextProvider: PresentationContextProvider?

    init(client: OAuth2Client) {
        self.client = client
        super.init()
    }

    func run() async throws -> OAuthGrant {
        let state = OAuth2Client.generateState()
        let codeVerifier = OAuth2Client.generateCodeVerifier()
        let authorizeURL = try client.authorizeURL(state: state, codeVerifier: codeVerifier)

        let callbackURL = try await presentAuthSession(authorizeURL: authorizeURL)
        let code = try validateCallback(callbackURL, expectedState: state)
        let tokens = try await client.exchange(authorizationCode: code, codeVerifier: codeVerifier)
        let email = try await client.fetchEmail(using: tokens.accessToken)
        return OAuthGrant(email: email, tokens: tokens)
    }

    // MARK: - Web auth session

    /// Wrap `ASWebAuthenticationSession.start` in an async/throws shape. The
    /// system invokes the completion with `(URL?, Error?)` — translate to
    /// our typed errors so the caller can branch on `.userCancelled`.
    private func presentAuthSession(authorizeURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: client.config.redirectScheme
            ) { callbackURL, error in
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: OAuthError.authorizationFailed(error.localizedDescription))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.authorizationFailed("provider returned no callback URL"))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            let provider = PresentationContextProvider()
            session.presentationContextProvider = provider
            // Force a fresh in-app browser session each time. Without this the
            // system reuses the user's Safari cookies — fine for Gmail, but a
            // signed-in user on a shared Mac would otherwise grant access to
            // the wrong identity. `false` keeps each File13 sign-in in its
            // own ephemeral context.
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            self.contextProvider = provider
            if !session.start() {
                continuation.resume(throwing: OAuthError.authorizationFailed("couldn't start authentication session"))
            }
        }
    }

    private func validateCallback(_ url: URL, expectedState: String) throws -> String {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OAuthError.authorizationFailed("invalid callback URL")
        }
        let items = comps.queryItems ?? []
        if let providerError = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value ?? providerError
            throw OAuthError.authorizationFailed(description)
        }
        guard let returnedState = items.first(where: { $0.name == "state" })?.value, returnedState == expectedState else {
            throw OAuthError.authorizationFailed("state mismatch — possible CSRF, sign-in aborted")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OAuthError.authorizationFailed("no authorization code in callback")
        }
        return code
    }
}

private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Prefer the key window — fall back to the first window in case the
        // user triggered sign-in while a sheet stole focus. The system
        // tolerates either as long as we return *some* window.
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
