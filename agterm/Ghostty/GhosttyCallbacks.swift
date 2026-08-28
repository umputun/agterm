// adapted from thdxg/macterm (MIT)

import agtermCore
import AppKit
import GhosttyKit
import os
import UniformTypeIdentifiers

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

    struct ClipboardRead {
        let userdata: UnsafeMutableRawPointer?
        let location: ghostty_clipboard_e
        let state: UnsafeMutableRawPointer?
        let mimes: UnsafePointer<UnsafePointer<CChar>?>?
        let mimesLen: UInt
        let list: Bool
    }

    func readClipboard(_ read: ClipboardRead) -> ghostty_clipboard_read_result_e {
        guard let surface = surface(from: read.userdata) else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let text = Self.readPasteboardText()
        let requestsText = (0..<Int(read.mimesLen)).contains { index in
            read.mimes?[index].map { String(cString: $0) == "text/plain" } ?? false
        }
        // an empty pasteboard still answers a text request with a ZERO-LENGTH representation: an OSC 52
        // reader is waiting for the reply, and `UNAVAILABLE` means the request never started, so nothing
        // would reach the pty and the client would hang until its own timeout.
        let contents = requestsText ? [ClipboardContent(mime: "text/plain", data: Data((text ?? "").utf8))] : []
        guard !contents.isEmpty || read.list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        Self.completeClipboardRequest(
            surface, contents: contents, available: read.list && text != nil ? ["text/plain"] : [], state: read.state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
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

    func confirmReadClipboard(ud: UnsafeMutableRawPointer?, confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
                              state: UnsafeMutableRawPointer?,
                              request: ghostty_clipboard_request_e) {
        guard let ud, let confirm else {
            if let surface = surface(from: ud) { ghostty_surface_deny_clipboard_request(surface, state) }
            return
        }
        // capture the VIEW, not the raw surface pointer: a close (GUI or `session.close`) can free the surface
        // via destroySurface() WHILE the sheet is open. Re-read `view.surface` at completion and skip if it's
        // gone — freeing already discarded the request, so there is nothing to complete and no loop. The view
        // also scopes the prompt's coalescing to this surface.
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(ud).takeUnretainedValue()
        let payload = Self.copyClipboardConfirmation(confirm.pointee)
        nonisolated(unsafe) let requestState = state
        let access: ClipboardAccess? = switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ: .read
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE: .write
        default: nil
        }
        guard let access else {
            guard let surface = view.surface else { return }
            Self.completeClipboardRequest(
                surface, contents: payload.contents, available: payload.available,
                state: requestState, confirmed: true)
            return
        }
        DispatchQueue.main.async {
            ClipboardPromptController.shared.request(access, requester: view) { allowed in
                guard let surface = view.surface else { return }
                guard allowed else {
                    ghostty_surface_deny_clipboard_request(surface, requestState)
                    return
                }
                Self.completeClipboardRequest(
                    surface, contents: payload.contents, available: payload.available,
                    state: requestState, confirmed: true)
            }
        }
    }

    func writeClipboard(ud: UnsafeMutableRawPointer?, content: UnsafePointer<ghostty_clipboard_content_s>?, len: UInt, confirm: Bool) {
        guard let content, len > 0 else { return }
        // keep EVERY representation, not just text: a Kitty write can carry images, the callback is void,
        // and core reports `DONE` to the program right after it — dropping a representation here silently
        // lies to a client that was just told its write succeeded.
        let items: [ClipboardContent] = UnsafeBufferPointer(start: content, count: Int(len)).compactMap { item in
            guard let mime = item.mime else { return nil }
            let bytes = UnsafeRawBufferPointer(start: item.data, count: item.len)
            return ClipboardContent(mime: String(cString: mime), data: Data(bytes))
        }
        guard !items.isEmpty else { return }
        // confirm == false: ghostty's `allow` clipboard-write policy already permitted it. This callback runs
        // on the main actor (verified), so write SYNCHRONOUSLY — a same-tick OSC 52 read would see stale data.
        guard confirm else {
            Self.setClipboard(items)
            return
        }
        // confirm == true: clipboard-write = ask. Gate behind the user, scoping coalescing to this surface
        // (userdata is the surface, as in the read confirm) so one Allow can't authorize another's write.
        guard let ud else { return }
        let view = Unmanaged<GhosttySurfaceView>.fromOpaque(ud).takeUnretainedValue()
        DispatchQueue.main.async {
            ClipboardPromptController.shared.request(.write, requester: view) { allowed in
                if allowed { Self.setClipboard(items) }
            }
        }
    }

    private static func setClipboard(_ items: [ClipboardContent]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes(items.compactMap { NSPasteboard.PasteboardType(mimeType: $0.mime) }, owner: nil)
        for item in items {
            guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
            // setData for text too: the contract is binary-safe, and a String round-trip would silently
            // replace invalid UTF-8 in a representation core just reported as written.
            pb.setData(item.data, forType: type)
        }
    }

    private struct ClipboardContent: Sendable {
        let mime: String
        let data: Data
    }

    private static func copyClipboardConfirmation(_ confirm: ghostty_clipboard_confirm_s)
        -> (contents: [ClipboardContent], available: [String]) {
        var contents: [ClipboardContent] = []
        if let source = confirm.contents {
            for item in UnsafeBufferPointer(start: source, count: confirm.contents_len) {
                guard let mime = item.mime else { continue }
                let bytes = UnsafeRawBufferPointer(start: item.data, count: item.len)
                contents.append(ClipboardContent(mime: String(cString: mime), data: Data(bytes)))
            }
        }
        var available: [String] = []
        if let source = confirm.available {
            for mime in UnsafeBufferPointer(start: source, count: confirm.available_len) {
                if let mime { available.append(String(cString: mime)) }
            }
        }
        return (contents, available)
    }

    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t, contents: [ClipboardContent], available: [String],
        state: UnsafeMutableRawPointer?, confirmed: Bool = false
    ) {
        var strings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            strings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }

        var cContents: [ghostty_clipboard_content_s] = []
        for item in contents {
            guard let mime = strdup(item.mime) else { continue }
            strings.append(mime)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(item.data.count, 1), alignment: 1)
            buffers.append(buffer)
            item.data.withUnsafeBytes { bytes in
                if let source = bytes.baseAddress { buffer.copyMemory(from: source, byteCount: bytes.count) }
            }
            cContents.append(ghostty_clipboard_content_s(
                mime: mime, data: buffer.assumingMemoryBound(to: CChar.self), len: item.data.count))
        }

        var cAvailable: [UnsafePointer<CChar>?] = []
        for item in available {
            guard let mime = strdup(item) else { continue }
            strings.append(mime)
            cAvailable.append(UnsafePointer(mime))
        }
        cContents.withUnsafeBufferPointer { contentsBuffer in
            cAvailable.withUnsafeBufferPointer { availableBuffer in
                var completion = ghostty_clipboard_complete_s(
                    contents: contentsBuffer.baseAddress,
                    contents_len: contentsBuffer.count,
                    available: availableBuffer.baseAddress,
                    available_len: availableBuffer.count,
                    confirmed: confirmed,
                    remember: false)
                ghostty_surface_complete_clipboard_request(surface, &completion, state)
            }
        }
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

extension NSPasteboard.PasteboardType {
    /// A pasteboard type for a MIME string: `text/plain` is `.string`, else the UTType's identifier, else
    /// the raw MIME as identifier (Ghostty.app's mapping, so both sides of a write round-trip agree).
    init?(mimeType: String) {
        if mimeType == "text/plain" {
            self = .string
            return
        }
        guard let utType = UTType(mimeType: mimeType) else {
            self.init(mimeType)
            return
        }
        self.init(utType.identifier)
    }
}
