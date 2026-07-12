import agtermCore
import AppKit
import SwiftUI

/// The font-relevant dashboard state — the pane-cell member set AND the font mode. A change to either
/// re-applies the per-cell font override. The members-only key would miss (SwiftUI suppresses `.onChange`
/// when the whole key is Equatable-equal) a same-members re-open with a DIFFERENT font mode
/// (`dashboard A B` then `dashboard A B --font-size 20`), so the mode rides the key too. Each member is now
/// an explicit `(session, pane)` cell, so a member-set change already captures any slot change — no separate
/// `kinds` term is needed.
struct DashboardFontKey: Equatable {
    let members: [DashboardMember]
    let mode: DashboardFontMode
}

extension WindowContentView {
    /// The composite key the font apply reacts to (see `DashboardFontKey`): the pane-cell member set plus the
    /// font mode, so a retarget, a same-members mode change, or a member add/remove re-applies the override.
    var dashboardFontKey: DashboardFontKey {
        DashboardFontKey(members: dashboard.members, mode: dashboard.fontMode)
    }

    /// Every VALID pane cell currently in this window's store, in tree order — each session contributes its
    /// `.primary` cell plus a `.split` cell when it `hasSplit`. The reconcile key: when a member session is
    /// closed OR a split pane closes while the dashboard is open (e.g. over the control socket), this array
    /// changes and `reconcileDashboardMembers` prunes the gone cell(s).
    var dashboardValidMembers: [DashboardMember] {
        store.workspaces.flatMap(\.sessions).flatMap { session -> [DashboardMember] in
            var members = [DashboardMember(session: session.id, surface: .primary)]
            if session.hasSplit { members.append(DashboardMember(session: session.id, surface: .split)) }
            return members
        }
    }

    /// The dashboard grid overlay, mounted in `windowOverlayLayer` while this window's `DashboardController`
    /// is open (inset by `titlebarHeight`, below `customTitlebar`, like the other window overlays). Closed
    /// over its `onSelect`/`onClose` closures + the control socket; view-only cells reparent each member's
    /// OWN pane surface (`.primary` → `\.surface`, `.split` → `\.splitSurface`) via the generalized deck
    /// yield. `highlightColor` is the themed chrome foreground, so the highlight ring tracks the terminal
    /// theme rather than the OS accent.
    @ViewBuilder var dashboardOverlay: some View {
        if dashboard.isOpen {
            DashboardView(
                controller: dashboard,
                store: store,
                makeSurface: makeSurface,
                makeSplitSurface: makeSplitSurface,
                highlightColor: chromeText,
                onHighlight: { dashboard.highlight($0) },
                onSelect: { selectDashboardMember($0) },
                onClose: { closeDashboardFromKeyboard() }
            )
        }
    }

    /// Whether an OPEN dashboard hosts this session-pane slot in a grid cell. A member is now an explicit
    /// `(session, pane)` cell, so BOTH panes of a split member are claimed (each hosts its own surface) — the
    /// deck must yield the `Color.clear` placeholder for every claimed slot (an NSView lives in one host at a
    /// time), exactly like the zoom exclusion, but generalized to N panes. False for every non-member slot,
    /// for a member's scratch/overlay surfaces (the dashboard never hosts those), and while the dashboard is
    /// closed.
    func dashboardHostsSurface(session: Session, surface: TerminalZoomSurface) -> Bool {
        guard dashboard.isOpen else { return false }
        return dashboard.members.contains(DashboardMember(session: session.id, surface: surface))
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
    /// re-applies the font mode to the current pane cells and records the applied size on the controller.
    /// Fires on open ([] → members), retarget (members → new set), a same-members font-mode change, a
    /// member add/remove, and close (members → []), so a de-membered surface never keeps a stale shrunk font
    /// and a re-open always re-sizes. Each cell's OWN pane surface (`.primary` → `\.surface`, `.split` →
    /// `\.splitSurface`) gets the override.
    func handleDashboardFontChange() {
        clearDashboardFontOverrides()
        guard dashboard.isOpen else {
            dashboard.setAppliedFontSize(nil)
            return
        }
        let target = dashboardTargetFontSize(memberCount: dashboard.members.count)
        dashboard.setAppliedFontSize(target)
        guard let target else { return } // .untouched: leave each surface at its own session.fontSize
        for member in dashboard.members {
            dashboardMemberSurface(member)?.dashboardFontOverride = target
        }
    }

    /// The reconcile hook (the body's `.onChange(of: dashboardValidMembers)`): drops any pane cell whose
    /// session was closed OR whose split pane closed while the dashboard is open (e.g. over the control
    /// socket), so the grid recomputes to the smaller count and the highlight never points at a gone pane. A
    /// no-op while closed or when no member vanished; `DashboardController.reconcile` closes the dashboard
    /// when the last member is gone.
    func reconcileDashboardMembers() {
        guard dashboard.isOpen else { return }
        dashboard.reconcile(existing: Set(dashboardValidMembers))
    }

    /// Reciprocal exclusivity (folded into the body's `.onChange(of: terminalZoom.target)`): a zoom becoming
    /// active while the dashboard is open closes the dashboard — the mirror of `ControlServer.setDashboard`
    /// clearing an active zoom on open.
    func closeDashboardIfZoomActive(_ target: TerminalZoomTarget?) {
        guard target != nil, dashboard.isOpen else { return }
        dashboard.close()
    }

    /// Enter (or a double-click) on the highlighted cell: select that session, close the dashboard, then land
    /// first responder in the cell's EXACT pane — the split (right) pane for a `.split` cell (mirroring
    /// `revealActiveBlockedPane`'s `.right` branch: flip `splitFocused`, then `focusSplitPane(wantSplit:true)`),
    /// else the main pane. Close BEFORE focusing so the `focusSplitPane`/`focusActiveSession` `dashboardActive`
    /// guards (the window's controller `isOpen`) don't block the focus.
    func selectDashboardMember(_ member: DashboardMember) {
        store.selectSession(member.session)
        dashboard.close()
        guard let session = store.session(withID: member.session) else {
            actions.focusActiveSession()
            return
        }
        if member.surface == .split, session.splitSurface != nil {
            session.splitFocused = true
            actions.focusSplitPane(session, wantSplit: true)
        } else {
            session.splitFocused = false
            actions.focusActiveSession()
        }
    }

    /// Esc: close the dashboard and restore first responder to the still-selected (previously active) session.
    func closeDashboardFromKeyboard() {
        dashboard.close()
        actions.focusActiveSession()
    }

    /// The absolute font size to apply to every member surface for the current mode, or nil for `.untouched`
    /// (leave each surface at its own `session.fontSize`). Resolves through the SAME host-free
    /// `DashboardFontMode.appliedFontSize` seam `ControlServer.setDashboard` uses, so the surface overrides
    /// and the controller's synchronous read-back land on the identical value (the onChange re-apply is a
    /// no-op re-write). `.auto` derives it from the grid, based on the Settings font size (nil → the ghostty
    /// default).
    private func dashboardTargetFontSize(memberCount: Int) -> Double? {
        let base = actions.settingsModel?.settings.fontSize ?? DashboardLayout.ghosttyDefaultFontSize
        return dashboard.fontMode.appliedFontSize(memberCount: memberCount, base: base)
    }

    /// Clear the transient dashboard font override on every surface that currently carries one, restoring its
    /// real (session-model) font. Sweeps BOTH `\.surface` AND `\.splitSurface` of every session, since a split
    /// member now carries the override on its OWN pane surface (both panes can carry one). A store-wide sweep
    /// rather than iterating `dashboard.members`, so it stays correct on close (members already emptied) and
    /// on window teardown; only touches surfaces with an active override, so a plain surface isn't needlessly
    /// re-configured.
    private func clearDashboardFontOverrides() {
        for session in store.workspaces.flatMap(\.sessions) {
            for surface in [session.surface, session.splitSurface] {
                guard let view = surface as? GhosttySurfaceView, view.dashboardFontOverride != nil else { continue }
                view.dashboardFontOverride = nil
            }
        }
    }

    /// The cell's OWN pane surface as a `GhosttySurfaceView`, for the font override: `.split` → the session's
    /// `splitSurface`, else its `surface` — the SAME slot the dashboard cell reparents.
    private func dashboardMemberSurface(_ member: DashboardMember) -> GhosttySurfaceView? {
        guard let session = store.session(withID: member.session) else { return nil }
        let surface = member.surface == .split ? session.splitSurface : session.surface
        return surface as? GhosttySurfaceView
    }
}
