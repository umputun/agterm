import Foundation

/// Sidebar divider geometry: the shared width clamp and the persisting setter behind `sidebar.width`.
/// Visibility and view mode stay in `AppStore.swift` beside the rest of the per-window sidebar state.
extension AppStore {
    /// Clamp a finite width to `sidebarWidthMin...sidebarWidthMax`. The dispatcher rejects non-finite
    /// requests; drag and `restore()` supply finite values.
    public static func clampSidebarWidth(_ width: Double) -> Double {
        min(sidebarWidthMax, max(sidebarWidthMin, width))
    }

    /// Sets this window's sidebar width, clamped to the drag bounds, and persists it; clean no-op when the
    /// clamped value is already current. The divider DRAG does not come through here — it writes every
    /// mouse-move tick and saves once on release, so a per-tick `save()` would be the wrong trade.
    public func setSidebarWidth(_ width: Double) {
        let clamped = AppStore.clampSidebarWidth(width)
        guard sidebarWidth != clamped else { return }
        sidebarWidth = clamped
        save()
    }
}
