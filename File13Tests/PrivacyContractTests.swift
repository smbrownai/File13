import Foundation
import Testing
@testable import File13

/// Regression test for File13's load-bearing privacy claim: **metadata
/// only, never bodies**. The product's privacy contract (CLAUDE.md §
/// "Privacy contract", privacy.html § 3 & 4) hinges on the assertion
/// that the IMAP layer never reaches for message body content.
///
/// SwiftMail (the vendored IMAP client) exposes both metadata-only
/// fetches (`fetchSlimMessageInfos`, `fetchUIDFlags`, etc.) **and**
/// body-fetching fetches (`fetchPart`, `fetchRawMessage`,
/// `fetchMessage`, `fetchAllMessageParts`, `fetchPartsPipelined`,
/// `fetchAndDecodeMessagePartData`). File13's bridge
/// (`SwiftMailIMAPClient.swift`) is the *only* code that calls into
/// SwiftMail, so if no body-fetching API name appears there, the
/// privacy contract holds at the wire.
///
/// The test reads the source file at test time (via `#filePath` plus a
/// known repo-relative path) and walks the lines after stripping `//`
/// comments. Comment text is allowed to mention forbidden APIs —
/// `SwiftMailIMAPClient.swift:76` explains *why* we drop `BODY[HEADER]`,
/// for example. A real call to `s.fetchPart(...)` is what fails the
/// test.
///
/// **If this test ever fails, do not silence it.** It means a commit is
/// about to break the headline product claim; the right move is to
/// revert the offending code or audit it line by line.
@Suite struct PrivacyContractTests {

    /// Names that, if found as function calls in
    /// `SwiftMailIMAPClient.swift`, mean File13 is now pulling body
    /// content from the server. Match is "identifier followed by `(`"
    /// so that, e.g., a string `"fetchMessageInfo"` inside another
    /// method name doesn't false-positive — Swift function calls have
    /// the open-paren immediately after the identifier.
    ///
    /// Allowed (metadata-only): `fetchSlimMessageInfos`,
    /// `fetchMessageInfo`, `fetchMessageInfosBulk`,
    /// `fetchMessageInfos`, `fetchUIDFlags`, `fetchCapabilities`.
    private static let forbiddenAPIs: [String] = [
        "fetchPart",
        "fetchPartsPipelined",
        "fetchRawMessage",
        "fetchMessage",                    // returns `Message` with body parts
        "fetchAllMessageParts",
        "fetchAndDecodeMessagePartData",
        "fetchStructure"                   // BODYSTRUCTURE — drops one boolean
                                           // out, but for the same reason we
                                           // pinned the slim path (latency +
                                           // not strictly metadata) we don't
                                           // call it. If you ever need it for
                                           // the attachment-presence boolean,
                                           // explicitly carve it out here.
    ]

    /// IMAP fetch-item names that pull body bytes from the server.
    /// Matching is done on the cleaned-source string content — any
    /// occurrence is suspect. The `BODY[…]` pattern in particular is
    /// what shows up in raw `fetchAttributes:` calls.
    private static let forbiddenFetchItems: [String] = [
        "BODY[",          // BODY[], BODY[HEADER], BODY[TEXT], BODY[1]
        "RFC822.TEXT",
        "RFC822 ",        // RFC822 alone fetches the entire message
        "BODYSTRUCTURE",  // mime tree (filenames, sizes) — we don't want
                          // any of this off the wire; the slim path
                          // drops it.
    ]

    /// The fetch path we *do* permit. Asserted-present so that a
    /// future refactor that removes the slim path is visible — if the
    /// only allowed API isn't being called, something is wrong.
    private static let requiredAPIs: [String] = [
        "fetchSlimMessageInfos"
    ]

    @Test func swiftMailIMAPClientNeverCallsBodyFetchingAPIs() throws {
        let source = try Self.cleanedSource()

        for forbidden in Self.forbiddenAPIs {
            // Match `fetchPart(` etc. — identifier immediately followed
            // by `(` is a function call. Excludes the case where the
            // word appears inside another identifier (`fetchPartial…`).
            let pattern = "\\b\(forbidden)\\s*\\("
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..., in: source)
            let matches = regex.numberOfMatches(in: source, range: range)
            #expect(
                matches == 0,
                "SwiftMailIMAPClient.swift contains a call to `\(forbidden)(...)`. This is a body-fetching API and contradicts File13's metadata-only privacy contract. If this fetch is legitimate, audit it and add the API to the test's allow-list with a comment explaining the carve-out."
            )
        }
    }

    @Test func swiftMailIMAPClientNeverRequestsBodyItems() throws {
        let source = try Self.cleanedSource()
        for token in Self.forbiddenFetchItems {
            let occurrences = source.components(separatedBy: token).count - 1
            #expect(
                occurrences == 0,
                "SwiftMailIMAPClient.swift mentions `\(token)` in non-comment code. This is an IMAP fetch-item that pulls body content. File13's slim path explicitly drops these — see the privacy contract in CLAUDE.md."
            )
        }
    }

    @Test func swiftMailIMAPClientStillUsesTheSlimPath() throws {
        // Defense in depth: if a refactor *removes* the slim fetch
        // (e.g., switches to a generic fetch) the test should fire so
        // the privacy story doesn't quietly migrate to a less-careful
        // API. Comments allowed (the cleaned source still contains the
        // call site itself if it's a real call).
        let source = try Self.cleanedSource()
        for required in Self.requiredAPIs {
            let pattern = "\\b\(required)\\s*\\("
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..., in: source)
            let matches = regex.numberOfMatches(in: source, range: range)
            #expect(
                matches > 0,
                "Expected `\(required)(...)` to be called somewhere in SwiftMailIMAPClient.swift — it's the only fetch path the privacy contract permits. If it's been replaced, update this test and re-verify the replacement is metadata-only."
            )
        }
    }

    // MARK: - Source loading

    /// Reads `SwiftMailIMAPClient.swift` from the repo and strips line
    /// comments so the privacy-claim mentions in doc-comments don't
    /// false-positive. Block comments are not used in the target file
    /// (verified at audit time); if a future commit introduces one,
    /// extend `stripComments(_:)`.
    private static func cleanedSource() throws -> String {
        // `#filePath` resolves to the absolute path of *this* test
        // file at compile time. The source under test sits at a known
        // sibling location in the repo. This is brittle to top-level
        // reorganization but more accurate than a Bundle resource
        // (which can be silently stale).
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // File13Tests/
            .deletingLastPathComponent()  // repo root
        let target = repoRoot
            .appendingPathComponent("Packages/File13Core/Sources/File13Core/SwiftMailIMAPClient.swift")
        let raw = try String(contentsOf: target, encoding: .utf8)
        return Self.stripComments(raw)
    }

    /// Strip `//` line comments. Naive — doesn't handle `//` inside
    /// string literals, but the source file under test doesn't have
    /// any `//` inside strings (and if it does in the future, the
    /// test will at worst false-negative a real issue, never
    /// false-positive a comment).
    private static func stripComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if let range = line.range(of: "//") {
                    return String(line[..<range.lowerBound])
                }
                return String(line)
            }
            .joined(separator: "\n")
    }
}
