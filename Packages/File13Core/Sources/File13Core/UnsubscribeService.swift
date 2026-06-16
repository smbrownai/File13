import Foundation
#if os(macOS)
import AppKit
#endif

/// Performs an unsubscribe via the mechanism extracted from a message. The
/// RFC 8058 one-click HTTPS POST path is cross-platform and lives in
/// `postOneClick(to:)`; the macOS dispatch helper `perform(_:)` additionally
/// handles `.web` and `.mailto` by handing the URL to `NSWorkspace`. On iOS
/// the caller hands `.web` / `.mailto` mechanisms to SwiftUI's `openURL`
/// environment itself — there's no `NSWorkspace` analog that doesn't pull in
/// a UIApplication reference.
///
/// We never compose or send mail ourselves — that's outside the spec's
/// "single automated unsubscribe reply" exception, and we don't have SMTP
/// wired.
public struct UnsubscribeService: Sendable {
    public enum Outcome: Sendable {
        /// One-click POST completed and the server returned a 2xx response.
        case oneClickSucceeded(statusCode: Int)
        /// One-click POST completed but the server returned a non-success status. Body included
        /// for diagnostics.
        case oneClickServerError(statusCode: Int, body: String?)
        /// Network or request-level failure during one-click POST.
        case oneClickFailed(message: String)
        /// The web/mailto URL was opened in an external app (browser or mail client).
        case openedExternally
        /// Tried to open externally but `NSWorkspace` refused.
        case externalOpenFailed
    }

    public init() {}

    #if os(macOS)
    /// - Parameters:
    ///   - mechanism: which unsubscribe path to follow.
    ///   - mailClientAppURL: optional override for `mailto:` links (e.g. Spark instead of Mail).
    ///   - browserAppURL: optional override for web confirmation pages (e.g. Firefox instead of
    ///     the system default). Has no effect on one-click HTTPS unsubscribes — those are POSTed
    ///     directly by File13 and never open a browser.
    ///
    /// macOS-only because the `.web` / `.mailto` cases route through
    /// `NSWorkspace`. iOS callers should use `postOneClick(to:)` for
    /// one-click HTTPS and `openURL` (SwiftUI environment) for the others.
    public func perform(
        _ mechanism: UnsubscribeMechanism,
        mailClientAppURL: URL? = nil,
        browserAppURL: URL? = nil
    ) async -> Outcome {
        switch mechanism {
        case .oneClick(let url):
            return await postOneClick(to: url)
        case .web(let url):
            return await openExternally(url, withApplicationAt: browserAppURL)
        case .mailto(let url, _):
            return await openExternally(url, withApplicationAt: mailClientAppURL)
        }
    }
    #endif

    /// RFC 8058 one-click POST. Cross-platform — only depends on Foundation.
    /// Refuses non-HTTPS URLs outright, even though `UnsubscribeParser`
    /// already enforces the scheme for the `.oneClick` case.
    public func postOneClick(to url: URL) async -> Outcome {
        // Defense in depth — the parser already requires `https` for one-click,
        // but a hand-built `UnsubscribeMechanism.oneClick(...)` could slip a
        // non-HTTPS URL through. Refuse cleartext outright.
        guard url.scheme?.lowercased() == "https" else {
            return .oneClickFailed(message: "Unsubscribe URL isn't HTTPS.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "List-Unsubscribe=One-Click".data(using: .utf8)

        let session = Self.hardenedSession
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .oneClickFailed(message: "Server didn't return an HTTP response.")
            }
            if (200..<300).contains(http.statusCode) {
                return .oneClickSucceeded(statusCode: http.statusCode)
            }
            return .oneClickServerError(
                statusCode: http.statusCode,
                body: String(data: data.prefix(512), encoding: .utf8)
            )
        } catch {
            return .oneClickFailed(message: error.localizedDescription)
        }
    }

    /// Hardened `URLSession` used for one-click unsubscribe POSTs. Built once
    /// per process — the configuration is identical for every call and
    /// `URLSession` is thread-safe.
    ///
    /// Trades the conveniences of `URLSession.shared` for three guarantees the
    /// shared session can't make:
    /// - **Ephemeral cookie store.** Tracking cookies set in the response
    ///   never reach `HTTPCookieStorage.shared`, so they can't follow the
    ///   user into Safari or any other `URLSession.shared` consumer.
    /// - **HTTPS-only redirects.** The delegate cancels any redirect whose
    ///   target isn't `https`. Stops a sender that ships a valid one-click
    ///   endpoint from 302-bouncing the POST to `http://tracker/?email=…`.
    /// - **Short timeout and no caching.** 15 s ceiling so a hung tracker
    ///   can't tie up the unsubscribe task; no URL cache so response bodies
    ///   never touch disk.
    ///
    /// Same hardening should apply if File13 ever adds outbound HTTP calls
    /// that follow user-controlled URLs.
    private static let hardenedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        // Generic UA so the request doesn't leak the user's build / locale.
        config.httpAdditionalHeaders = ["User-Agent": "File13/1.0"]
        return URLSession(
            configuration: config,
            delegate: HTTPSOnlyRedirectGuard(),
            delegateQueue: nil
        )
    }()

    #if os(macOS)
    @MainActor
    private func openExternally(_ url: URL, withApplicationAt appURL: URL?) async -> Outcome {
        guard let appURL else {
            return NSWorkspace.shared.open(url) ? .openedExternally : .externalOpenFailed
        }
        let configuration = NSWorkspace.OpenConfiguration()
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
            return .openedExternally
        } catch {
            // Fall back to the system default rather than failing outright — better that the
            // user's unsubscribe goes through *some* mail client than none.
            return NSWorkspace.shared.open(url) ? .openedExternally : .externalOpenFailed
        }
    }
    #endif
}

/// `URLSessionTaskDelegate` that refuses to follow any redirect whose new URL
/// isn't HTTPS. Calling the completion handler with `nil` cancels the redirect
/// without erroring the task — the original 3xx response surfaces to the
/// caller, which is fine: a sender that responds with a non-HTTPS redirect
/// just gets a "server error" outcome instead of a silent tracker hit.
private final class HTTPSOnlyRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if request.url?.scheme?.lowercased() == "https" {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
