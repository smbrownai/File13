import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// Hardened `URLSession` shared by every third-party LLM provider
/// (`AnthropicProvider`, `OpenAIProvider`, `GoogleProvider`,
/// `PerplexityProvider`). Trades the conveniences of `URLSession.shared`
/// for guarantees the shared session can't make about how API credentials
/// are handled.
///
/// Why this exists — the redirect leak that motivated it:
///
/// `URLSession.shared` follows HTTP redirects by default. Its built-in
/// cross-host protection strips a small set of sensitive headers
/// (`Authorization`, `Cookie`, `WWW-Authenticate`, and a handful of
/// proxy-related ones) when redirecting to a different origin. **Custom
/// headers are not stripped.** Anthropic authenticates with `x-api-key`,
/// Google embeds the key as `?key=…` in the URL query string — both bypass
/// the stripping rule. A 3xx from `api.anthropic.com` to any other host
/// would have URLSession forward the user's API key to that host.
///
/// API endpoints don't legitimately redirect. Anthropic, OpenAI, Google,
/// and Perplexity each serve their JSON RPC from a single canonical host;
/// a 3xx is either a deployment glitch we want to surface as an error or
/// an attack we want to refuse. So this session **refuses every redirect**.
///
/// Also ephemeral (no cookie storage, no URL cache, no credential
/// storage) so nothing about the request persists across the call.
public enum LLMURLSession {
    public static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(
            configuration: config,
            delegate: LLMSessionDelegate(),
            delegateQueue: nil
        )
    }()
}

/// SPKI pins for the AI provider hosts. Empty by default — see the comment
/// on `LLMSessionDelegate` for how to populate. When a pin set exists for a
/// host, every certificate in that host's chain must be checked and at
/// least one SPKI in the chain must match one of the listed pins.
///
/// To compute a pin from a known-good cert (assuming an offline PEM at
/// `cert.pem`):
///
/// ```sh
/// openssl x509 -in cert.pem -pubkey -noout \
///   | openssl pkey -pubin -outform der \
///   | openssl dgst -sha256 -binary \
///   | openssl enc -base64
/// ```
///
/// Pin against intermediate or leaf CA SPKIs — pinning to the root makes
/// CA-rotation surprises harder to recover from, pinning to the leaf
/// breaks every ~90 days on Let's Encrypt rotations. Each host should have
/// a primary + at least one backup pin so a single rotation doesn't take
/// the provider offline for everyone.
///
/// **Status (2026-05-16):** structure is in place, pin values are not
/// populated. Without populated pins the delegate falls back to standard
/// ATS validation (still TLS-required and hostname-bound; just no MITM
/// resistance against CA-issued attacker certs). Populating pins is a
/// deployment step that has to be verified against each provider's live
/// chain before shipping.
public enum LLMTLSPins {
    /// Base64-encoded SHA-256 hashes of the SubjectPublicKeyInfo (SPKI) for
    /// trusted CA certificates per host. Populate before shipping. Keep
    /// this private — pin rotations are an operational matter.
    public static let pinsByHost: [String: Set<String>] = [
        "api.anthropic.com":                  [],
        "api.openai.com":                     [],
        "generativelanguage.googleapis.com":  [],
        "api.perplexity.ai":                  [],
    ]
}

/// Combined `URLSessionDelegate` + `URLSessionTaskDelegate` that does two
/// things, in order:
///
/// 1. **Refuses every HTTP redirect.** API endpoints don't legitimately
///    redirect, and a 3xx can leak `x-api-key` (Anthropic) or the
///    `?key=` query parameter (Google) — URLSession's built-in cross-
///    origin header stripping only covers `Authorization` / `Cookie` /
///    a few proxy-related headers.
/// 2. **Enforces SPKI pinning** when `LLMTLSPins.pinsByHost` has any pin
///    for the request host. The pin-set semantics: every certificate in
///    the server's evaluated chain has its SubjectPublicKeyInfo hashed
///    (SHA-256), and the chain must contain at least one hash that
///    matches a pinned value for the host. When the host isn't in the
///    pin table (or its pin set is empty), this delegate accepts the
///    chain that the system's default trust evaluation already approved
///    — i.e. behaves like the system default.
///
/// `URLSession` calls the session-level `didReceive:` for any task that
/// doesn't have a task-level handler. We don't override the task-level
/// one, so this handler fires for every request through `LLMURLSession`.
private final class LLMSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only handle the server-trust authentication method. Anything else
        // (basic auth, client cert, etc.) we delegate to the default
        // handler — the providers don't use those.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        let expectedPins = LLMTLSPins.pinsByHost[host] ?? []

        // System-default evaluation still has to pass — pinning is added
        // defense, not a replacement for hostname + expiry + chain checks.
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // No pins for this host: respect the system result.
        if expectedPins.isEmpty {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        // Pin check: every certificate in the chain has its SPKI hashed;
        // any match against an expected pin satisfies the challenge.
        let certCount: CFIndex
        if #available(macOS 12.0, iOS 15.0, *) {
            certCount = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate])?.count ?? 0
        } else {
            certCount = SecTrustGetCertificateCount(serverTrust)
        }

        for index in 0..<certCount {
            let cert: SecCertificate?
            if #available(macOS 12.0, iOS 15.0, *) {
                let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate]
                cert = chain?[index]
            } else {
                cert = SecTrustGetCertificateAtIndex(serverTrust, index)
            }
            guard let cert,
                  let spkiHash = Self.spkiSHA256Base64(for: cert) else { continue }
            if expectedPins.contains(spkiHash) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        // No pin matched. Refuse the connection rather than fall back to
        // system trust — that's the whole point of pinning.
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    /// Extract the SubjectPublicKeyInfo from a SecCertificate, hash it
    /// with SHA-256, and return the base64 encoding. Returns nil when
    /// the certificate's public key isn't extractable (very rare with
    /// well-formed X.509).
    ///
    /// Note: `SecCertificateCopyKey` returns the public key, and
    /// `SecKeyCopyExternalRepresentation` for RSA/EC keys returns the
    /// raw key — not the full SPKI DER. To compute a SPKI pin that
    /// matches the openssl recipe above, we wrap the raw key bytes with
    /// the standard SPKI AlgorithmIdentifier header for the key's type.
    /// CryptoKit doesn't expose ASN.1 helpers and we want to avoid a
    /// dependency, so we use the known fixed-prefix table for the
    /// common public-key types (RSA-2048, RSA-4096, ECDSA P-256,
    /// ECDSA P-384) — the same approach Apple recommends for manual
    /// pinning.
    private static func spkiSHA256Base64(for certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            return nil
        }
        guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let keyType = attributes[kSecAttrKeyType] as? String,
              let keySize = attributes[kSecAttrKeySizeInBits] as? Int else {
            return nil
        }
        guard let prefix = spkiPrefix(keyType: keyType, keySize: keySize) else { return nil }
        var spki = Data()
        spki.append(prefix)
        spki.append(keyData)
        let digest = SHA256.hash(data: spki)
        return Data(digest).base64EncodedString()
    }

    /// SubjectPublicKeyInfo ASN.1 prefix bytes for the supported key
    /// types. Lifted from RFC 5280 / RFC 5480 — these are the standard
    /// SPKI headers prepended to the raw public-key bytes that Apple's
    /// `SecKeyCopyExternalRepresentation` returns.
    private static func spkiPrefix(keyType: String, keySize: Int) -> Data? {
        let rsa = kSecAttrKeyTypeRSA as String
        let ec  = kSecAttrKeyTypeECSECPrimeRandom as String
        if keyType == rsa && keySize == 2048 {
            return Data([
                0x30,0x82,0x01,0x22,0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,
                0x01,0x05,0x00,0x03,0x82,0x01,0x0f,0x00
            ])
        }
        if keyType == rsa && keySize == 4096 {
            return Data([
                0x30,0x82,0x02,0x22,0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,
                0x01,0x05,0x00,0x03,0x82,0x02,0x0f,0x00
            ])
        }
        if keyType == ec && keySize == 256 {
            return Data([
                0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,
                0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00
            ])
        }
        if keyType == ec && keySize == 384 {
            return Data([
                0x30,0x76,0x30,0x10,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,0x06,0x05,0x2b,
                0x81,0x04,0x00,0x22,0x03,0x62,0x00
            ])
        }
        return nil
    }
}
