import Foundation
import Testing
@testable import file13

/// Unit tests for `TTYInput.sanitize(pipedBytes:)` — the pure portion of
/// the secret-input helper that handles bytes coming in on a non-TTY
/// stdin (`pbpaste | file13 providers set-key …`, heredocs, etc.).
///
/// The TTY path itself (`tcgetattr` / `tcsetattr` echo suppression) is
/// not unit-tested here — it needs a real pty and the failure modes
/// (echo not restored on early return) are covered by the `defer`
/// pattern in `TTYInput.readFromTTY`.
@Suite struct TTYInputTests {
    @Test func emptyInputProducesEmptyString() {
        #expect(TTYInput.sanitize(pipedBytes: Data()) == "")
    }

    @Test func plainAsciiPasses() {
        #expect(TTYInput.sanitize(pipedBytes: Data("hunter2".utf8)) == "hunter2")
    }

    @Test func trailingNewlineIsStripped() {
        // Matches the typical `printf 'pw\n' | file13 …` case.
        #expect(TTYInput.sanitize(pipedBytes: Data("hunter2\n".utf8)) == "hunter2")
    }

    @Test func leadingAndTrailingWhitespaceIsStripped() {
        // Heredocs and stray pbpaste sometimes carry edge whitespace.
        #expect(TTYInput.sanitize(pipedBytes: Data("  hunter2  ".utf8)) == "hunter2")
    }

    @Test func interiorWhitespaceIsPreserved() {
        // Passphrases legitimately contain spaces — only trim the edges.
        #expect(TTYInput.sanitize(pipedBytes: Data("correct horse battery staple\n".utf8)) ==
            "correct horse battery staple")
    }

    @Test func onlyWhitespaceCollapsesToEmpty() {
        #expect(TTYInput.sanitize(pipedBytes: Data("\n\n  \t\n".utf8)) == "")
    }

    @Test func utf8MultibyteCharsArePreserved() {
        let secret = "pässwörd-üñîçødé"
        #expect(TTYInput.sanitize(pipedBytes: Data(secret.utf8)) == secret)
    }

    @Test func nonUtf8BytesProduceEmptyString() {
        // Stray Latin-1 bytes (0xFF 0xFE) aren't valid UTF-8 — bail safely
        // rather than substituting replacement characters into a secret.
        let bytes = Data([0xFF, 0xFE, 0x00, 0x41])
        #expect(TTYInput.sanitize(pipedBytes: bytes) == "")
    }

    @Test func crlfLineEndingsAreStripped() {
        // Windows-style line endings can arrive via pasted secrets.
        #expect(TTYInput.sanitize(pipedBytes: Data("hunter2\r\n".utf8)) == "hunter2")
    }
}
