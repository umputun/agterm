import Foundation

/// Shapes a failed custom command's diagnostics into the two strings a HUD can paint.
///
/// The runner posts through `ControlServer.openHud` directly, which skips the dispatcher's text validation,
/// so every value here is already stripped of escape sequences and capped at `HudSpec.maxTextLength`.
public enum CommandFailure {
    /// How much stderr is retained. A diagnostic bound, not a measured one: only the last line is shown, and
    /// a command that writes megabytes must not grow the buffer with it.
    public static let tailLimit = 16 * 1024

    /// The last usable line of a captured tail, as HUD detail. Decoding is lenient because a cut tail can
    /// split a scalar. Lines are cleaned BEFORE one is chosen: a command whose last write was a bare colour
    /// reset would otherwise show an empty panel instead of the diagnostic above it. Nil when nothing usable
    /// was written.
    public static func detail(fromTail tail: [UInt8]) -> String? {
        let text = String(decoding: tail, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let clean = cleaned(String(line))
            if !clean.isEmpty { return capped(clean) }
        }
        return nil
    }

    /// The panel's first line: the command's name and why it failed. `reason` is the exit status for a command
    /// that ran and the launch error for one that never started. A long name is truncated to keep the reason,
    /// which is the half that says what happened.
    public static func message(name: String, reason: String) -> String {
        let reason = cleaned(reason)
        let separator = ": "
        let room = HudSpec.maxTextLength - HudLayout.textLength(reason + separator)
        guard room > 0 else { return capped(reason) }
        var name = cleaned(name)
        while HudLayout.textLength(name) > room, !name.isEmpty { name.removeLast() }
        return name.isEmpty ? reason : name + separator + reason
    }

    /// Strips escape sequences and control characters: the HUD helper prints these bytes into a live terminal,
    /// where an unstripped CSI would paint outside the panel. `TerminalText.sanitized` removes the C0 range
    /// but leaves the `[31m` an escape sequence trails behind, so the sequences go first.
    private static func cleaned(_ text: String) -> String {
        TerminalText.sanitized(TerminalText.strippingEscapes(text)).trimmingCharacters(in: .whitespaces)
    }

    /// Truncates to what a HUD accepts, measured in `HudLayout.textLength`'s unit, which counts Unicode
    /// scalars of the precomposed form, so a multi-scalar grapheme costs more than one character.
    private static func capped(_ text: String) -> String {
        var result = text
        while HudLayout.textLength(result) > HudSpec.maxTextLength, !result.isEmpty {
            result.removeLast()
        }
        return result
    }
}
