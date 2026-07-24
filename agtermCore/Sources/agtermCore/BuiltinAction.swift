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
    case duplicateSession = "duplicate_session"
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
    /// `nil` covers only the keyless actions (`rename_*`/`delete_*`/`duplicate_session`/`clear_status`/
    /// `first_session`/`last_session`/`select_theme`/`toggle_flagged_view`/`focus_workspace`), which gain
    /// a key only when the user `map`s one. Every action that ships with a key returns it here, including
    /// the six arrow-bound ones — the arrows are part of the chord grammar, so their defaults round-trip
    /// through `keymap.conf` like any other and the menu needs no hardcoded fallback.
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
        case .focusLeftPane: return Chord(mods: [.command, .option], key: "left")
        case .focusRightPane: return Chord(mods: [.command, .option], key: "right")
        case .previousSession: return Chord(mods: [.command, .option], key: "up")
        case .nextSession: return Chord(mods: [.command, .option], key: "down")
        case .previousAttentionSession: return Chord(mods: [.control, .option], key: "up")
        case .nextAttentionSession: return Chord(mods: [.control, .option], key: "down")
        case .renameWindow, .deleteWindow, .renameWorkspace, .deleteWorkspace, .renameSession, .duplicateSession,
             .clearStatus, .firstSession, .lastSession, .selectTheme, .toggleFlaggedView, .focusWorkspace:
            return nil
        }
    }
}
