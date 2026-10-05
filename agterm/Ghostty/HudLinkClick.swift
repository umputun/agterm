import AppKit
import GhosttyKit

/// Gives a HUD panel the terminal's link gesture: ⌘ over a link shows the pointing hand, ⌘-click opens it.
/// The panel refuses every hit (`viewOnly`, under SwiftUI's `.allowsHitTesting(false)`) and tracks no
/// pointer, so neither can reach its surface the ordinary way. ONE app-wide monitor feeds it instead, as
/// `SplitRatioAccessor` does for the divider, which leaves the passivity gates as they are: every other
/// click still reaches the session, and without ⌘ the panel hears nothing.
@MainActor
enum HudLinkClick {
    private static let panels = NSHashTable<GhosttySurfaceView>.weakObjects()
    private static var monitor: Any?
    private static weak var pressed: GhosttySurfaceView?
    /// The panel the pointer is over with ⌘ held, which is the only time a panel is told where it is.
    private(set) static weak var hovered: GhosttySurfaceView?

    /// Whether a panel shows a link under the pointer, so the pane beneath must leave the cursor alone.
    static var ownsCursor: Bool { hovered?.mouseShape == GHOSTTY_MOUSE_SHAPE_POINTER }

    /// A panel freed while tracked leaves the monitor installed, which costs nothing: `panels` is weak.
    static func track(_ panel: GhosttySurfaceView, _ tracked: Bool) {
        guard tracked else { return panels.remove(panel) }
        panels.add(panel)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseMoved, .flagsChanged]) { event in
            if event.type == .mouseMoved || event.type == .flagsChanged {
                hover(event)
                return event
            }
            return consumes(event) ? nil : event
        }
    }

    /// Reports the pointer to the panel under it while ⌘ is the only modifier held, and takes it away again
    /// when either stops being true, so libghostty raises and drops its own hovered-link state.
    static func hover(_ event: NSEvent) {
        let held = event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command
        let point = event.type == .mouseMoved ? event.locationInWindow : event.window?.mouseLocationOutsideOfEventStream
        let panel = held ? point.flatMap { panel(in: event.window, at: $0) } : nil
        let owned = ownsCursor
        if let previous = hovered, previous !== panel { previous.passivePointer(at: nil, with: event) }
        hovered = panel
        if let panel, let point { panel.passivePointer(at: point, with: event) }
        // after this event is dispatched: SwiftUI resets the cursor on a move, and a stationary ⌘ release
        // reaches no pane that would put its own shape back
        DispatchQueue.main.async {
            if ownsCursor { NSCursor.pointingHand.set() } else if owned, hovered == nil { NSCursor.iBeam.set() }
        }
    }

    /// The release is claimed only after a claimed press, so the pair always reaches the same surface.
    static func consumes(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseUp {
            guard let panel = pressed else { return false }
            pressed = nil
            panel.passiveClick(GHOSTTY_MOUSE_RELEASE, with: event)
            return true
        }
        guard isLinkClick(event), let panel = panel(in: event.window, at: event.locationInWindow) else { return false }
        pressed = panel
        panel.passiveClick(GHOSTTY_MOUSE_PRESS, with: event)
        return true
    }

    /// Whether `event` is a left press with ⌘ as its only modifier, which is what libghostty requires
    /// before it resolves a link under the pointer.
    static func isLinkClick(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else { return false }
        return event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command
    }

    private static func panel(in window: NSWindow?, at point: NSPoint) -> GhosttySurfaceView? {
        guard let window, window.attachedSheet == nil else { return nil }
        return panels.allObjects.first { panel in
            panel.deckOnScreen && panel.window === window && panel.bounds.contains(panel.convert(point, from: nil))
        }
    }
}
