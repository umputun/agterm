import Foundation

/// A rebindable, menu-backed built-in action. Each case has a canonical kitty-style raw name (the
/// token the user writes after `map` in `keymap.conf`) and a `defaultChord` — the shortcut the menu
/// ships with today, or `nil` for an action that has no default key.
///
/// The raw names mirror the menu items in `agtermApp`'s `.commands`; `defaultChord` is the single
/// source of truth for those default shortcuts once the menu reads `equivalent(for:)`.
public enum BuiltinAction: String, CaseIterable, Sendable {
    case newWindow = "new_window", renameWindow = "rename_window", deleteWindow = "delete_window"
    case newWorkspace = "new_workspace", renameWorkspace = "rename_workspace", deleteWorkspace = "delete_workspace"
    case newSession = "new_session", openDirectory = "open_directory", renameSession = "rename_session"
    case closeSession = "close_session", clearStatus = "clear_status"
    case increaseFontSize = "increase_font_size", decreaseFontSize = "decrease_font_size", resetFontSize = "reset_font_size"
    case toggleSplit = "toggle_split", toggleScratch = "toggle_scratch", toggleSearch = "toggle_search"
    case focusLeftPane = "focus_left_pane", focusRightPane = "focus_right_pane"
    case previousSession = "previous_session", nextSession = "next_session"
    case previousAttentionSession = "previous_attention_session", nextAttentionSession = "next_attention_session"
    case firstSession = "first_session", lastSession = "last_session"
    case quickTerminal = "quick_terminal", sessionPalette = "session_palette", commandPalette = "command_palette"

    /// The shipped default chord for this action, or `nil` when it has no default key today.
    ///
    /// `nil` covers two groups: the keyless actions (`rename_*`/`delete_*`/`clear_status`/
    /// `first_session`/`last_session`), which gain a key only when the user `map`s one; AND the
    /// arrow-bound actions (`focus_left_pane` ⌘⌥←, `focus_right_pane` ⌘⌥→, `previous_session` ⌥⌘↑,
    /// `next_session` ⌥⌘↓). Arrows are NOT expressible as a parsed `Chord` (`parseKeybind` only accepts
    /// single-char keys or `tab`/`space`/`return`/`delete`), so they cannot round-trip through the
    /// keymap grammar and are not returned here. The menu keeps its hardcoded arrow shortcut as the
    /// fallback when `equivalent(for:)` is nil; the user can still re-`map` these to a parseable chord.
    public var defaultChord: Chord? {
        switch self {
        case .newWindow: return Chord(mods: [.command, .option], key: "n")
        case .newWorkspace: return Chord(mods: [.command, .shift], key: "n")
        case .newSession: return Chord(mods: [.command], key: "n")
        case .openDirectory: return Chord(mods: [.command], key: "o")
        case .closeSession: return Chord(mods: [.command], key: "w")
        case .increaseFontSize: return Chord(mods: [.command], key: "+")
        case .decreaseFontSize: return Chord(mods: [.command], key: "-")
        case .resetFontSize: return Chord(mods: [.command], key: "0")
        case .toggleSplit: return Chord(mods: [.command], key: "d")
        case .toggleScratch: return Chord(mods: [.command], key: "j")
        case .toggleSearch: return Chord(mods: [.command], key: "f")
        case .quickTerminal: return Chord(mods: [.control], key: "`")
        case .sessionPalette: return Chord(mods: [.control], key: "p")
        case .commandPalette: return Chord(mods: [.control, .shift], key: "p")
        case .renameWindow, .deleteWindow, .renameWorkspace, .deleteWorkspace, .renameSession, .clearStatus,
             .firstSession, .lastSession:
            return nil
        case .focusLeftPane, .focusRightPane, .previousSession, .nextSession,
             .previousAttentionSession, .nextAttentionSession:
            // arrow-bound: not expressible as a parsed Chord; the menu keeps its hardcoded arrow key.
            return nil
        }
    }
}
