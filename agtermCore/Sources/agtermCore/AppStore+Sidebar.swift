import Foundation

/// Sidebar divider geometry: the shared width clamp and the persisting setter behind `sidebar.width`.
/// Visibility and view mode stay in `AppStore.swift` beside the rest of the per-window sidebar state.
public extension AppStore {
    /// Clamp a sidebar width to `sidebarWidthMin...sidebarWidthMax`. Callers pass finite values only —
    /// `sidebar.width` rejects a non-finite argument at the dispatcher, and the drag passes a cursor x.
    static func clampSidebarWidth(_ width: Double) -> Double {
        min(sidebarWidthMax, max(sidebarWidthMin, width))
    }

    /// Sets this window's sidebar width, clamped to the drag bounds, and persists it; clean no-op when the
    /// clamped value is already current. The divider DRAG does not come through here — it writes every
    /// mouse-move tick and saves once on release, so a per-tick `save()` would be the wrong trade.
    func setSidebarWidth(_ width: Double) {
        let clamped = AppStore.clampSidebarWidth(width)
        guard sidebarWidth != clamped else { return }
        sidebarWidth = clamped
        save()
    }
}
