import AppKit
import GhosttyKit

extension GhosttySurfaceView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // above the nil-window guard: DETACHING is the transition nothing else reports. Hiding the quick
        // terminal unmounts its view with `deckVisible`/`viewOnly`/`surface` all unchanged, so this is the
        // only site that can clear the latch — below the guard it never ran, and the re-show then compared
        // equal and stayed silent too.
        postAccessibilityExposureChange()
        observeWindowVisibility()
        updateRendererVisibility()
        guard let window else { return }
        if surface == nil {
            createSurface()
        } else {
            let scale = Double(window.backingScaleFactor)
            ghostty_surface_set_content_scale(surface, scale, scale)
            let size = convertToBacking(bounds).size
            if size.width > 0, size.height > 0 {
                ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
            }
            updateGhosttyFocus()
        }
        updateMetalLayerSize()
        // focus is driven by TerminalSurfaceHost.updateNSView when this surface becomes the active session's detail
        // view; only an auto-focus (overlay) surface grabs here, since that grab misses a deferred surface.
        requestAutoFocus(in: window)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if pendingSurfaceCreation { createSurface() }
        updateMetalLayerSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalLayerSize()
    }

    /// Record this surface's light/dark scheme from the authoritative app-level `isDark`
    /// (`NSApp.effectiveAppearance`), so the NEXT `update_config` re-resolves a dual `theme = light:,dark:` to
    /// the matching side: libghostty takes the active side from the surface's RECORDED conditional state, not
    /// the config file alone, so a surface created before its window's appearance resolved re-derives the
    /// WRONG side. Cheap to re-assert (`set_color_scheme` early-returns unchanged); the caller sets the APP side.
    func syncColorScheme(isDark: Bool) {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    private func updateMetalLayerSize() {
        guard let surface, window != nil else { return }
        let scaledSize = convertToBacking(bounds).size
        guard scaledSize.width > 0, scaledSize.height > 0 else { return }
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        if let liveLayer = layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveLayer.contentsScale = CGFloat(scale)
            CATransaction.commit()
        }
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
        // the split re-parent invalidates the Metal drawable, and neither a same-grid set_size nor the tick
        // (dirty surfaces only) repaints it — force one or the re-hosted pane stays blank over a live buffer.
        ghostty_surface_refresh(surface)
        onGridChange?()
    }
}
