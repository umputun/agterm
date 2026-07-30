import agtermCore
import AppKit

/// App-side bridge mapping a `WindowInfo.ID` to its live `NSWindow` — `WindowLibrary` is host-free (no
/// AppKit), so the NSWindow handles live here. `TitleProbeView` registers/unregisters on window attach/close;
/// `raise(_:)` brings an already-open window forward (the dedup-by-id raise path), `close(_:)` tears it down.
@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()
    private var windows: [WindowInfo.ID: NSWindow] = [:]

    private init() {}

    var registeredCount: Int { windows.count }

    func register(_ id: WindowInfo.ID, window: NSWindow) {
        windows[id] = window
        NotificationCenter.default.post(name: .agtermWindowAttachmentChanged, object: nil)
    }

    /// Whether an on-screen window is registered for `id` (i.e. its NSWindow has attached).
    func isRegistered(_ id: WindowInfo.ID) -> Bool { windows[id] != nil }

    /// Whether the on-screen window for `id` is currently the key window; false when none is registered. The
    /// auto-follow focus bridge gates on it, so only a key window pulls first responder into the followed
    /// session and a background window changes only its selection.
    func isKeyWindow(_ id: WindowInfo.ID) -> Bool { windows[id]?.isKeyWindow ?? false }

    func unregister(_ id: WindowInfo.ID) {
        windows[id] = nil
        NotificationCenter.default.post(name: .agtermWindowAttachmentChanged, object: nil)
    }

    func contains(_ window: NSWindow) -> Bool {
        windows.values.contains { $0 === window }
    }

    /// Returns the stable control-window id for a live AppKit window. Focus retry loops use this reverse
    /// lookup to honor window-scoped modal state without coupling each terminal surface to `WindowLibrary`.
    func windowID(for window: NSWindow) -> WindowInfo.ID? {
        windows.first { $0.value === window }?.key
    }

    /// Brings the window for `id` to the front if one is live. Returns whether a window was raised.
    @discardableResult
    func raise(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Closes the on-screen window for `id` if one is live, returning whether one was. `window.close()` NOT
    /// `performClose`, to bypass the confirm-before-close proxy — this is the programmatic path (Delete
    /// Window already confirms; the control socket must stay headless). `close()` still runs the `willClose`
    /// teardown + library mark-closed.
    @discardableResult
    func close(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        window.close()
        return true
    }

    /// Resizes the on-screen window for `id` to `width` x `height` points (frame size), top edge fixed,
    /// clamped into `[window.minSize, screen.visibleFrame]` via `WindowGeometry.clampSize` (the single clamp
    /// path). False if no window is registered for `id` (not open). The control-channel `window.resize` path.
    @discardableResult
    func resize(_ id: WindowInfo.ID, width: Int, height: Int) -> Bool {
        guard let window = windows[id] else { return false }
        let maxSize = resolvedScreen(for: window)?.visibleFrame.size
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

    /// Moves the on-screen window for `id` so its top-left is at (`x`, `y`) points from the top-left of
    /// `display` (a screen-list index; nil = the window's current display), y down, clamped via
    /// `WindowGeometry.clampOrigin` so an off-screen request keeps a grabbable strip on the target display.
    /// False if no window is registered (not open) or `display` is out of range. The `window.move` path.
    @discardableResult
    func move(_ id: WindowInfo.ID, x: Int, y: Int, display: Int?) -> Bool {
        guard let window = windows[id] else { return false }
        let screen: NSScreen?
        if let display {
            let screens = NSScreen.screens
            guard display >= 0, display < screens.count else { return false }
            screen = screens[display]
        } else {
            screen = resolvedScreen(for: window)
        }
        guard let screen else { return false }
        // (x, y) is the top-left relative to the screen's top-left (y down) → AppKit screen point (y up).
        let size = window.frame.size
        let topLeft = NSPoint(x: screen.frame.minX + CGFloat(x), y: screen.frame.maxY - CGFloat(y))
        let requested = WindowGeometry.Point(x: Double(topLeft.x), y: Double(topLeft.y - size.height))
        let origin = WindowGeometry.clampOrigin(requested, windowSize: WindowGeometry.Size(size),
                                                displayFrame: WindowGeometry.Rect(screen.frame)).cgPoint
        window.setFrameOrigin(origin)
        return true
    }

    /// Zooms (maximize-to-screen) the on-screen window for `id` if one is live, driving the standard
    /// `NSWindow.zoom` — the double-click-header gesture's action (a plain green-button click does native
    /// full screen instead; Option-click zooms). A second call restores the prior frame. False if no window
    /// is registered for `id` (not open). The control-channel `window.zoom` path.
    @discardableResult
    func zoom(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        window.zoom(nil)
        return true
    }

    /// Toggles native macOS full screen for `id`'s window if one is live, driving the standard
    /// `NSWindow.toggleFullScreen` — the green traffic-light button's action; a second call exits. False if
    /// no window is registered (not open). The control-channel `window.fullscreen` path; the GUI half
    /// toggles the key window directly.
    @discardableResult
    func fullscreen(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        window.toggleFullScreen(nil)
        return true
    }

    /// Whether the window for `id` is minimized to the Dock. False when none is registered. The settle-poll
    /// predicate for `window.minimize`, which must wait out the animation before reporting.
    func isMinimized(_ id: WindowInfo.ID) -> Bool { windows[id]?.isMiniaturized ?? false }

    /// The outcome of a `minimize` request, so the caller can tell "not open" from "not minimizable".
    enum MinimizeOutcome {
        case applied(desired: Bool)
        case notOpen
        case fullScreen
    }

    /// Minimizes `id`'s on-screen window to the Dock, or restores it, via the standard
    /// `NSWindow.miniaturize`/`deminiaturize` — the action of ⌘M, the yellow traffic-light button, and the
    /// Minimize title-bar double-click. The mode resolves against the window's CURRENT state, so `on`/`off`
    /// are idempotent and only `toggle` flips. Restoring puts the window back on screen without making it
    /// key; `window.select` (`raise`) is the raise-it-too path. A window in native full screen is REJECTED
    /// rather than silently ignored: AppKit no-ops `miniaturize` there, so applying it would report success
    /// having done nothing.
    func minimize(_ id: WindowInfo.ID, mode: ControlToggleMode) -> MinimizeOutcome {
        guard let window = windows[id] else { return .notOpen }
        let desired = mode.desiredValue(current: window.isMiniaturized)
        guard window.isMiniaturized != desired else { return .applied(desired: desired) }
        guard !window.styleMask.contains(.fullScreen) else { return .fullScreen }
        if desired { window.miniaturize(nil) } else { window.deminiaturize(nil) }
        return .applied(desired: desired)
    }

    /// The screen a window's frame belongs to. `NSWindow.screen` is nil whenever the window is off-screen —
    /// notably while MINIMIZED to the Dock, and while the app is hidden — so fall back to the display its
    /// frame overlaps most (`WindowGeometry.bestDisplayIndex`, the frame-restore path's resolution), then
    /// the main screen for a frame overlapping nothing (a disconnected display). Shared by `geometry`,
    /// `move`, and `resize` on purpose: a read resolved by overlap and a write resolved against
    /// `NSScreen.main` would disagree on the display index, so a minimized window's reported frame would
    /// stop round-tripping back through `window.move`.
    private func resolvedScreen(for window: NSWindow) -> NSScreen? {
        if let screen = window.screen { return screen }
        let screens = NSScreen.screens
        let frames = screens.map { WindowGeometry.Rect($0.frame) }
        if let index = WindowGeometry.bestDisplayIndex(for: WindowGeometry.Rect(window.frame), among: frames) {
            return screens[index]
        }
        return NSScreen.main ?? screens.first
    }

    /// The window's current frame in the SAME coordinate system `move`/`resize` accept, so `window.list`'s
    /// read-back round-trips back through them: `x`/`y` are the top-left relative to the window's display
    /// top-left (y down), `width`/`height` the frame size, `display` the screen index. The inverse of
    /// `move`'s forward math (`x = minX - screen.minX`, `y = screen.maxY - maxY`) to integer-point precision
    /// — the values round to `Int` because those commands take `Int`, so a user-dragged fractional frame
    /// restores to the nearest point. Nil when no window is registered (closed). The `window.list` source.
    func geometry(for id: WindowInfo.ID) -> ControlWindowFrame? {
        guard let window = windows[id], let screen = resolvedScreen(for: window) else { return nil }
        let frame = window.frame
        let x = Int((frame.minX - screen.frame.minX).rounded())
        let y = Int((screen.frame.maxY - frame.maxY).rounded())
        let display = NSScreen.screens.firstIndex(of: screen) ?? 0
        return ControlWindowFrame(x: x, y: y,
                                  width: Int(frame.width.rounded()), height: Int(frame.height.rounded()),
                                  display: display)
    }

    /// Whether the window for `id` is in native full screen, zoomed (maximized-to-screen, NOT full screen),
    /// and/or minimized to the Dock; nil when no window is registered (closed). The read side of
    /// `window.fullscreen`/`window.zoom`/`window.minimize` on `window.list`, for idempotent toggles.
    func windowFlags(for id: WindowInfo.ID) -> (fullscreen: Bool, zoomed: Bool, minimized: Bool)? {
        guard let window = windows[id] else { return nil }
        return (fullscreen: window.styleMask.contains(.fullScreen), zoomed: window.isZoomed,
                minimized: window.isMiniaturized)
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
