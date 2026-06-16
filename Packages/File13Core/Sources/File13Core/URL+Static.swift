import Foundation

extension URL {
    /// Build a `URL` from a string literal that the author has verified is
    /// well-formed at write time (provider endpoints, marketing site links,
    /// preset help URLs, etc.).
    ///
    /// `URL.init?(string:)` returns nil on parse failure; the historical
    /// idiom around the codebase was `URL(string: "…")!`, which would crash
    /// with a generic "unexpectedly found nil" message that doesn't tell
    /// you *which* URL failed. This helper preserves the trap-on-failure
    /// semantics (a malformed literal is a programmer error, not a runtime
    /// condition) but the assertion message names the offending string and
    /// pinpoints the call site.
    ///
    /// Use *only* for compile-time constants. Anything coming from user
    /// input, configuration, or the network must still go through the
    /// optional initializer.
    public static func verified(
        _ string: String,
        file: StaticString = #file,
        line: UInt = #line
    ) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure(
                "URL.verified called with malformed string literal: \(string)",
                file: file,
                line: line
            )
        }
        return url
    }
}
