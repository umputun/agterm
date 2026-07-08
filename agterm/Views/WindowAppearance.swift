import agtermCore
import AppKit

/// Blends the window title bar with the terminal, mirroring macterm's `WindowAppearance`
/// (which in turn mirrors Ghostty's transparent-titlebar path). The trick that makes it
/// seamless: besides a transparent titlebar + `fullSizeContentView` + a window background
/// matching the terminal, AppKit's private `NSTitlebarView` paints its own material layer
/// that draws a visible band/seam at the titlebar height. Clearing that layer lets the
/// window background (and the full-size content below it) show through continuously.
@MainActor
enum WindowAppearance {
    /// The window-chrome inputs composited at the AppKit level, read from the shared `GhosttyApp`
    /// channels by `WindowAccessor.applyTitlebarBlend`. Defaults are the opaque, full-height look.
    struct Chrome {
        var opacity: Double = 1
        var blurRadius: Int = 0
        var toolbarMode: ToolbarMode = .compact
    }

    /// Apply the blend to `window` using `background` (the terminal background color) and the given
    /// `chrome` inputs. Idempotent; safe to re-apply on attach and on every window/title/appearance
    /// update — AppKit rebuilds the titlebar subviews (and re-asserts a default toolbar style) on
    /// key/main/fullscreen transitions, so re-applying is required to keep the seam gone and the
    /// chosen toolbar style stuck.
    ///
    /// At full opacity the window is opaque with a solid background (the original behavior). Below
    /// full opacity the window goes non-opaque and its background carries the alpha: the renderer is
    /// pinned transparent (see `AppSettings.ghosttyConfigLines`) and the chrome paints nothing, so
    /// the whole interior reads as one continuous translucent surface, optionally blurred.
    static func sync(window: NSWindow, background: NSColor, chrome: Chrome) {
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // the visible title is our custom titlebar row; hide AppKit's own title text so the OS window
        // title (set by the accessor for the window menu / XCUITest) never shows beside the header.
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        // hidden toolbar mode drops the three traffic-light buttons for a full-bleed terminal; every
        // other mode restores them. Skipped in fullscreen so entering/exiting fullscreen (which re-runs
        // this sync) leaves AppKit's own auto-showing title bar buttons intact, like the translucency below.
        let hideButtons = chrome.toolbarMode == .hidden && !window.styleMask.contains(.fullScreen)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = hideButtons
        }

        // native fullscreen draws its own opaque background and the chrome shows through any
        // transparency, so force opaque while fullscreened.
        let transparent = chrome.opacity < 1 && !window.styleMask.contains(.fullScreen)
        if transparent {
            window.isOpaque = false
            window.backgroundColor = background.withAlphaComponent(chrome.opacity)
            setWindowBackgroundBlur(window, radius: chrome.blurRadius)
        } else {
            window.isOpaque = true
            window.backgroundColor = background
            setWindowBackgroundBlur(window, radius: 0) // clear any blur applied while translucent
        }

        // keep the sidebar see-through so the window background shows through it (the lighter/darker
        // tint is layered in SwiftUI, not here). on macOS 26 the NavigationSplitView sidebar is a Liquid
        // Glass container wrapping the sidebar content: `NSGlassEffectView.tintColor` is an INPUT to the
        // glass material, not an
        // opaque fill — so AppKit re-cooks it markedly lighter/frostier when the window resigns key,
        // and there is no `NSVisualEffectView.state = .active` equivalent on `NSGlassEffectView` to
        // pin it. To keep the sidebar a constant color across key/non-key (only visible once there are
        // multiple windows), stop letting the glass be the background: clear it so the window background
        // shows through (the sidebar tint is layered in SwiftUI — see `syncSidebarBackground`).
        syncSidebarBackground(in: window)

        // the title/terminal separator is drawn in the detail pane (ContentView), so it
        // ends at the sidebar edge rather than spanning the full titlebar width.
        guard let container = titlebarContainer(in: window) else { return }
        if let titlebarView = container.firstDescendant(withClassName: "NSTitlebarView") {
            titlebarView.wantsLayer = true
            titlebarView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        // always hide the OS titlebar background: our custom titlebar row is the chrome. At full
        // opacity, or when .hiddenTitleBar doesn't hold (the XCUITest reopen path), it would otherwise
        // paint a dark strip above the header.
        container.firstDescendant(withClassName: "NSTitlebarBackgroundView")?.isHidden = true
    }

    /// Keeps the sidebar see-through so the window background shows through it — the opaque terminal
    /// color at full opacity, or the translucent tinted background + blur below it. The user's
    /// lighter/darker sidebar shift is layered in SwiftUI (a wash behind the transparent outline, see
    /// `WindowContentView.sidebarTintWash`) so it composes with the translucency instead of fighting it
    /// and covers the whole column (tree + bottom bar) uniformly. On macOS 26 the Liquid Glass container
    /// that could wrap the sidebar is cleared too (defensive — the custom split no longer creates one).
    private static func syncSidebarBackground(in window: NSWindow) {
        guard let scroll = sidebarScroll(in: window) else { return }
        if #available(macOS 26.0, *), let glass = sidebarGlass(containing: scroll) {
            glass.style = .clear
            glass.tintColor = nil
            glass.contentView?.wantsLayer = true
            glass.contentView?.layer?.backgroundColor = nil
            forceVisualEffectsActive(in: glass)
        }
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        if let outline = scroll.documentView as? NSOutlineView {
            outline.backgroundColor = .clear
        }
    }

    /// The sidebar's tagged scroll view (`agterm-sidebar-scroll`), searched from the window's root view.
    private static func sidebarScroll(in window: NSWindow) -> NSScrollView? {
        guard let contentView = window.contentView else { return nil }
        var root: NSView = contentView
        while let parent = root.superview { root = parent }
        return root.firstDescendant(withIdentifier: "agterm-sidebar-scroll") as? NSScrollView
    }

    /// The first `NSGlassEffectView` ancestor of the sidebar scroll view (the
    /// `NSContainerConcentricGlassEffectView` that `NavigationSplitView` wraps the sidebar in on
    /// macOS 26).
    @available(macOS 26.0, *)
    private static func sidebarGlass(containing scroll: NSScrollView) -> NSGlassEffectView? {
        var node: NSView? = scroll.superview
        while let current = node {
            if let glass = current as? NSGlassEffectView { return glass }
            node = current.superview
        }
        return nil
    }

    /// Forces any nested legacy `NSVisualEffectView` to render its active material regardless of
    /// window key state — defensive insurance for the sidebar subtree.
    private static func forceVisualEffectsActive(in view: NSView) {
        if let effect = view as? NSVisualEffectView { effect.state = .active }
        for subview in view.subviews { forceVisualEffectsActive(in: subview) }
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

// MARK: - Private CGS background-blur SPI

// `CGSSetWindowBackgroundBlurRadius` is the private CoreGraphics call every macOS terminal
// (Terminal.app, iTerm, Ghostty) uses to blur the content behind a translucent window. Undocumented
// but long-stable; libghostty calls the same symbol. Resolved once via dlsym; a missing symbol
// degrades to a no-op (no blur) rather than crashing. Adapted from thdxg/macterm (MIT).
private let cgsDefaultConnection: (@convention(c) () -> Int32)? = {
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGSDefaultConnectionForThread") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
}()

private let cgsSetWindowBackgroundBlur: (@convention(c) (Int32, Int, Int32) -> Int32)? = {
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGSSetWindowBackgroundBlurRadius") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (Int32, Int, Int32) -> Int32).self)
}()

@MainActor
private func setWindowBackgroundBlur(_ window: NSWindow, radius: Int) {
    guard let cgsDefaultConnection, let cgsSetWindowBackgroundBlur else { return }
    _ = cgsSetWindowBackgroundBlur(cgsDefaultConnection(), window.windowNumber, Int32(radius))
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

    /// Depth-first search for the first descendant (or self) carrying the given identifier.
    /// Used to locate the tagged sidebar scroll view so its enclosing glass can be reached.
    func firstDescendant(withIdentifier identifier: String) -> NSView? {
        if self.identifier?.rawValue == identifier { return self }
        for subview in subviews {
            if let found = subview.firstDescendant(withIdentifier: identifier) { return found }
        }
        return nil
    }
}
