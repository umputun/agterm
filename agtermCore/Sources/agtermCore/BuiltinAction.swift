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
    case closeSession = "close_session", reopenRecent = "reopen_recent", undoClose = "undo_close", clearStatus = "clear_status"
    case increaseFontSize = "increase_font_size", decreaseFontSize = "decrease_font_size", resetFontSize = "reset_font_size"
    case toggleSplit = "toggle_split", toggleScratch = "toggle_scratch", toggleTerminalZoom = "toggle_terminal_zoom"
    case toggleSearch = "toggle_search"
    case toggleSidebar = "toggle_sidebar", selectTheme = "select_theme", toggleFullscreen = "toggle_fullscreen"
    case toggleFlaggedView = "toggle_flagged_view", toggleFlag = "toggle_flag", focusWorkspace = "focus_workspace"
    case focusLeftPane = "focus_left_pane", focusRightPane = "focus_right_pane"
    case previousSession = "previous_session", nextSession = "next_session"
    case previousAttentionSession = "previous_attention_session", nextAttentionSession = "next_attention_session"
    case firstSession = "first_session", lastSession = "last_session"
    case quickTerminal = "quick_terminal", sessionPalette = "session_palette", commandPalette = "command_palette"
    case customCommandPalette = "custom_command_palette", showAttention = "show_attention"
    case dashboard = "dashboard"

    /// The shipped default chord for this action, or `nil` when it has no default key today.
    ///
    /// `nil` covers two groups: the keyless actions (`rename_*`/`delete_*`/`clear_status`/
    /// `first_session`/`last_session`/`select_theme`/`toggle_flagged_view`/`focus_workspace`),
    /// which gain a key only when the user `map`s one; AND the six
    /// arrow-bound actions (`focus_left_pane` ⌘⌥←, `focus_right_pane` ⌘⌥→, `previous_session` ⌥⌘↑,
    /// `next_session` ⌥⌘↓, `previous_attention_session` ⌃⌥↑, `next_attention_session` ⌃⌥↓). Arrows are
    /// NOT expressible as a parsed `Chord` (`parseKeybind` only accepts single-char keys or
    /// `tab`/`space`/`return`/`delete`), so they cannot round-trip through the keymap grammar and are not
    /// returned here. The menu keeps its hardcoded arrow shortcut as the
    /// fallback when `equivalent(for:)` is nil; the user can still re-`map` these to a parseable chord.
    public var defaultChord: Chord? {
        switch self {
        case .newWindow: return Chord(mods: [.command, .option], key: "n")
        case .newWorkspace: return Chord(mods: [.command, .shift], key: "n")
        case .newSession: return Chord(mods: [.command], key: "n")
        case .openDirectory: return Chord(mods: [.command], key: "o")
        case .closeSession: return Chord(mods: [.command], key: "w")
        case .reopenRecent: return Chord(mods: [.command, .shift], key: "t")
        case .undoClose: return Chord(mods: [.command], key: "z")
        case .increaseFontSize: return Chord(mods: [.command], key: "+")
        case .decreaseFontSize: return Chord(mods: [.command], key: "-")
        case .resetFontSize: return Chord(mods: [.command], key: "0")
        case .toggleSplit: return Chord(mods: [.command], key: "d")
        case .toggleScratch: return Chord(mods: [.command], key: "j")
        case .toggleTerminalZoom: return Chord(mods: [.command, .shift], key: "return")
        case .toggleSearch: return Chord(mods: [.command], key: "f")
        case .toggleSidebar: return Chord(mods: [.command, .control], key: "s")
        case .toggleFullscreen: return Chord(mods: [.command, .control], key: "f")
        case .toggleFlag: return Chord(mods: [.command, .shift], key: "f")
        case .quickTerminal: return Chord(mods: [.control], key: "`")
        case .sessionPalette: return Chord(mods: [.control], key: "p")
        case .commandPalette: return Chord(mods: [.control, .shift], key: "p")
        case .customCommandPalette: return Chord(mods: [.control, .shift], key: "o")
        case .showAttention: return Chord(mods: [.control, .shift], key: "i")
        case .dashboard: return Chord(mods: [.command, .shift], key: "d")
        case .renameWindow, .deleteWindow, .renameWorkspace, .deleteWorkspace, .renameSession, .clearStatus,
             .firstSession, .lastSession, .selectTheme, .toggleFlaggedView, .focusWorkspace:
            return nil
        case .focusLeftPane, .focusRightPane, .previousSession, .nextSession,
             .previousAttentionSession, .nextAttentionSession:
            // arrow-bound: not expressible as a parsed Chord; the menu keeps its hardcoded arrow key.
            return nil
        }
    }

    /// The hardcoded macOS menu glyph for the six arrow-bound actions, whose default shortcut can't
    /// round-trip through `Chord`/`keymap.conf` (so `defaultChord` is nil). `nil` for every other
    /// action — a keyless action stays keyless until the user maps a chord. This is the display
    /// counterpart of the menu's hardcoded arrow `.keyboardShortcut`, used by `Keymap.glyphHint(for:)`
    /// to render an action's current shortcut in the action palette and the toolbar tooltips.
    public var arrowGlyphFallback: String? {
        switch self {
        case .focusLeftPane: return "⌥⌘←"
        case .focusRightPane: return "⌥⌘→"
        case .previousSession: return "⌥⌘↑"
        case .nextSession: return "⌥⌘↓"
        case .previousAttentionSession: return "⌃⌥↑"
        case .nextAttentionSession: return "⌃⌥↓"
        default: return nil
        }
    }
}
