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

    /// strippingEscapes drops an ESC and whatever sequence follows it: CSI (`ESC [` … final byte `@`-`~`), OSC (`ESC ]` … BEL
    /// or ST), DCS/SOS/PM/APC strings (… ST), intermediate forms (`ESC (` … final byte), and the two-character forms. A trailing partial sequence is dropped with it, since a cut tail
    /// can end mid-escape.
    static func strippingEscapes(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value == 0x1B }) else { return text }
        var result = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar.value == 0x1B else {
                result.append(scalar)
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { break }
            let kind = scalars[index]
            index += 1
            if kind.value == 0x5B { // CSI: parameters, then one final byte
                while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) { index += 1 }
                index += 1
            } else if kind.value == 0x5D { // OSC: runs to BEL or ESC \
                while index < scalars.count, scalars[index].value != 0x07, scalars[index].value != 0x1B {
                    index += 1
                }
                if index < scalars.count, scalars[index].value == 0x1B { index += 1 }
                index += 1
            } else if [0x50, 0x58, 0x5E, 0x5F].contains(kind.value) {
                // DCS, SOS, PM, APC: opaque up to ESC \ only; a tmux passthrough doubles every ESC inside it
                while index < scalars.count {
                    let next = index + 1 < scalars.count ? scalars[index + 1].value : 0
                    if scalars[index].value == 0x1B, next == 0x5C { break }
                    index += scalars[index].value == 0x1B && next == 0x1B ? 2 : 1
                }
                index += 2
            } else if (0x20...0x2F).contains(kind.value) { // intermediates, then one final byte: `tput sgr0` emits ESC ( B
                while index < scalars.count, (0x20...0x2F).contains(scalars[index].value) { index += 1 }
                index += 1
            }
        }
        return String(result)
    }
}

extension String {
    /// Trimmed of surrounding whitespace and newlines, nil if empty — the one normalizer for the
    /// rename/displayName "blank after trim" rule.
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
