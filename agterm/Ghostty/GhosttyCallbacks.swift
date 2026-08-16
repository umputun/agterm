// adapted from thdxg/macterm (MIT)

import agtermCore
import AppKit
import GhosttyKit
import os

/// Routes libghostty runtime callbacks to the appropriate terminal views.
///
/// `@unchecked Sendable`, NOT `@MainActor`: the C closures run synchronously off whatever thread libghostty
/// calls from, and this router holds no mutable state. Every `@MainActor` touch hops via
/// `DispatchQueue.main.async`, copying any C string first — the `char*` lives only for that callback.
final class GhosttyCallbacks: @unchecked Sendable {
    /// Coalesces libghostty wakeups into one queued main-thread tick: `wakeup_cb` fires off-main far faster
    /// than the runloop drains, and a single `ghostty_app_tick` drains all pending work. The flag clears
    /// before the tick so a wakeup arriving during it re-schedules instead of being dropped.
    private let tickScheduled = OSAllocatedUnfairLock(initialState: false)

    func wakeup() {
        let alreadyScheduled = tickScheduled.withLock { scheduled -> Bool in
            if scheduled { return true }
            scheduled = true
            return false
        }
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [self] in
            tickScheduled.withLock { $0 = false }
            GhosttyApp.shared.tick()
        }
    }

    func action(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_PWD:
            guard let view = surfaceView(from: target), let ptr = action.action.pwd.pwd else { return true }
            let pwd = String(cString: ptr)
            DispatchQueue.main.async { view.applyPwd(pwd) }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            // OSC 0/1/2 title, often from PROMPT_COMMAND or SSH; displayName prefers it to the cwd basename.
            guard let view = surfaceView(from: target), let ptr = action.action.set_title.title else { return true }
            let title = String(cString: ptr)
            DispatchQueue.main.async { view.applyTitle(title) }
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            // the cell pixel size changed (cmd +/- font size, or DPI): a trigger only — the view reads the
            // live font size and the app persists it.
            guard let view = surfaceView(from: target) else { return true }
            DispatchQueue.main.async { view.reportFontSize() }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // an OSC 9 / 777 desktop notification. the manager resolves the session/pane and suppresses.
            guard let view = surfaceView(from: target) else { return true }
            let note = action.action.desktop_notification
            let title = note.title.flatMap { String(cString: $0) } ?? ""
            let body = note.body.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async { NotificationManager.shared.notify(surface: view, title: title, body: body) }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // ghostty prints its "Process exited. Press any key to close" fallback unless the host consumes
            // this action: an overlay that should vanish returns true to suppress the prompt; a wait-opt-in
            // overlay (and every other surface) returns false, so the prompt shows and close_surface_cb closes.
            guard let view = surfaceView(from: target), view.shouldCloseOnChildExitAction else { return false }
            DispatchQueue.main.async { view.handleProcessExit() }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            // libghostty entered search mode; the needle it reports back is optional.
            guard let view = surfaceView(from: target) else { return true }
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) }
            DispatchQueue.main.async { view.onSearchStart?(needle) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            // libghostty exited search mode; the view clears the fields and refocuses the terminal.
            guard let view = surfaceView(from: target) else { return true }
            DispatchQueue.main.async { view.onSearchEnd?() }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            // the total match count (ssize_t; negative means no query) — a negative maps to nil.
            guard let view = surfaceView(from: target) else { return true }
            let raw = action.action.search_total.total
            let value = raw < 0 ? nil : Int(raw)
            DispatchQueue.main.async { view.onSearchTotal?(value) }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            // libghostty reported the 1-based index of the selected match (ssize_t; negative means none).
            guard let view = surfaceView(from: target) else { return true }
            let raw = action.action.search_selected.selected
            let value = raw < 0 ? nil : Int(raw)
            DispatchQueue.main.async { view.onSearchSelected?(value) }
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // ghostty replies to `ghostty_app_update_config` with the config it APPLIED: for the app target
            // the dual `theme = light:,dark:` resolved to the current side, which the host config can't show
            // (`ghostty_config_get` reads the light default). Clone synchronously (the core frees its copy on
            // return) and stash for `reloadConfig`; app target only, so per-surface overlays can't repaint.
            guard target.tag == GHOSTTY_TARGET_APP,
                  let cfg = action.action.config_change.config,
                  let clone = ghostty_config_clone(cfg) else { return true }
            stashDerivedAppConfig(clone)
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            // the host hides/shows the pointer — the core never touches the cursor (mouse-hide-while-typing).
            // setHiddenUntilMouseMoves auto-reveals on the next mouse move, so show just resets it.
            let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
            DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(hidden) }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            // pointing hand over a detected link / OSC-8 hyperlink, I-beam over the grid, resize/crosshair.
            guard let view = surfaceView(from: target) else { return true }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { view.applyMouseShape(shape) }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            // copy the URL out of the LENGTH-DELIMITED buffer synchronously (valid only for this call):
            // `open_url.url` is a Zig slice, NOT NUL-terminated, so honor `.len` — `String(cString:)` would
            // over-read into adjacent hyperlink storage. Then open it scheme-validated on the main actor.
            let openURL = action.action.open_url
            guard let view = surfaceView(from: target), let ptr = openURL.url else { return true }
            let link = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(openURL.len)), as: UTF8.self)
            DispatchQueue.main.async { view.openLink(link) }
            return true
        case GHOSTTY_ACTION_COLOR_CHANGE:
            // a dynamic color set or RESET via OSC 10/11/12 (fg/bg/cursor) or their 110/111/112 resets,
            // already applied by libghostty; but under translucency every surface renders background-opacity
            // 0 (the window backing supplies the tint), so an OSC 11 BACKGROUND is invisible until THIS
            // surface's opacity is lifted — fg/cursor render regardless. The main actor routes set-vs-reset
            // and dedupes per prompt.
            guard let view = surfaceView(from: target) else { return true }
            let change = action.action.color_change
            guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return true }
            let hex = String(format: "#%02x%02x%02x", Int(change.r), Int(change.g), Int(change.b))
            DispatchQueue.main.async { view.handleOSCBackgroundChange(hex) }
            return true
        default:
            return false
        }
    }

    /// The app-target CONFIG_CHANGE clone awaiting pickup, as a bit pattern (raw pointers aren't Sendable, so
    /// the lock holds `UInt`; 0 = none). Written during `ghostty_app_update_config`, taken by `reloadConfig`.
    private let pendingAppConfig = OSAllocatedUnfairLock<UInt>(initialState: 0)

    /// Stash the cloned app-level derived config, freeing any stale one left from a take-less update
    /// (e.g. an update_config outside `reloadConfig`) so the box never leaks more than one clone.
    private func stashDerivedAppConfig(_ config: ghostty_config_t) {
        let raw = UInt(bitPattern: config)
        let stale = pendingAppConfig.withLock { pending -> UInt in
            let previous = pending
            pending = raw
            return previous
        }
        if let staleConfig = ghostty_config_t(bitPattern: stale) { ghostty_config_free(staleConfig) }
    }

    /// Hand the pending derived config (if any) to the caller, which owns freeing it.
    func takeDerivedAppConfig() -> ghostty_config_t? {
        let raw = pendingAppConfig.withLock { pending -> UInt in
            let current = pending
            pending = 0
            return current
        }
        return ghostty_config_t(bitPattern: raw)
    }

    func readClipboard(ud: UnsafeMutableRawPointer?, location _: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        let text = Self.readPasteboardText() ?? ""
        text.withCString { ghostty_surface_complete_clipboard_request(surface(from: ud), $0, state, false) }
        return true
    }

    /// The text for a pasteboard: file/web URLs (a Finder copy or a drag-drop) become shell-escaped paths,
    /// space-joined; a plain string comes back verbatim, NOT escaped, since it may be a command the user
    /// means to run. Shared by the clipboard paste path and the drag-drop handler, so a drop inserts as a paste.
    static func pasteboardText(_ pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let parts = urls.map(urlText).filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        return pb.string(forType: .string).flatMap { !$0.isEmpty ? $0 : nil }
    }

    /// The text one pasteboard URL contributes: a shell-escaped path for a file URL (so a path with spaces
    /// lands as one argument), else the escaped absolute string. The SINGLE definition shared by the reader
    /// and the menu gate, so they cannot drift — untestable in XCUITest (see the Control API rule).
    private static func urlText(_ url: URL) -> String {
        ShellEscape.path(url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString)
    }

    /// Pasted text from the general clipboard (the libghostty paste callback).
    static func readPasteboardText() -> String? { pasteboardText(.general) }

    /// Whether `pasteboardText` would return something, without building the joined result: menu validation
    /// runs on every Edit-menu open and ⌘V key-equivalent lookup, so it short-circuits on the first usable URL.
    ///
    /// It must agree with `pasteboardText` BOTH ways, which a bare `canReadObject([NSURL])` TYPE check does
    /// not: a pasteboard merely DECLARING `public.file-url` with no usable value would enable Paste while
    /// the reader returns nil (verified with a named pasteboard). Hence the same `urlText` + non-empty filter.
    static func hasPasteboardText(_ pb: NSPasteboard = .general) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.contains(where: { !urlText($0).isEmpty }) {
            return true
        }
        return pb.string(forType: .string).map { !$0.isEmpty } ?? false
    }

    func confirmReadClipboard(ud: UnsafeMutableRawPointer?, content: UnsafePointer<CChar>?, state: UnsafeMutableRawPointer?,
                              request: ghostty_clipboard_request_e) {
        // only a real OSC 52 read (a program reading the system clipboard into the terminal stream) is
        // gated; a paste auto-approves so ⌘V never prompts.
        guard request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ else {
            guard let content else { return }
            ghostty_surface_complete_clipboard_request(surface(from: ud), content, state, true)
            return
        }
        guard let ud else { return }
        // capture the VIEW, not the raw surface pointer: a close (GUI or `session.close`) can free the surface
        // via destroySurface() WHILE the sheet is open. Re-read `view.surface` at completion and skip if it's
        // gone — freeing already discarded the request, so there is nothing to complete and no loop. The view
        // also scopes the prompt's coalescing to this surface.
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(ud).takeUnretainedValue()
        let text = content.map { String(cString: $0) } ?? "" // copy now; nil content reads as empty
        nonisolated(unsafe) let requestState = state
        DispatchQueue.main.async {
            ClipboardPromptController.shared.request(.read, requester: view) { allowed in
                guard let surface = view.surface else { return }
                // deny by delivering an EMPTY clipboard with confirmed = true: completing with confirmed =
                // false leaves the request unconfirmed and libghostty re-asks, looping the dialog.
                let delivered = allowed ? text : ""
                delivered.withCString { ghostty_surface_complete_clipboard_request(surface, $0, requestState, true) }
            }
        }
    }

    func writeClipboard(ud: UnsafeMutableRawPointer?, content: UnsafePointer<ghostty_clipboard_content_s>?, len: UInt, confirm: Bool) {
        guard let content, len > 0 else { return }
        var text: String?
        for item in UnsafeBufferPointer(start: content, count: Int(len)) {
            guard let data = item.data, let mime = item.mime, String(cString: mime).hasPrefix("text/plain") else { continue }
            text = String(cString: data)
            break
        }
        guard let text else { return }
        // confirm == false: ghostty's `allow` clipboard-write policy already permitted it. This callback runs
        // on the main actor (verified), so write SYNCHRONOUSLY — a same-tick OSC 52 read would see stale data.
        guard confirm else {
            Self.setClipboard(text)
            return
        }
        // confirm == true: clipboard-write = ask. Gate behind the user, scoping coalescing to this surface
        // (userdata is the surface, as in the read confirm) so one Allow can't authorize another's write.
        guard let ud else { return }
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(ud).takeUnretainedValue()
        DispatchQueue.main.async {
            ClipboardPromptController.shared.request(.write, requester: view) { allowed in
                if allowed { Self.setClipboard(text) }
            }
        }
    }

    private static func setClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func closeSurface(ud: UnsafeMutableRawPointer?) {
        guard let ud else { return }
        // the Session retains the view until destroySurface() runs (the only place ghostty_surface_free is
        // called), so takeUnretainedValue() is safe. never close or free synchronously from this callback.
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(ud).takeUnretainedValue()
        DispatchQueue.main.async { view.handleProcessExit() }
    }

    private func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let ud = ghostty_surface_userdata(surface)
        else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    private func surface(from ud: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        guard let ud else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(ud).takeUnretainedValue().surface
    }
}
