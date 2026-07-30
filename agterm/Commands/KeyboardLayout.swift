import Carbon
import Foundation

/// The active keyboard layout's ability to type ASCII — the signal that decides how a key press resolves
/// to a keymap chord (`chordKey(forKeyCode:produced:layoutIsASCIICapable:)`).
///
/// A Latin layout (US, Dvorak, Colemak, US-International, French, German) reports true and binds by the
/// character it types. A non-Latin one (Russian, Greek, Hebrew, Arabic, Thai) reports false and binds by
/// physical position, since nothing it types can spell a chord.
///
/// This covers the two MONITOR-driven paths only — custom commands and `undo_close`. Every other built-in
/// rides an AppKit menu key equivalent, which resolves on its own; ⌘N and ⌘W were observed firing on a
/// Russian layout, but how AppKit reaches them was not isolated here, and `.claude/rules/control-api.md`
/// records a conflicting account for ⌘C/⌘V/⌘A. Do not cite this type as evidence either way.
enum KeyboardLayout {
    /// Whether the active keyboard layout can type ASCII. Read fresh on every key press — the query costs
    /// well under a microsecond, so it needs no cache and no input-source-changed observer and can never go
    /// stale mid-session. An unresolvable layout falls back to true (bind by produced character), which is
    /// how every Latin layout already behaves.
    static var isASCIICapable: Bool {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
        else { return true }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }
}
