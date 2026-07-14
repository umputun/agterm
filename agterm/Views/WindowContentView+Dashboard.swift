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

    /// The dashboard caption pill's FILL — the theme's muted selection-background highlight (the same color
    /// the selected sidebar row draws), or a soft wash of the chrome foreground when the theme exposes no
    /// selection color. Read live from `GhosttyApp` so a theme flip (which re-renders the body via
    /// `chromeText`/`terminalColor`) re-resolves it, matching the sidebar pill — muted and themed, never the
    /// loud foreground.
    private var dashboardPillColor: Color {
        if let selection = GhosttyApp.shared.terminalSelectionBackgroundColor { return Color(nsColor: selection) }
        return chromeText.opacity(0.22)
    }

    /// The dashboard caption pill's TEXT — the theme's selection-foreground (readable over `dashboardPillColor`),
    /// else the chrome foreground.
    private var dashboardPillTextColor: Color {
        if let selection = GhosttyApp.shared.terminalSelectionForegroundColor { return Color(nsColor: selection) }
        return chromeText
    }

    /// The dashboard's title, following the normal `windowTitle` logic: just "Dashboard", plus "— <window
    /// name>" when the window carries a custom name (auto "window N" names omitted, exactly like the normal
    /// title). No cwd subtitle — the grid has no single active session to source one from.
    private var dashboardWindowTitle: String {
        guard let info = library.windows.first(where: { $0.id == windowID }), info.hasCustomName else {
            return "Dashboard"
        }
        return "Dashboard — \(info.name)"
    }

    /// The stripped chrome above the OPEN dashboard grid, the exact counterpart of `zoomTitlebar`: in
    /// hidden-toolbar mode the same invisible ~3px drag strip, otherwise a bare bar carrying the dashboard
    /// title and an exit button — none of the sidebar/split/scratch/quick-terminal/attention controls the full `customTitlebar`
    /// renders. Dropping them is the fix: while the view-only grid is up those buttons would steal the
    /// key-catcher's first responder (stranding Esc) and drive actions that make no sense behind the modal.
    /// Window drag / double-click / traffic lights stay via `WindowControlArea`; the exit button runs the
    /// same close-and-refocus path as Esc.
    @ViewBuilder var dashboardTitlebar: some View {
        if toolbarMode == .hidden {
            Color.clear
                .frame(height: 3)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .background { WindowControlArea() }
        } else {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: 78)
                    .allowsHitTesting(false)
                Text(dashboardWindowTitle)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .padding(.leading, 8)
                    // falls through to the drag/zoom layer behind the bar, like the normal title.
                    .allowsHitTesting(false)
                Spacer(minLength: 12)
                Button {
                    closeDashboardFromKeyboard()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Exit Dashboard")
                .accessibilityLabel("Exit Dashboard")
                .accessibilityIdentifier("dashboard-exit")
                .padding(.trailing, 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(chromeText)
            .imageScale(toolbarMode == .normal ? .large : .medium)
            .frame(height: titlebarHeight)
            .frame(maxWidth: .infinity)
            .background { WindowControlArea() }
        }
    }

    /// The dashboard grid overlay, mounted in `windowOverlayLayer` while this window's `DashboardController`
    /// is open (inset by `titlebarHeight`, below `customTitlebar`, like the other window overlays). Closed
    /// over its `onSelect`/`onClose` closures + the control socket; view-only cells reparent each member's
    /// OWN pane surface (`.primary` → `\.surface`, `.split` → `\.splitSurface`) via the generalized deck
    /// yield. `highlightColor` is the themed chrome foreground (the highlight ring tracks the terminal theme
    /// rather than the OS accent), and `captionBackground` is the themed terminal background (the caption
    /// chip fill), so the name chip matches the active theme too.
    @ViewBuilder var dashboardOverlay: some View {
        if dashboard.isOpen {
            DashboardView(
                controller: dashboard,
                store: store,
                makeSurface: makeSurface,
                makeSplitSurface: makeSplitSurface,
                highlightColor: chromeText,
                captionBackground: terminalColor,
                pillColor: dashboardPillColor,
                pillTextColor: dashboardPillTextColor,
                onClick: { clickDashboardMember($0) },
                onSelect: { selectDashboardMember($0) },
                onClose: { closeDashboardFromKeyboard() }
            )
        }
    }

    /// Title-bar button that opens the dashboard grid — the frontmost window's most-recently-used sessions in
    /// a view-only grid, auto-sized (the `AppActions.toggleDashboard` / ⌘⇧D / Navigate ▸ Dashboard opener). A
    /// single glyph, never a 2-state toggle: while the dashboard is open the whole titlebar is swapped for the
    /// stripped `dashboardTitlebar`, so this button only ever renders while the dashboard is closed. Disabled
    /// with no sessions (nothing to show), like the split/scratch buttons. Non-private so `titlebarRow`
    /// (in `WindowContentView`) can place it, mirroring the `+RecentSessions` buttons.
    var dashboardButton: some View {
        Button {
            actions.toggleDashboard()
        } label: {
            Label("Dashboard", systemImage: "square.split.2x2")
        }
        .help(helpHint("Dashboard", .dashboard))
        .disabled(store.activeSession == nil)
        .accessibilityIdentifier("dashboard-toggle-button")
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
            // the session switcher is app-global and renders in the FRONTMOST window (like the palette above),
            // so only that window's dashboard may cancel it — a control-driven dashboard of a background window
            // must not abort an in-progress Ctrl-Tab in the frontmost window.
            if library.activeWindowID == windowID, sessionSwitcher.isActive { sessionSwitcher.cancel() }
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
        // reconcile may have CLOSED the dashboard (its last member's session/pane vanished); the key-catcher
        // that held first responder then unmounts with nothing to re-grab it, stranding the window without
        // focus. Restore it like the Esc/Enter paths do — but ONLY for the frontmost window: this fires
        // per-window (incl. a background window on a control-driven session close) and `focusActiveSession`
        // targets the frontmost store, so an unguarded call would grab first responder in the WRONG window
        // (the same hazard the zoom-exit refocus guards against).
        if !dashboard.isOpen, library.activeWindowID == windowID { actions.focusActiveSession() }
    }

    /// Reciprocal exclusivity (folded into the body's `.onChange(of: terminalZoom.target)`): a zoom becoming
    /// active while the dashboard is open closes the dashboard — the mirror of `ControlServer.setDashboard`
    /// clearing an active zoom on open.
    func closeDashboardIfZoomActive(_ target: TerminalZoomTarget?) {
        guard target != nil, dashboard.isOpen else { return }
        dashboard.close()
    }

    /// How long the active frame flashes on a clicked cell before the click enters it — a brief, visible
    /// acknowledgement so a mouse jump doesn't feel like an instant, unexplained close.
    static let dashboardClickEnterDelay: TimeInterval = 0.18

    /// A mouse click on a cell: flash the active frame on it (`dashboard.highlight`), then enter after a brief
    /// delay — an instant jump with no frame flash reads as confusing. Keyboard Enter has no delay (its
    /// highlight is already visible). The delayed enter only fires while this cell is STILL the highlighted
    /// one, so a superseding click (or an arrow) on another cell wins — last-click, not first-scheduled — and
    /// a close/reconcile in the gap (which clears or moves the highlight) cancels the pending enter.
    func clickDashboardMember(_ member: DashboardMember) {
        dashboard.highlight(member)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dashboardClickEnterDelay) {
            guard dashboard.isOpen, dashboard.highlighted == member else { return }
            selectDashboardMember(member)
        }
    }

    /// Enter (immediately), or a mouse click (after its flash delay), enters a cell: select that session,
    /// close the dashboard, then land first responder in the cell's EXACT pane — the split (right) pane for a `.split` cell (mirroring
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
