import agtermCore
import AppKit

/// Blends the window title bar with the terminal, mirroring macterm's `WindowAppearance` (itself mirroring
/// Ghostty's transparent-titlebar path). Besides a transparent titlebar + `fullSizeContentView` + a
/// terminal-matching window background, AppKit's private `NSTitlebarView` paints its own material layer
/// drawing a visible band at the titlebar height; clearing it lets the window background show through.
@MainActor
enum WindowAppearance {
    /// The window-chrome inputs composited at the AppKit level, read from the shared `GhosttyApp`
    /// channels by `WindowAccessor.applyTitlebarBlend`. Defaults are the opaque, full-height look.
    struct Chrome {
        var opacity: Double = 1
        var blurRadius: Int = 0
        var toolbarMode: ToolbarMode = .compact
    }

    /// Apply the blend to `window` using `background` (the terminal background color) and the `chrome`
    /// inputs. Idempotent, and re-applying on attach and on every window/title/appearance update is
    /// REQUIRED: AppKit rebuilds the titlebar subviews and re-asserts a default toolbar style on
    /// key/main/fullscreen transitions, bringing the seam back and unsticking the chosen toolbar style.
    ///
    /// At full opacity the window is opaque with a solid background; below it the window goes non-opaque
    /// and its background carries the alpha — the renderer is pinned transparent
    /// (`AppSettings.ghosttyConfigLines`) and the chrome paints nothing, so the interior reads as one
    /// continuous translucent, optionally blurred surface. macOS Reduce Transparency leaves the saved
    /// chrome inputs unchanged and presents opaque and unblurred until it is turned off.
    static func sync(window: NSWindow, background: NSColor, chrome: Chrome) {
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // the visible title is our custom titlebar row; hide AppKit's own title text so the OS window
        // title (set by the accessor for the window menu / XCUITest) never shows beside the header.
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        // hidden toolbar mode drops the three traffic-light buttons for a full-bleed terminal, every other
        // mode restores them. skipped in fullscreen so AppKit's own auto-showing buttons stay intact.
        let hideButtons = chrome.toolbarMode == .hidden && !window.styleMask.contains(.fullScreen)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = hideButtons
        }

        // native fullscreen draws its own opaque background and the chrome shows through any transparency,
        // so force opaque there; Reduce Transparency forces the same without touching the saved inputs.
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let transparent = chrome.opacity < 1
            && !window.styleMask.contains(.fullScreen)
            && !reduceTransparency
        if transparent {
            window.isOpaque = false
            window.backgroundColor = background.withAlphaComponent(chrome.opacity)
            setWindowBackgroundBlur(window, radius: chrome.blurRadius)
        } else {
            window.isOpaque = true
            window.backgroundColor = background
            setWindowBackgroundBlur(window, radius: 0) // clear any blur applied while translucent
        }

        // keep the sidebar see-through (the lighter/darker tint is layered in SwiftUI, not here). on macOS
        // 26 the NavigationSplitView sidebar is a Liquid Glass container: `NSGlassEffectView.tintColor` is
        // an INPUT to the material, not an opaque fill, so AppKit re-cooks it markedly lighter/frostier when
        // the window resigns key, and there is no `NSVisualEffectView.state = .active` equivalent to pin it.
        // clearing the glass keeps the color constant across key/non-key — visible only with multiple windows.
        syncSidebarBackground(in: window)

        // the title/terminal separator is SwiftUI's (`WindowContentView.titlebarHairline`), drawn full width
        // by both columns and omitted in hidden mode. Nothing below draws it.
        guard let container = titlebarContainer(in: window) else { return }
        if let titlebarView = container.firstDescendant(withClassName: "NSTitlebarView") {
            titlebarView.wantsLayer = true
            titlebarView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        // always hide the OS titlebar background — our custom row is the chrome. At full opacity, or when
        // .hiddenTitleBar doesn't hold (the XCUITest reopen path), it paints a dark strip above the header.
        container.firstDescendant(withClassName: "NSTitlebarBackgroundView")?.isHidden = true
        // hidden mode must also suppress `_NSTitlebarDecorationView` — a full-width titlebar-height sibling
        // of NSTitlebarView painting a vibrancy material band (macOS 26). tall/compact cover it with the
        // custom row; hidden mode (traffic lights gone, row collapsed to the 3px drag strip) leaves it bare.
        container.firstDescendant(withClassName: "_NSTitlebarDecorationView")?.isHidden = hideButtons
    }

    /// Keeps the sidebar see-through — opaque terminal color at full opacity, translucent tinted background
    /// + blur below it. The user's lighter/darker shift is layered in SwiftUI (a wash behind the transparent
    /// outline, `WindowContentView.sidebarTintWash`) so it composes with the translucency and covers tree +
    /// bottom bar uniformly. The macOS 26 Liquid Glass container is cleared too (defensive — the custom
    /// split no longer creates one).
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
    /// `NSContainerConcentricGlassEffectView` `NavigationSplitView` wraps the sidebar in on macOS 26).
    @available(macOS 26.0, *)
    private static func sidebarGlass(containing scroll: NSScrollView) -> NSGlassEffectView? {
        var node: NSView? = scroll.superview
        while let current = node {
            if let glass = current as? NSGlassEffectView { return glass }
            node = current.superview
        }
        return nil
    }

    /// Forces any nested legacy `NSVisualEffectView` to its active material regardless of window key state.
    private static func forceVisualEffectsActive(in view: NSView) {
        if let effect = view as? NSVisualEffectView { effect.state = .active }
        for subview in view.subviews { forceVisualEffectsActive(in: subview) }
    }

    /// The `NSTitlebarContainerView` for `window`, found from the window's root theme frame.
    private static func titlebarContainer(in window: NSWindow) -> NSView? {
        guard let contentView = window.contentView else { return nil }
        var root: NSView = contentView
        while let parent = root.superview { root = parent }
        if String(describing: type(of: root)) == "NSTitlebarContainerView" { return root }
        return root.firstDescendant(withClassName: "NSTitlebarContainerView")
    }
}

// MARK: - Private CGS background-blur SPI

// `CGSSetWindowBackgroundBlurRadius` is the private CoreGraphics call every macOS terminal (Terminal.app,
// iTerm, Ghostty, libghostty) uses to blur the content behind a translucent window — undocumented but
// long-stable. resolved once via dlsym; a missing symbol degrades to a no-op (no blur), not a crash.
// Adapted from thdxg/macterm (MIT).
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
    /// Depth-first search for the first descendant whose runtime class name matches — the only way to reach
    /// AppKit's private titlebar views.
    func firstDescendant(withClassName className: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == className { return subview }
            if let found = subview.firstDescendant(withClassName: className) { return found }
        }
        return nil
    }

    /// Depth-first search for the first descendant (or self) carrying the given identifier.
    func firstDescendant(withIdentifier identifier: String) -> NSView? {
        if self.identifier?.rawValue == identifier { return self }
        for subview in subviews {
            if let found = subview.firstDescendant(withIdentifier: identifier) { return found }
        }
        return nil
    }
}
