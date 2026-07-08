import agtermCore
import AppKit

/// App-side bridge mapping a `WindowInfo.ID` to its live `NSWindow`. `WindowLibrary` is host-free
/// (no AppKit), so the NSWindow handles live here. `TitleProbeView` registers/unregisters on window
/// attach/close; `raise(_:)` brings an already-open window forward (the dedup-by-id raise path) and
/// `close(_:)` runs `performClose` (the `window.close` teardown path).
@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()
    private var windows: [WindowInfo.ID: NSWindow] = [:]

    private init() {}

    var registeredCount: Int { windows.count }

    func register(_ id: WindowInfo.ID, window: NSWindow) {
        windows[id] = window
    }

    /// Whether an on-screen window is registered for `id` (i.e. its NSWindow has attached).
    func isRegistered(_ id: WindowInfo.ID) -> Bool { windows[id] != nil }

    /// Whether the on-screen window for `id` is currently the key window. False when none is registered.
    /// The auto-follow focus bridge gates on this so only a key window pulls first responder into the
    /// auto-followed session; a background window changes only its selection.
    func isKeyWindow(_ id: WindowInfo.ID) -> Bool { windows[id]?.isKeyWindow ?? false }

    func unregister(_ id: WindowInfo.ID) {
        windows[id] = nil
    }

    func contains(_ window: NSWindow) -> Bool {
        windows.values.contains { $0 === window }
    }

    /// Brings the window for `id` to the front if one is live. Returns whether a window was raised.
    @discardableResult
    func raise(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Closes the on-screen window for `id` if one is live. Uses `window.close()` (NOT `performClose`)
    /// so it bypasses the confirm-before-close proxy — this is the programmatic path (Delete Window,
    /// which already confirms, and the control socket, which must stay headless). `close()` still runs
    /// the `willClose` teardown + library mark-closed. Returns whether a window was closed.
    @discardableResult
    func close(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        window.close()
        return true
    }

    /// Resizes the on-screen window for `id` to `width` x `height` points (frame size), keeping its top
    /// edge fixed and clamping into `[window.minSize, screen.visibleFrame]` via `WindowGeometry.clampSize`
    /// (the single clamp path). Returns false if no window is registered for `id` (not open). The
    /// control-channel `window.resize` path.
    @discardableResult
    func resize(_ id: WindowInfo.ID, width: Int, height: Int) -> Bool {
        guard let window = windows[id] else { return false }
        let maxSize = (window.screen ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let size = WindowGeometry.clampSize(WindowGeometry.Size(CGSize(width: CGFloat(width), height: CGFloat(height))),
                                            min: WindowGeometry.Size(window.minSize),
                                            max: WindowGeometry.Size(maxSize)).cgSize
        var frame = window.frame
        frame.origin.y += frame.size.height - size.height // keep the top edge fixed
        frame.size = size
        window.setFrame(frame, display: true)
        return true
    }

    /// Moves the on-screen window for `id` so its top-left corner is at (`x`, `y`) points relative to the
    /// top-left of `display` (an index into the screen list; nil = the window's current display), y down.
    /// The origin is clamped via `WindowGeometry.clampOrigin` so an off-screen request keeps a grabbable
    /// strip on the target display. Returns false if no window is registered for `id` (not open) or
    /// `display` is out of range. The control-channel `window.move` path.
    @discardableResult
    func move(_ id: WindowInfo.ID, x: Int, y: Int, display: Int?) -> Bool {
        guard let window = windows[id] else { return false }
        let screen: NSScreen?
        if let display {
            let screens = NSScreen.screens
            guard display >= 0, display < screens.count else { return false }
            screen = screens[display]
        } else {
            screen = window.screen ?? NSScreen.main
        }
        guard let screen else { return false }
        // (x, y) is the top-left relative to the screen's top-left (y down) → AppKit screen point (y up).
        let size = window.frame.size
        let topLeft = NSPoint(x: screen.frame.minX + CGFloat(x), y: screen.frame.maxY - CGFloat(y))
        // convert top-left to the frame's bottom-left origin, then clamp so a strip stays on the display.
        let requested = WindowGeometry.Point(x: Double(topLeft.x), y: Double(topLeft.y - size.height))
        let origin = WindowGeometry.clampOrigin(requested, windowSize: WindowGeometry.Size(size),
                                                displayFrame: WindowGeometry.Rect(screen.frame)).cgPoint
        window.setFrameOrigin(origin)
        return true
    }

    /// Zooms (the maximize-to-screen toggle) the on-screen window for `id` if one is live, driving the
    /// standard `NSWindow.zoom` — the same action as the double-click-header gesture (a plain green-button
    /// click does native full screen instead; Option-click zooms). A second call restores the prior frame.
    /// Returns false if no window is registered for `id`
    /// (not open). The control-channel `window.zoom` path.
    @discardableResult
    func zoom(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        window.zoom(nil)
        return true
    }

    /// Toggles native macOS full screen for the on-screen window for `id` if one is live, driving the
    /// standard `NSWindow.toggleFullScreen` — the same action as the green traffic-light button. A second
    /// call exits full screen. Returns false if no window is registered for `id` (not open). The
    /// control-channel `window.fullscreen` path; the GUI half toggles the key window directly.
    @discardableResult
    func fullscreen(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        window.toggleFullScreen(nil)
        return true
    }

    /// The window's current frame in the SAME coordinate system `move`/`resize` accept, so `window.list`'s
    /// read-back round-trips back through `window.move`/`window.resize`: `x`/`y` are the top-left relative to
    /// the window's display top-left (y down), `width`/`height` the frame size, `display` the screen index.
    /// This is the inverse of `move`'s forward math (`x = minX - screen.minX`, `y = screen.maxY - maxY`) to
    /// integer-point precision: the values round to `Int` since `window.move`/`window.resize` take `Int`, so a
    /// user-dragged fractional frame restores to the nearest point (which is all those commands accept).
    /// Nil when no window is registered for `id` (closed) or it has no screen. The `window.list` frame source.
    func geometry(for id: WindowInfo.ID) -> ControlWindowFrame? {
        guard let window = windows[id], let screen = window.screen else { return nil }
        let frame = window.frame
        let x = Int((frame.minX - screen.frame.minX).rounded())
        let y = Int((screen.frame.maxY - frame.maxY).rounded())
        let display = NSScreen.screens.firstIndex(of: screen) ?? 0
        return ControlWindowFrame(x: x, y: y,
                                  width: Int(frame.width.rounded()), height: Int(frame.height.rounded()),
                                  display: display)
    }

    /// Whether the window for `id` is in native full screen and/or zoomed (maximized-to-screen, NOT full
    /// screen), or nil when no window is registered (closed). The read side of `window.fullscreen`/`window.zoom`
    /// on `window.list`, so a script can make those toggles idempotent.
    func windowFlags(for id: WindowInfo.ID) -> (fullscreen: Bool, zoomed: Bool)? {
        guard let window = windows[id] else { return nil }
        return (fullscreen: window.styleMask.contains(.fullScreen), zoomed: window.isZoomed)
    }
}

// CoreGraphics <-> host-free WindowGeometry conversions, kept app-side: agtermCore stays Foundation-only
// (a CoreGraphics member reference there crashes the release WMO SIL deserializer — see WindowGeometry).
private extension WindowGeometry.Size {
    init(_ cg: CGSize) { self.init(width: Double(cg.width), height: Double(cg.height)) }
    var cgSize: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }
}

private extension WindowGeometry.Point {
    var cgPoint: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
}

private extension WindowGeometry.Rect {
    init(_ cg: CGRect) {
        self.init(origin: WindowGeometry.Point(x: Double(cg.origin.x), y: Double(cg.origin.y)),
                  size: WindowGeometry.Size(cg.size))
    }
}
