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
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // ghostty replies to `ghostty_app_update_config` with the config it actually APPLIED — for
            // the app target that is the dual `theme = light:,dark:` conditional resolved to the current
            // appearance side, which the host-loaded config can never show (`ghostty_config_get` on it
            // always reads the default = light side). Clone it synchronously (the core frees its derived
            // copy right after this callback returns) and stash it for `GhosttyApp.reloadConfig` to read
            // the chrome colors from. Surface-targeted changes (per-surface watermark overlays) must not
            // repaint app-level chrome, so only the app target is stashed.
            guard target.tag == GHOSTTY_TARGET_APP,
                  let cfg = action.action.config_change.config,
                  let clone = ghostty_config_clone(cfg) else { return true }
            stashDerivedAppConfig(clone)
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            // libghostty asks the host to hide/show the pointer — the mechanism behind
            // mouse-hide-while-typing (the core never touches the cursor itself). setHiddenUntilMouseMoves
            // auto-reveals on the next mouse move, so the hidden case is all that needs acting on; show resets it.
            let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
            DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(hidden) }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            // libghostty requests a mouse cursor shape for this surface — the pointing hand over a detected
            // link / OSC-8 hyperlink, the I-beam over the grid, resize/crosshair in the matching modes.
            // recover the surface and apply the mapped NSCursor.
            guard let view = surfaceView(from: target) else { return true }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { view.applyMouseShape(shape) }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            // a click opened a detected link / OSC-8 hyperlink. copy the URL out of the LENGTH-DELIMITED C
            // buffer synchronously (only valid for this call; `open_url.url` is NOT NUL-terminated — it is a
            // Zig slice, so honor `.len` instead of `String(cString:)`, which would over-read into adjacent
            // hyperlink storage), then open it scheme-validated on the main actor.
            let openURL = action.action.open_url
            guard let view = surfaceView(from: target), let ptr = openURL.url else { return true }
            let link = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(openURL.len)), as: UTF8.self)
            DispatchQueue.main.async { view.openLink(link) }
            return true
        default:
            return false
        }
    }

    /// The app-target CONFIG_CHANGE clone awaiting pickup, as a bit pattern (raw pointers aren't
    /// Sendable, so the lock holds `UInt`; 0 = none). Written synchronously by the CONFIG_CHANGE arm
    /// during `ghostty_app_update_config`, taken right after by `GhosttyApp.reloadConfig`.
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

    /// Returns the text for a pasteboard: file/web URLs (Finder copy, or a drag-drop) become shell-escaped
    /// paths, space-joined for multiple, so a path with spaces lands as one argument; otherwise the plain
    /// string verbatim (it may be a command the user means to run, so it is NOT escaped). Shared by the
    /// clipboard paste path (`readPasteboardText`) and the drag-drop handler (`GhosttySurfaceView`), so a
    /// dropped file inserts its path exactly like a pasted one.
    static func pasteboardText(_ pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let parts = urls.map(urlText).filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        return pb.string(forType: .string).flatMap { !$0.isEmpty ? $0 : nil }
    }

    /// The text one pasteboard URL contributes to a paste: a shell-escaped path for a file URL (so a path
    /// with spaces lands as one argument), else the escaped absolute string. The SINGLE definition shared by
    /// `pasteboardText` and `hasPasteboardText`, so the reader and the menu gate cannot drift apart — an
    /// invariant with no automated test (the file-URL case is not XCUITest-able; see the Control API rule).
    private static func urlText(_ url: URL) -> String {
        ShellEscape.path(url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString)
    }

    /// Pasted text from the general clipboard (the libghostty paste callback).
    static func readPasteboardText() -> String? { pasteboardText(.general) }

    /// Whether `pasteboardText` would return something, without building the joined result. Menu validation
    /// runs on every Edit-menu open and on every ⌘V key-equivalent lookup, so the Paste gate short-circuits on
    /// the first usable URL instead of mapping, escaping and joining the whole clipboard.
    ///
    /// It must agree with `pasteboardText` in BOTH directions. A bare `canReadObject([NSURL])` probe does not:
    /// that is a TYPE check, so a pasteboard merely DECLARING `public.file-url` with no usable value enables
    /// Paste while the reader returns nil and the paste inserts nothing (verified against a named pasteboard).
    /// Hence the same `urlText` + non-empty filter the reader applies.
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
