import Foundation

/// Helpers for cleaning up server-supplied or user-supplied strings before
/// they're rendered to the UI or fed to AI prompts.
///
/// Two specific risks these defend against:
///
/// 1. **BiDi / RTL-override spoofing.** A hostile sender sets their display
///    name to contain U+202E (Right-to-Left Override) so a name like
///    `paypal.com<U+202E>moc.evil` renders as `paypal.commolla.com`. The
///    user's whole defense against phishing is the visual identity of the
///    sender row — trusting unsanitized BiDi controls there is a known
///    homograph attack vector.
///
/// 2. **Control-character poisoning of logs and the UI.** A buggy or
///    hostile IMAP server can return error strings containing ANSI escapes,
///    NUL bytes, or megabytes of padding. When those land in `lastError`
///    or the CLI's stderr writer, they corrupt terminal output and bloat
///    logs.
public enum DisplaySanitizer {
    /// Unicode formatting characters that change visual direction without
    /// occupying space. Removed wherever we render a sender-controlled
    /// string. Kept on the *stored* string (so address matching still
    /// works against what the server actually sent); applied at the
    /// rendering boundary.
    private static let bidiControls: Set<UInt32> = [
        0x200E, // LEFT-TO-RIGHT MARK
        0x200F, // RIGHT-TO-LEFT MARK
        0x202A, // LEFT-TO-RIGHT EMBEDDING
        0x202B, // RIGHT-TO-LEFT EMBEDDING
        0x202C, // POP DIRECTIONAL FORMATTING
        0x202D, // LEFT-TO-RIGHT OVERRIDE
        0x202E, // RIGHT-TO-LEFT OVERRIDE
        0x2066, // LEFT-TO-RIGHT ISOLATE
        0x2067, // RIGHT-TO-LEFT ISOLATE
        0x2068, // FIRST STRONG ISOLATE
        0x2069, // POP DIRECTIONAL ISOLATE
        0x061C  // ARABIC LETTER MARK
    ]

    /// Strip BiDi formatting controls and replace C0 control bytes (other
    /// than newline/tab) with a single space. Suitable for any string
    /// that's about to be shown to the user as identifying text — sender
    /// display name, subject preview, server error reason.
    public static func sanitizeForDisplay(_ input: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(input.unicodeScalars.count)
        for scalar in input.unicodeScalars {
            let v = scalar.value
            if bidiControls.contains(v) { continue }
            // Replace C0 controls (excluding tab 0x09, LF 0x0A, CR 0x0D for
            // multi-line subjects/errors that we want to preserve structure
            // of) with a space so we don't silently swallow tokens.
            if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D {
                out.append(UnicodeScalar(0x20))
                continue
            }
            if v == 0x7F { // DEL
                out.append(UnicodeScalar(0x20))
                continue
            }
            out.append(scalar)
        }
        return String(out)
    }

    /// Cap a server-supplied error / diagnostic string at `maxLength`
    /// characters and replace C0 controls (including newlines) with a
    /// single space. Use for strings destined for `lastError`, log lines,
    /// or any single-line UI surface where a megabyte-long error or an
    /// embedded ANSI escape would be a problem.
    public static func sanitizeForLog(_ input: String, maxLength: Int = 256) -> String {
        var out = String.UnicodeScalarView()
        var taken = 0
        for scalar in input.unicodeScalars {
            if taken >= maxLength { break }
            let v = scalar.value
            if v < 0x20 || v == 0x7F {
                out.append(UnicodeScalar(0x20))
            } else {
                out.append(scalar)
            }
            taken += 1
        }
        var result = String(out)
        if input.unicodeScalars.count > maxLength {
            result.append("…")
        }
        return result
    }
}

public extension String {
    /// Convenience that routes through `DisplaySanitizer.sanitizeForDisplay`.
    var sanitizedForDisplay: String {
        DisplaySanitizer.sanitizeForDisplay(self)
    }
}
