// adapted from thdxg/macterm (MIT)

import agtermCore
import AppKit
import GhosttyKit

/// `GhosttySurfaceView` surface I/O and binding-action operations: type/paste into the pty, read the
/// selection / buffer / foreground pid, drive libghostty binding actions (font size, search), read the live
/// font size. Methods only (no stored properties), split out to keep `GhosttySurfaceView.swift` under size.
extension GhosttySurfaceView {
    /// Types `text` into this surface's pty (the control channel's `session.type`) as literal keystrokes,
    /// the keyboard's own path (`ghostty_surface_key` with `.text` set — see `insertText`), NOT
    /// `ghostty_surface_text`, whose bracketed-paste wrapping both suppresses command execution and leaks
    /// `\e[200~`/`\e[201~` markers when fired rapidly. Printable runs go as key-with-text events; every line
    /// ending (`\n`, `\r`, `\r\n`) is a real Return keypress, so a trailing newline submits and a multi-line
    /// payload runs line by line. Bytes are copied via `withCString`, so no buffer outlives the call. Returns
    /// `false` (a no-op) when the surface is not created yet (a never-shown / just-shown session), so a caller
    /// injecting into a pane with no realize/select path (`right`/`scratch`) reports `session not realized`
    /// instead of a false ok; the main-pane path realizes it first via select+poll.
    @discardableResult
    func inject(text: String) -> Bool {
        guard let surface else { return false }
        for segment in KeystrokeSegments.split(text) {
            switch segment {
            case let .text(segment):
                segment.withCString { ptr in
                    var ke = ghostty_input_key_s()
                    ke.action = GHOSTTY_ACTION_PRESS
                    ke.text = ptr
                    _ = ghostty_surface_key(surface, ke)
                }
            case .returnKey:
                sendReturn(to: surface)
            }
        }
        return true
    }

    /// Inserts `text` as a bracketed paste — the drag-drop path. Unlike `inject(text:)`, which types
    /// keystrokes and turns each `\n`/`\r` into a Return, this routes through `ghostty_surface_text`, whose
    /// bracketed-paste wrapping makes the running program treat the whole payload as literal text, so a
    /// dropped multi-line selection lands at the cursor without auto-submitting — like ⌘V, and with ⌘V's
    /// caveat that a raw prompt with mode 2004 off still submits. A drop must behave like a paste, not like
    /// typing; `session.type` keeps `inject` because automation DOES want newline→Return. Bytes are copied
    /// synchronously, so nothing outlives the call. A no-op when the surface is not created yet.
    func insertPasted(text: String) {
        guard let surface, !text.isEmpty else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }

    /// This surface's current selection text (the control channel's `session.copy`), or nil with no selection
    /// or an uncreated surface. Selection is surface terminal state, independent of focus, so any realized
    /// session can be read. The libghostty buffer is copied into a Swift `String` and freed via
    /// `ghostty_surface_free_text` before returning.
    func readSelection() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        guard let ptr = t.text, t.text_len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(t.text_len)), as: UTF8.self)
    }

    /// This surface's terminal buffer as plain text (the control channel's `session.text`). nil ONLY on a
    /// FAILED read (no surface yet, or `ghostty_surface_read_text` fails), so a caller can tell that from a
    /// genuinely blank screen, which reads as an empty string. The region is the visible screen by default,
    /// the whole screen plus scrollback when `all` is true or `lines` is set; `lines` keeps the last N
    /// CONTENT lines (trailing blank grid rows trimmed). Like `readSelection` it ignores focus and
    /// copies-then-frees the libghostty buffer. UTF-8 only — `ghostty_surface_read_text` carries no per-cell
    /// color or SGR. Covered by the `session.text` XCUITest e2e, since the call needs a live surface.
    func readScreenText(all: Bool, lines: Int?) -> String? {
        guard let surface else { return nil }
        // A zero-init ghostty_point_s is GHOSTTY_POINT_ACTIVE / GHOSTTY_POINT_COORD_EXACT (both enum 0),
        // not viewport/top-left, so set tag and coord on both endpoints.
        let tag = (all || lines != nil) ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        var sel = ghostty_selection_s()
        sel.top_left = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        sel.bottom_right = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        sel.rectangle = false
        var t = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        // A successful read of a blank screen yields no bytes — that is an empty string, NOT a failure
        // (nil is reserved for the guards above so `readText` can report a real read failure as an error).
        guard let ptr = t.text, t.text_len > 0 else { return "" }
        let full = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(t.text_len)), as: UTF8.self)
        guard let n = lines, n > 0 else { return full }
        // Drop trailing blank/whitespace-only rows (the unused grid below a short screen) so `--lines N`
        // returns the last N CONTENT lines instead of blank padding, then keep the last N.
        var rows = full.components(separatedBy: "\n")
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeLast()
        }
        return rows.suffix(n).joined(separator: "\n")
    }

    /// This surface's foreground process pid (libghostty `ghostty_surface_foreground_pid`), or nil when
    /// the surface has not been created or the call returns 0. Read at quit by the restore-running-command
    /// capture (`ForegroundProcess.command(for:shellBasename:)`); not focus-dependent, like `readSelection`.
    func foregroundPid() -> pid_t? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        return pid > 0 ? pid_t(pid) : nil
    }

    /// Synthesizes a Return keypress (press + release) on `surface` via the same key path the keyboard
    /// uses, so the shell treats it as Enter. Keycode 36 is the macOS virtual keycode for Return.
    private func sendReturn(to surface: ghostty_surface_t) {
        var ke = ghostty_input_key_s()
        ke.keycode = 36
        ke.mods = GHOSTTY_MODS_NONE
        ke.consumed_mods = GHOSTTY_MODS_NONE
        ke.composing = false
        ke.text = nil
        ke.unshifted_codepoint = 0
        ke.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, ke)
        ke.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, ke)
    }

    /// Triggers a libghostty keybind action on this surface (e.g. `increase_font_size:1`,
    /// `decrease_font_size:1`, `reset_font_size`), so a menu item drives the same behavior as the built-in
    /// keybind; a font change rides the usual CELL_SIZE → persist path. Returns whether it ran — `false`
    /// when the libghostty surface isn't realized yet (the view exists, its inner `surface` is nil), so a
    /// control caller reports `session not realized` instead of a false ok. `@discardableResult` for the
    /// GUI/menu callers.
    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        return true
    }

    /// The direction `navigateSearch` steps the selection. The pure enum (with its libghostty mapping) is
    /// host-free in `agtermCore.SearchDirection`; this alias keeps the existing call sites unchanged.
    typealias SearchDirection = agtermCore.SearchDirection

    /// Enters search mode on this surface (the `start_search` binding action). libghostty replies with a
    /// START_SEARCH action carrying the current needle; sending it again while search is active closes it.
    func startSearch() { performBindingAction("start_search") }

    /// Sets the search query (the `search:<needle>` binding action). libghostty replies with SEARCH_TOTAL
    /// and SEARCH_SELECTED actions for the new match set.
    func sendSearchQuery(_ needle: String) { performBindingAction("search:\(needle)") }

    /// Steps the selection one match. The agterm direction is INVERTED to libghostty's `navigate_search`
    /// string by `SearchDirection.ghosttyAction` (see `agtermCore.SearchDirection`), so the DOWN chevron /
    /// Enter / `--next` move visually down and the UP chevron / Shift-Enter / `--prev` move visually up.
    func navigateSearch(_ direction: SearchDirection) {
        performBindingAction(direction.ghosttyAction)
    }

    /// Exits search mode on this surface (the `end_search` binding action). libghostty replies with an
    /// END_SEARCH action.
    func endSearch() { performBindingAction("end_search") }

    /// The surface's live font size in points (post cmd +/-), read from `inherited_config`; nil when the
    /// libghostty surface isn't realized or hasn't resolved a size. The read side of `font.*` — the control
    /// `tree` reads it per pane, since the split/scratch panes' sizes are otherwise unobservable (live-only).
    func currentFontSize() -> Double? {
        guard let surface else { return nil }
        let size = Double(ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_WINDOW).font_size)
        return size > 0 ? size : nil
    }
}
