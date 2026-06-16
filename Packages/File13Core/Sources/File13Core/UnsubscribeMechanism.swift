import Foundation

/// One usable unsubscribe path extracted from RFC 2369 `List-Unsubscribe` (and RFC 8058
/// `List-Unsubscribe-Post`) headers.
public enum UnsubscribeMechanism: Hashable, Sendable {
    /// HTTPS URL the server has explicitly marked as one-click safe (RFC 8058). We POST to it
    /// with `List-Unsubscribe=One-Click` body and unsubscribe is complete.
    case oneClick(URL)
    /// Plain HTTPS URL — typically opens a confirmation page in the browser. We hand off via
    /// `NSWorkspace.shared.open(_:)` and let the user click through.
    case web(URL)
    /// `mailto:` URI. We hand off to the user's default mail client (we can't compose mail
    /// ourselves — the spec forbids any outbound mail except the unsubscribe reply, and we don't
    /// have SMTP wired). The user's mail client sends the message.
    case mailto(URL, address: String)

    public var label: String {
        switch self {
        case .oneClick:                        "One-click web"
        case .web:                             "Web link"
        case .mailto(_, let address):          "Email \(address)"
        }
    }

    public var openableURL: URL {
        switch self {
        case .oneClick(let url), .web(let url): url
        case .mailto(let url, _):               url
        }
    }
}

public enum UnsubscribeParser {
    /// Parse a `List-Unsubscribe` header (and the optional `List-Unsubscribe-Post`) into the set
    /// of mechanisms the user agent can use, ordered by preference.
    ///
    /// RFC 2369 grammar: comma-separated list of `<URI>` tokens. The URI can be `mailto:` or HTTPS.
    /// RFC 8058 says: when `List-Unsubscribe-Post: List-Unsubscribe=One-Click` is present, any
    /// HTTPS URL in the list is safe to POST to without further user interaction.
    public static func parse(listUnsubscribe: String?, listUnsubscribePost: String?) -> [UnsubscribeMechanism] {
        guard let raw = listUnsubscribe, !raw.isEmpty else { return [] }
        let tokens = extractAngleBracketedTokens(from: raw)

        let allowsOneClick = (listUnsubscribePost ?? "")
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .contains("list-unsubscribe=one-click")

        var mechanisms: [UnsubscribeMechanism] = []
        for token in tokens {
            if token.hasPrefix("mailto:") {
                if let url = URL(string: token), let address = mailtoAddress(from: token) {
                    mechanisms.append(.mailto(url, address: address))
                }
                continue
            }
            if let url = URL(string: token), let scheme = url.scheme?.lowercased() {
                if scheme == "https" {
                    mechanisms.append(allowsOneClick ? .oneClick(url) : .web(url))
                } else if scheme == "http" {
                    // Plain HTTP — never auto-POST to it; defer to the user.
                    mechanisms.append(.web(url))
                }
            }
        }

        // Stable ordering: one-click first, then web, then mailto. Matches what we'd auto-prefer.
        return mechanisms.sorted { lhs, rhs in priority(lhs) < priority(rhs) }
    }

    private static func priority(_ m: UnsubscribeMechanism) -> Int {
        switch m {
        case .oneClick: 0
        case .web:      1
        case .mailto:   2
        }
    }

    /// Pull `<…>`-bracketed tokens out of a header value. The header may contain whitespace,
    /// folded lines, and commas inside or outside the brackets; only the bracketed payload is
    /// significant per RFC 2369.
    private static func extractAngleBracketedTokens(from raw: String) -> [String] {
        var results: [String] = []
        var current: String?
        for ch in raw {
            switch ch {
            case "<":
                current = ""
            case ">":
                if let c = current { results.append(c.trimmingCharacters(in: .whitespacesAndNewlines)) }
                current = nil
            default:
                if current != nil { current?.append(ch) }
            }
        }
        return results
    }

    private static func mailtoAddress(from raw: String) -> String? {
        // Strip "mailto:" prefix and any query string.
        let withoutScheme = raw.replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive, .anchored])
        let address = withoutScheme.split(separator: "?", maxSplits: 1).first.map(String.init) ?? withoutScheme
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
