import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared TTY secret-input helper for `accounts add` and `providers set-key`.
///
/// Reads a secret from stdin without echoing it back. On a TTY we suppress
/// echo via `tcgetattr` / `tcsetattr`; on a pipe / heredoc we just consume
/// the bytes. `getpass(3)` was deprecated by Apple in 10.15 — its man page
/// directs callers to disable ECHO themselves via termios, which is what
/// `readFromTTY` does (and which restores the prior mode in a `defer` so
/// an early throw never leaves the terminal with echo off).
enum TTYInput {
    /// Read a secret from stdin. Writes the prompt to stderr on a TTY so
    /// it never appears in stdout pipes. Returns an empty string when the
    /// caller sends EOF before any bytes.
    static func readSecret(prompt: String) -> String {
        let fd = fileno(stdin)
        if isatty(fd) != 0 {
            return readFromTTY(fd: fd, prompt: prompt)
        }
        return sanitize(pipedBytes: FileHandle.standardInput.availableData)
    }

    /// Pure bytes → string conversion used on the non-TTY path. Extracted
    /// so the trimming + UTF-8 fallback semantics are covered by unit
    /// tests without needing a fake stdin. Returns empty string on
    /// non-UTF-8 data — secrets are expected to be ASCII / UTF-8 and any
    /// upstream encoding mismatch is a user error.
    static func sanitize(pipedBytes: Data) -> String {
        guard let raw = String(data: pipedBytes, encoding: .utf8) else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readFromTTY(fd: Int32, prompt: String) -> String {
        FileHandle.standardError.write(Data(prompt.utf8))

        var saved = termios()
        guard tcgetattr(fd, &saved) == 0 else {
            // Couldn't query the tty mode — fall back to a plain readLine.
            // Less safe (the secret will echo) but better than failing the
            // operation outright.
            FileHandle.standardError.write(Data("\n".utf8))
            return readLine(strippingNewline: true) ?? ""
        }

        var modified = saved
        // ECHO is the cause of visible characters; ECHONL keeps the
        // newline visible so the user sees their <return> register.
        modified.c_lflag &= ~tcflag_t(ECHO)
        modified.c_lflag |= tcflag_t(ECHONL)

        guard tcsetattr(fd, TCSAFLUSH, &modified) == 0 else {
            FileHandle.standardError.write(Data("\n".utf8))
            return readLine(strippingNewline: true) ?? ""
        }
        defer {
            // Always restore the original mode, even on early return.
            _ = tcsetattr(fd, TCSAFLUSH, &saved)
        }
        return readLine(strippingNewline: true) ?? ""
    }
}
