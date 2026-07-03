import Foundation

/// TerminalText sanitizes strings a terminal program reports over OSC sequences — the window title
/// (OSC 0/1/2) and the working directory (OSC 7) — before agterm stores them on a `Session`. Those
/// values are attacker-influenceable (a remote SSH host or any program's output sets them) and flow,
/// unquoted, into a `/bin/sh -c` line via the `{AGT_SESSION_NAME}`/`{AGT_SESSION_PWD}` custom-command
/// tokens, so a control character — a newline above all, which `sh -c` reads as a command separator —
/// must never survive into the stored value. A title or a directory path never legitimately contains
/// a control character, so stripping the whole C0 range is lossless for real input.
///
/// This does NOT make raw `{AGT_X}` interpolation safe against visible shell metacharacters (`;`,
/// `$()`, backticks); those are legitimate in titles/paths and are the caller's concern via the
/// shell-quoted `$AGT_X` environment form. This closes only the invisible control-character vector.
public enum TerminalText {
    /// Strip the C0 control range (U+0000–U+001F, including tab/newline/carriage-return) and DEL
    /// (U+007F) from an OSC-reported title or working directory; every other scalar is preserved.
    /// The common case (no control characters, which is every real title/path) returns the input
    /// unchanged with no allocation, since these callbacks run on every OSC redraw.
    public static func sanitized(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return value }
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars where scalar.value >= 0x20 && scalar.value != 0x7F {
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
