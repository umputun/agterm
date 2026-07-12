import agtermCore
import AppKit
import SwiftUI

extension WindowContentView {
    /// libghostty's built-in terminal font size (points), used as the base for `.auto` sizing when the user
    /// has not set an explicit Settings font size (`AppSettings.fontSize == nil`). agterm has no constant for
    /// it, so this mirrors ghostty's default.
    private var ghosttyDefaultFontSize: Double { 13 }

    /// The dashboard grid overlay, mounted in `windowOverlayLayer` while this window's `DashboardController`
    /// is open (inset by `titlebarHeight`, below `customTitlebar`, like the other window overlays). Closed
    /// over its `onSelect`/`onClose` closures + the control socket; view-only cells reparent each member's
    /// resolved `addressableSurface` via the generalized deck yield.
    @ViewBuilder var dashboardOverlay: some View {
        if dashboard.isOpen {
            DashboardView(
                controller: dashboard,
                store: store,
                makeSurface: makeSurface,
                makeSplitSurface: makeSplitSurface,
                onHighlight: { dashboard.highlight($0) },
                onSelect: { selectDashboardMember($0) },
                onClose: { closeDashboardFromKeyboard() }
            )
        }
    }

    /// Whether an OPEN dashboard hosts this session-surface slot in a grid cell. The dashboard reparents each
    /// member's `addressableSurface` — `.primary` when the primary shell is live, else `.split` for a promoted
    /// survivor — so that one slot's deck entry must yield the `Color.clear` placeholder (an NSView lives in
    /// one host at a time), exactly like the zoom exclusion. False for every non-member slot, for a member's
    /// scratch/overlay surfaces (the dashboard never hosts those), and while the dashboard is closed.
    func dashboardHostsSurface(session: Session, surface: TerminalZoomSurface) -> Bool {
        guard dashboard.isOpen, dashboard.members.contains(session.id) else { return false }
        let hosted: TerminalZoomSurface = session.surface != nil ? .primary : .split
        return surface == hosted
    }

    /// Register this window's `DashboardController` so the control socket can drive it (called from `onAppear`).
    func registerDashboard() {
        DashboardControllerRegistry.shared.register(windowID, controller: dashboard)
    }

    /// Restore any active font override BEFORE unregistering, so closing the window never strands a shrunk
    /// dashboard font on a surface (called from `onDisappear`).
    func tearDownDashboard() {
        clearDashboardFontOverrides()
        DashboardControllerRegistry.shared.unregister(windowID)
    }

    /// The dashboard-open transition (the body's `.onChange(of: dashboard.isOpen)`): entering closes this
    /// window's transient chrome and pauses auto-follow (mirrors `handleZoomTargetChange`); exiting resumes
    /// auto-follow. The per-member font override is driven separately off `dashboard.members` so a retarget
    /// (re-open with a new set) re-applies it.
    func handleDashboardOpenChange(_ isOpen: Bool) {
        if isOpen {
            // the palette is app-global and renders in the FRONTMOST window, so only that window's dashboard
            // may close it — a control-driven dashboard of a background window must not kill the user's palette.
            if library.activeWindowID == windowID { palette.close() }
            // end an open ⌘F search (otherwise libghostty stays in search mode with stale highlights and no bar).
            if let session = store.activeSession, session.searchActive {
                (session.searchSurface as? GhosttySurfaceView)?.endSearch()
            }
            if quickTerminal.isVisible { quickTerminal.hide() }
            if sessionSwitcher.isActive { sessionSwitcher.cancel() }
            // pause this window's idle auto-follow so an armed jump can't reshuffle the selection under the modal.
            store.suppressAutoFollow()
        } else {
            store.resumeAutoFollow()
        }
    }

    /// The member-set change (the body's `.onChange(of: dashboard.members)`): clears every prior override,
    /// then re-applies the font mode to the current members and records the applied size on the controller.
    /// Fires on open ([] → members), retarget (members → new set), and close (members → []), so a de-membered
    /// surface never keeps a stale shrunk font and a retarget re-sizes.
    func handleDashboardMembersChange() {
        clearDashboardFontOverrides()
        guard dashboard.isOpen else {
            dashboard.appliedFontSize = nil
            return
        }
        let target = dashboardTargetFontSize(memberCount: dashboard.members.count)
        dashboard.appliedFontSize = target
        guard let target else { return } // .untouched: leave each surface at its own session.fontSize
        for id in dashboard.members {
            dashboardMemberSurface(id)?.dashboardFontOverride = target
        }
    }

    /// Reciprocal exclusivity (folded into the body's `.onChange(of: terminalZoom.target)`): a zoom becoming
    /// active while the dashboard is open closes the dashboard — the mirror of `ControlServer.setDashboard`
    /// clearing an active zoom on open.
    func closeDashboardIfZoomActive(_ target: TerminalZoomTarget?) {
        guard target != nil, dashboard.isOpen else { return }
        dashboard.close()
    }

    /// Enter (or a double-click) on the highlighted cell: select that session, close the dashboard, then land
    /// first responder in it.
    func selectDashboardMember(_ id: UUID) {
        store.selectSession(id)
        dashboard.close()
        actions.focusActiveSession()
    }

    /// Esc: close the dashboard and restore first responder to the still-selected (previously active) session.
    func closeDashboardFromKeyboard() {
        dashboard.close()
        actions.focusActiveSession()
    }

    /// The absolute font size to apply to every member surface for the current mode, or nil for `.untouched`
    /// (leave each surface at its own `session.fontSize`). `.auto` derives it from the grid via
    /// `DashboardLayout.dashboardFontSize`, based on the Settings font size (nil → the ghostty default).
    private func dashboardTargetFontSize(memberCount: Int) -> Double? {
        switch dashboard.fontMode {
        case .untouched:
            return nil
        case let .fixed(value):
            return value
        case .auto:
            let (cols, rows) = DashboardLayout.grid(count: memberCount)
            let base = actions.settingsModel?.settings.fontSize ?? ghosttyDefaultFontSize
            return DashboardLayout.dashboardFontSize(cols: cols, rows: rows, base: base)
        }
    }

    /// Clear the transient dashboard font override on every surface that currently carries one, restoring its
    /// real (session-model) font. A store-wide sweep rather than iterating `dashboard.members`, so it stays
    /// correct on close (members already emptied) and on window teardown; only touches surfaces with an active
    /// override, so a plain surface isn't needlessly re-configured.
    private func clearDashboardFontOverrides() {
        for session in store.workspaces.flatMap(\.sessions) {
            guard let surface = session.addressableSurface as? GhosttySurfaceView,
                  surface.dashboardFontOverride != nil else { continue }
            surface.dashboardFontOverride = nil
        }
    }

    /// The member's hosted surface — `addressableSurface` (`surface ?? splitSurface`), the SAME slot the
    /// dashboard cell reparents — as a `GhosttySurfaceView`, for the font override.
    private func dashboardMemberSurface(_ id: UUID) -> GhosttySurfaceView? {
        store.session(withID: id)?.addressableSurface as? GhosttySurfaceView
    }
}
