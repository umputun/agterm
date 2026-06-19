// adapted from thdxg/macterm (MIT)

import AppKit
import GhosttyKit

/// Routes libghostty runtime callbacks to the appropriate terminal views.
///
/// `@unchecked Sendable` and NOT `@MainActor`: the C closures run synchronously
/// off whatever thread libghostty calls from. This router holds no mutable
/// state. Every `@MainActor` touch hops via `DispatchQueue.main.async`, and any
/// C string is copied to a Swift `String` value *before* the hop (the `char*`
/// is only valid for the synchronous callback duration).
final class GhosttyCallbacks: @unchecked Sendable {
    func wakeup() {
        DispatchQueue.main.async { GhosttyApp.shared.tick() }
    }

    func action(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_PWD:
            guard let view = surfaceView(from: target), let ptr = action.action.pwd.pwd else { return true }
            let pwd = String(cString: ptr)
            DispatchQueue.main.async { view.applyPwd(pwd) }
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            // fires when the cell pixel size changes (font-size change via cmd +/-, or DPI
            // change). used only as a trigger: the view reads the live font size and the app
            // persists it.
            guard let view = surfaceView(from: target) else { return true }
            DispatchQueue.main.async { view.reportFontSize() }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // the child process exited. ghostty prints its "Process exited. Press any key to close"
            // fallback unless the host consumes this action. an overlay that should vanish closes
            // immediately and returns true to suppress the prompt; a wait-opt-in overlay (and any other
            // surface) returns false so ghostty shows the prompt and close_surface_cb handles the close.
            guard let view = surfaceView(from: target), view.shouldCloseOnChildExitAction else { return false }
            DispatchQueue.main.async { view.handleProcessExit() }
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

    /// Returns pasted text from the pasteboard: file paths (Finder drag/copy)
    /// fall back to plain string.
    static func readPasteboardText() -> String? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let paths = urls
                .map { url in url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString }
                .filter { !$0.isEmpty }
            if !paths.isEmpty { return paths.joined(separator: " ") }
        }
        return pb.string(forType: .string).flatMap { !$0.isEmpty ? $0 : nil }
    }

    func confirmReadClipboard(ud: UnsafeMutableRawPointer?, content: UnsafePointer<CChar>?, state: UnsafeMutableRawPointer?) {
        guard let content else { return }
        ghostty_surface_complete_clipboard_request(surface(from: ud), content, state, true)
    }

    func writeClipboard(content: UnsafePointer<ghostty_clipboard_content_s>?, len: UInt) {
        guard let content, len > 0 else { return }
        for item in UnsafeBufferPointer(start: content, count: Int(len)) {
            guard let data = item.data, let mime = item.mime, String(cString: mime).hasPrefix("text/plain") else { continue }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(cString: data), forType: .string)
            return
        }
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
