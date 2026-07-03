// adapted from thdxg/macterm (MIT)

import agtermCore
import AppKit
import GhosttyKit
import os

/// Routes libghostty runtime callbacks to the appropriate terminal views.
///
/// `@unchecked Sendable` and NOT `@MainActor`: the C closures run synchronously
/// off whatever thread libghostty calls from. This router holds no mutable
/// state. Every `@MainActor` touch hops via `DispatchQueue.main.async`, and any
/// C string is copied to a Swift `String` value *before* the hop (the `char*`
/// is only valid for the synchronous callback duration).
final class GhosttyCallbacks: @unchecked Sendable {
    /// Coalesces libghostty wakeups into one queued main-thread tick. `wakeup_cb` fires off-main far faster
    /// than the runloop drains; a single `ghostty_app_tick` drains all pending work. The flag clears before
    /// the tick so a wakeup arriving during it re-schedules instead of being dropped. (Replaces the dropped
    /// 120Hz poll timer — agterm is demand-driven now.)
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
            // the shell or a program set the terminal title (OSC 0/1/2 — often from a PROMPT_COMMAND
            // or a remote host over SSH). recover the surface, copy the title out of the C string,
            // and apply it to the session; displayName prefers it over the cwd basename.
            guard let view = surfaceView(from: target), let ptr = action.action.set_title.title else { return true }
            let title = String(cString: ptr)
            DispatchQueue.main.async { view.applyTitle(title) }
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            // fires when the cell pixel size changes (font-size change via cmd +/-, or DPI
            // change). used only as a trigger: the view reads the live font size and the app
            // persists it.
            guard let view = surfaceView(from: target) else { return true }
            DispatchQueue.main.async { view.reportFontSize() }
            return true
        case GHOSTTY_ACTION_RENDER:
            // libghostty signals this surface has a frame ready to paint. agterm is demand-driven (no poll
            // timer), so service it by drawing now.
            guard let view = surfaceView(from: target) else { return true }
            DispatchQueue.main.async { view.renderNow() }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // a program emitted an OSC 9 / 777 desktop notification. recover the firing surface and
            // copy the title/body out of the C strings synchronously (only valid for this call),
            // then hop to the manager (which resolves the session/pane and applies suppression).
            guard let view = surfaceView(from: target) else { return true }
            let note = action.action.desktop_notification
            let title = note.title.flatMap { String(cString: $0) } ?? ""
            let body = note.body.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async { NotificationManager.shared.notify(surface: view, title: title, body: body) }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // the child process exited. ghostty prints its "Process exited. Press any key to close"
            // fallback unless the host consumes this action. an overlay that should vanish closes
            // immediately and returns true to suppress the prompt; a wait-opt-in overlay (and any other
            // surface) returns false so ghostty shows the prompt and close_surface_cb handles the close.
            guard let view = surfaceView(from: target), view.shouldCloseOnChildExitAction else { return false }
            DispatchQueue.main.async { view.handleProcessExit() }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            // libghostty entered search mode. recover the firing surface and copy the optional needle out
            // of the C string synchronously (only valid for this call), then hop to the view's toggle.
            guard let view = surfaceView(from: target) else { return true }
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) }
            DispatchQueue.main.async { view.onSearchStart?(needle) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            // libghostty exited search mode. recover the surface and hop to the view's clear/refocus.
            guard let view = surfaceView(from: target) else { return true }
            DispatchQueue.main.async { view.onSearchEnd?() }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            // libghostty reported the total match count (ssize_t; negative means no query). map a negative
            // to nil, else carry the count.
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
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            // libghostty asks the host to hide/show the pointer — the mechanism behind
            // mouse-hide-while-typing (the core never touches the cursor itself). setHiddenUntilMouseMoves
            // auto-reveals on the next mouse move, so the hidden case is all that needs acting on; show resets it.
            let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
            DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(hidden) }
            return true
        default:
            return false
        }
    }

    func readClipboard(ud: UnsafeMutableRawPointer?, location _: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        let text = Self.readPasteboardText() ?? ""
        text.withCString { ghostty_surface_complete_clipboard_request(surface(from: ud), $0, state, false) }
        return true
    }

    /// Returns the text for a pasteboard: file/web URLs (Finder copy, or a drag-drop) become shell-escaped
    /// paths, space-joined for multiple, so a path with spaces lands as one argument; otherwise the plain
    /// string verbatim (it may be a command the user means to run, so it is NOT escaped). Shared by the
    /// clipboard paste path (`readPasteboardText`) and the drag-drop handler (`GhosttySurfaceView`), so a
    /// dropped file inserts its path exactly like a pasted one.
    static func pasteboardText(_ pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let parts = urls
                .map { ShellEscape.path($0.isFileURL ? $0.path(percentEncoded: false) : $0.absoluteString) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        return pb.string(forType: .string).flatMap { !$0.isEmpty ? $0 : nil }
    }

    /// Pasted text from the general clipboard (the libghostty paste callback).
    static func readPasteboardText() -> String? { pasteboardText(.general) }

    func confirmReadClipboard(ud: UnsafeMutableRawPointer?, content: UnsafePointer<CChar>?, state: UnsafeMutableRawPointer?,
                              request: ghostty_clipboard_request_e) {
        // only a real OSC 52 read (a program reading the system clipboard into the terminal stream) is
        // gated; a paste keeps auto-approving so ⌘V never prompts.
        guard request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ else {
            guard let content else { return }
            ghostty_surface_complete_clipboard_request(surface(from: ud), content, state, true)
            return
        }
        guard let ud else { return }
        // capture the VIEW, not the raw surface pointer: a session/window/pane close (or `session.close`
        // over the control socket) can free the surface via destroySurface() WHILE the sheet is open. We
        // re-read `view.surface` on the main actor at completion and skip if it's gone (freeing the surface
        // already discarded its pending request, so there is nothing to complete and no loop). The view
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
        // confirm == false: ghostty's clipboard-write policy already allowed it (the `allow` default). This
        // callback runs on the main actor (verified), so write SYNCHRONOUSLY — deferring it lets a following
        // OSC 52 read in the same tick observe the stale clipboard.
        guard confirm else {
            Self.setClipboard(text)
            return
        }
        // confirm == true: clipboard-write = ask. Gate behind the user, scoping coalescing to this surface
        // (the write callback's userdata is the surface, same pointer as the read confirm) so one Allow
        // can't authorize a different surface's queued write.
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
        // The Session retains the view until destroySurface() runs (the only
        // place ghostty_surface_free is called), so takeUnretainedValue() is
        // safe here. Recover the view and hop to the main actor — never close
        // or free synchronously from this callback.
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
