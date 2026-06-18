import AppKit

/// Blends the window title bar with the terminal, mirroring macterm's `WindowAppearance`
/// (which in turn mirrors Ghostty's transparent-titlebar path). The trick that makes it
/// seamless: besides a transparent titlebar + `fullSizeContentView` + a window background
/// matching the terminal, AppKit's private `NSTitlebarView` paints its own material layer
/// that draws a visible band/seam at the titlebar height. Clearing that layer lets the
/// window background (and the full-size content below it) show through continuously.
@MainActor
enum WindowAppearance {
    /// Apply the blend to `window` using `background` (the terminal background color).
    /// Idempotent; safe to re-apply on attach and on every window/title update — AppKit
    /// rebuilds the titlebar subviews on key/main/fullscreen transitions, so re-applying
    /// is required to keep the seam gone.
    static func sync(window: NSWindow, background: NSColor) {
        window.titlebarAppearsTransparent = true
        // a slightly-visible hairline between the title area and the terminal.
        window.titlebarSeparatorStyle = .line
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = true
        window.backgroundColor = background

        guard let titlebarView = titlebarContainer(in: window)?.firstDescendant(withClassName: "NSTitlebarView") else {
            return
        }
        titlebarView.wantsLayer = true
        titlebarView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// The `NSTitlebarContainerView` for `window` — a descendant of the window's root
    /// theme frame (the superview chain above the content view).
    private static func titlebarContainer(in window: NSWindow) -> NSView? {
        guard let contentView = window.contentView else { return nil }
        var root: NSView = contentView
        while let parent = root.superview { root = parent }
        if String(describing: type(of: root)) == "NSTitlebarContainerView" { return root }
        return root.firstDescendant(withClassName: "NSTitlebarContainerView")
    }
}

extension NSView {
    /// Depth-first search for the first descendant whose runtime class name matches.
    /// Used to reach AppKit's private titlebar views by class name.
    func firstDescendant(withClassName className: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == className { return subview }
            if let found = subview.firstDescendant(withClassName: className) { return found }
        }
        return nil
    }
}
