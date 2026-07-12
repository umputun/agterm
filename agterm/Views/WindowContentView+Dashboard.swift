import agtermCore
import AppKit
import SwiftUI

/// The font-relevant dashboard state — the member set AND the font mode. A change to EITHER re-applies the
/// per-member override, so a same-members re-open with a DIFFERENT font mode (`dashboard A B` then
/// `dashboard A B --font-size 20`) still re-sizes; keying the apply off `members` alone missed it, because
/// SwiftUI suppresses `.onChange(of: members)` when the array is Equatable-equal.
struct DashboardFontKey: Equatable {
    let members: [UUID]
    let mode: DashboardFontMode
}

extension WindowContentView {
    /// The composite key the font apply reacts to (see `DashboardFontKey`).
    var dashboardFontKey: DashboardFontKey {
        DashboardFontKey(members: dashboard.members, mode: dashboard.fontMode)
    }

    /// Every session id currently in this window's store, in tree order — the reconcile key: when a member
    /// session is closed while the dashboard is open (e.g. over the control socket), this array changes and
    /// `reconcileDashboardMembers` prunes the gone member.
    var dashboardSessionIDs: [UUID] {
        store.workspaces.flatMap { $0.sessions.map(\.id) }
    }

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
    /// auto-follow. The per-member font override is driven separately off `dashboardFontKey` so a retarget
    /// (re-open with a new set) OR a same-members re-open with a new font mode re-applies it.
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

    /// The font-key change (the body's `.onChange(of: dashboardFontKey)`): clears every prior override, then
    /// re-applies the font mode to the current members and records the applied size on the controller. Fires
    /// on open ([] → members), retarget (members → new set), a same-members font-mode change, and close
    /// (members → []), so a de-membered surface never keeps a stale shrunk font and a re-open always re-sizes.
    func handleDashboardFontChange() {
        clearDashboardFontOverrides()
        guard dashboard.isOpen else {
            dashboard.setAppliedFontSize(nil)
            return
        }
        let target = dashboardTargetFontSize(memberCount: dashboard.members.count)
        dashboard.setAppliedFontSize(target)
        guard let target else { return } // .untouched: leave each surface at its own session.fontSize
        for id in dashboard.members {
            dashboardMemberSurface(id)?.dashboardFontOverride = target
        }
    }

    /// The reconcile hook (the body's `.onChange(of: dashboardSessionIDs)`): drops any member whose session
    /// was closed while the dashboard is open (e.g. over the control socket), so the grid recomputes to the
    /// smaller count and the highlight never points at a gone session. A no-op while closed or when no member
    /// vanished; `DashboardController.reconcile` closes the dashboard when the last member is gone.
    func reconcileDashboardMembers() {
        guard dashboard.isOpen else { return }
        dashboard.reconcile(existing: Set(dashboardSessionIDs))
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
            let base = actions.settingsModel?.settings.fontSize ?? DashboardLayout.ghosttyDefaultFontSize
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
