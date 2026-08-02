/// TerminalText sanitizes every value that reaches a `{AGT_X}` custom-command token: the title (OSC 0/1/2)
/// and working directory (OSC 7) a terminal program reports, and the session, workspace and window names
/// and the `session.new --cwd` a caller supplies over the control socket or the GUI. Those values are
/// attacker-influenceable (a remote SSH host or any program's output sets the OSC pair; automation sets a
/// name from a branch title or a filename) and flow unquoted into a `/bin/sh -c` line via
/// `{AGT_SESSION_NAME}`, `{AGT_SESSION_PWD}`, `{AGT_WORKSPACE_NAME}` and `{AGT_WINDOW_NAME}`, so a control
/// character — above all a newline, which `sh -c` reads as a command separator — must never survive into
/// the stored value. A name or directory path never legitimately contains one, so stripping the whole C0
/// range is lossless for real input.
///
/// This closes only the invisible control-character vector: raw `{AGT_X}` interpolation stays unsafe
/// against visible shell metacharacters (`;`, `$()`, backticks), which are legitimate in titles/paths and
/// are the caller's concern via the shell-quoted `$AGT_X` environment form.
public enum TerminalText {
    /// Strip the C0 control range (U+0000–U+001F, including tab/newline/carriage-return) and DEL (U+007F)
    /// from a title, path or name; every other scalar is preserved. The common case (no control characters,
    /// i.e. every real title, path or name) returns the input unchanged with no allocation, since the OSC
    /// callbacks run on every redraw.
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
