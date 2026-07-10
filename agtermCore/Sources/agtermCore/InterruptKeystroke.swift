import Foundation

/// Host-free keyboard modifiers, mirroring the subset of `NSEvent.ModifierFlags` the interrupt
/// classifier needs. The app target maps an `NSEvent`'s flags onto this so the classification stays
/// testable without AppKit.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let command = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
}

/// Classifies a keystroke as one that interrupts a working agent — Escape, or a bare Ctrl-C. Both
/// dismiss a pending Claude Code / TUI prompt, which is what clears a stale `active` status glyph. Kept
/// host-free so the full truth table (including the negatives ordinary-key / Cmd-C / Ctrl-Shift-C) is
/// unit-testable; the app target reduces an `NSEvent` to these primitives.
public enum InterruptKeystroke {
    /// The physical C key position (macOS `kVK_ANSI_C`). Layout-independent, unlike the produced character.
    public static let cKeyCode: UInt16 = 8
    /// The Escape key (macOS `kVK_Escape`).
    public static let escapeKeyCode: UInt16 = 53

    /// Whether the keystroke interrupts the agent. `character` is the layout's base letter for the key
    /// (`NSEvent.charactersIgnoringModifiers`); matching it covers Latin layouts including Dvorak, where
    /// the C letter sits at a non-`cKeyCode` physical key. The `cKeyCode` fallback covers non-Latin layouts
    /// (Cyrillic, Greek) where that physical key produces a non-Latin character rather than "c" — the same
    /// layout-independent fallback the built-in `super+key_c` binds use — but only when the produced base
    /// is non-Latin or unavailable: a remapped Latin layout where `cKeyCode` yields a Latin letter other
    /// than "c" (Dvorak's "j") is left alone, so Ctrl-J there is not a false interrupt. Escape interrupts
    /// under any modifiers; Ctrl-C must be bare (control only, no command/option/shift) so a copy-style
    /// chord like Ctrl-Shift-C does not clear a glyph while the agent is still working.
    public static func isInterrupt(keyCode: UInt16, character: String?, modifiers: KeyModifiers) -> Bool {
        if keyCode == escapeKeyCode { return true }
        guard modifiers.contains(.control),
              !modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.shift) else {
            return false
        }
        let base = character?.lowercased()
        if base == "c" { return true }
        return keyCode == cKeyCode && !isLatinLetter(base)
    }

    /// Whether `base` is a single basic-Latin letter (a lowercased a-z). Used to keep the `cKeyCode`
    /// fallback off remapped Latin layouts, where the physical C key produces a Latin letter that isn't "c".
    private static func isLatinLetter(_ base: String?) -> Bool {
        guard let base, base.count == 1, let scalar = base.unicodeScalars.first else { return false }
        return scalar.value >= 0x61 && scalar.value <= 0x7A
    }
}
