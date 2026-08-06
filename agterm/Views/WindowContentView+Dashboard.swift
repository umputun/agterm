import agtermCore
import AppKit
import SwiftUI

/// The font-relevant dashboard state: the pane-cell member set AND the font mode, since SwiftUI suppresses
/// `.onChange` on an Equatable-equal key and members alone would miss a same-members re-open in a DIFFERENT
/// mode. Members are explicit `(session, pane)` cells, so a slot change already changes the set.
struct DashboardFontKey: Equatable {
    let members: [DashboardMember]
    let mode: DashboardFontMode
}

extension WindowContentView {
    /// The composite key the font apply reacts to (see `DashboardFontKey`).
    var dashboardFontKey: DashboardFontKey {
        DashboardFontKey(members: dashboard.members, mode: dashboard.fontMode)
    }

    /// Every valid pane cell in this window's store, in tree order. The reconcile key: closing a member
    /// session or a split pane while the dashboard is open changes it, and `reconcileDashboardMembers`
    /// prunes the gone cells.
    var dashboardValidMembers: [DashboardMember] {
        store.workspaces.flatMap(\.sessions).flatMap { session -> [DashboardMember] in
            var members = [DashboardMember(session: session.id, surface: .primary)]
            if session.hasSplit { members.append(DashboardMember(session: session.id, surface: .split)) }
            return members
        }
    }

    /// The caption pill's FILL — the theme's muted selection background (what the selected sidebar row
    /// draws), or a soft wash of the chrome foreground when none. Read live so a theme flip re-resolves it.
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

    /// "Dashboard", plus "— <window name>" for a custom window name (auto "window N" omitted, like the
    /// normal `windowTitle`). No cwd subtitle — the grid has no single active session to source one from.
    private var dashboardWindowTitle: String {
        guard let info = library.windows.first(where: { $0.id == windowID }), info.hasCustomName else {
            return "Dashboard"
        }
        return "Dashboard — \(info.name)"
    }

    /// The stripped chrome above the OPEN grid, the counterpart of `zoomTitlebar`: in hidden-toolbar mode
    /// the same invisible ~3px drag strip, else a bare bar with the title and an exit button. None of
    /// `customTitlebar`'s controls: behind the view-only grid they would steal the key-catcher's first
    /// responder (stranding Esc) and drive actions that make no sense. Window drag / double-click / traffic
    /// lights stay via `WindowControlArea`.
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

    /// The grid overlay, mounted in `windowOverlayLayer` while this window's `DashboardController` is open
    /// (inset by `titlebarHeight`, below `customTitlebar`, like the other window overlays). View-only cells
    /// reparent each member's OWN pane surface via the generalized deck yield.
    /// `highlightColor`/`captionBackground` are themed, so the ring and caption chip track the terminal
    /// theme rather than the OS accent.
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
                focusAllowed: pick.pending == nil,
                showsTopHairline: toolbarMode != .hidden,
                onClick: { clickDashboardMember($0) },
                onSelect: { selectDashboardMember($0) },
                onClose: { closeDashboardFromKeyboard() }
            )
        }
    }

    /// Title-bar opener for the view-only grid — the frontmost window's most-recently-used sessions,
    /// auto-sized (the `AppActions.toggleDashboard` / ⌘⇧D / Navigate ▸ Dashboard path). A single glyph,
    /// never a 2-state toggle: an open dashboard swaps the whole titlebar for `dashboardTitlebar`, so this
    /// renders only while closed. Disabled with no sessions; non-private so `titlebarRow` can place it.
    var dashboardButton: some View {
        Button {
            actions.toggleDashboard()
        } label: {
            Label("Dashboard", systemImage: "rectangle.split.2x2")
        }
        .help(helpHint("Dashboard", .dashboard))
        .disabled(store.activeSession == nil)
        .accessibilityIdentifier("dashboard-toggle-button")
    }

    /// Whether an OPEN dashboard hosts this session-pane slot in a grid cell. BOTH panes of a split member
    /// are claimed and the deck must yield its `Color.clear` placeholder for each — an NSView lives in one
    /// host at a time, the zoom exclusion generalized to N panes. False for a non-member slot, for a
    /// member's scratch/overlay surfaces, and while closed.
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

    /// The `.onChange(of: dashboard.isOpen)` transition: entering closes this window's transient chrome and
    /// pauses auto-follow (mirroring `handleZoomTargetChange`), exiting resumes it. The per-member font
    /// override rides `dashboardFontKey` instead.
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
            // the switcher is app-global and frontmost-rendered like the palette, same background-window guard.
            if library.activeWindowID == windowID, sessionSwitcher.isActive { sessionSwitcher.cancel() }
            // pause this window's idle auto-follow so an armed jump can't reshuffle the selection under the modal.
            store.suppressAutoFollow()
        } else {
            store.resumeAutoFollow()
        }
    }

    /// The `.onChange(of: dashboardFontKey)` apply: clear every prior override, re-apply the mode to each
    /// current pane cell's OWN surface, and record the applied size on the controller. Fires on open,
    /// retarget, mode change, member add/remove and close, so no de-membered surface keeps a stale font.
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

    /// The `.onChange(of: dashboardValidMembers)` hook: drops any pane cell whose session or split pane
    /// closed, so the grid recomputes to the smaller count and the highlight never points at a gone pane.
    /// `DashboardController.reconcile` closes the dashboard once the last member is gone.
    func reconcileDashboardMembers() {
        guard dashboard.isOpen else { return }
        dashboard.reconcile(existing: Set(dashboardValidMembers))
        // a reconcile-driven close unmounts the key-catcher that held first responder with nothing to
        // re-grab it, so restore focus like Esc/Enter — but ONLY for the frontmost window: this fires
        // per-window while `focusActiveSession` targets the frontmost store, so an unguarded call would
        // grab first responder in the WRONG window.
        if !dashboard.isOpen, library.activeWindowID == windowID { actions.focusActiveSession() }
    }

    /// Reciprocal exclusivity (in the body's `.onChange(of: terminalZoom.target)`): a zoom becoming active
    /// closes an open dashboard — the mirror of `ControlServer.setDashboard` clearing a zoom on open.
    func closeDashboardIfZoomActive(_ target: TerminalZoomTarget?) {
        guard target != nil, dashboard.isOpen else { return }
        dashboard.close()
    }

    /// How long the active frame flashes on a clicked cell before the click enters it, so a mouse jump
    /// doesn't read as an instant, unexplained close.
    static let dashboardClickEnterDelay: TimeInterval = 0.18

    /// A click flashes the active frame on the cell, then enters after a brief delay — an instant jump with
    /// no flash reads as confusing (keyboard Enter needs none, its highlight is already visible). The
    /// delayed enter fires only while this cell is STILL highlighted, so a superseding click or arrow wins
    /// (last-click, not first-scheduled) and a close/reconcile in the gap cancels it.
    func clickDashboardMember(_ member: DashboardMember) {
        dashboard.highlight(member)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dashboardClickEnterDelay) {
            guard dashboard.isOpen, dashboard.highlighted == member else { return }
            selectDashboardMember(member)
        }
    }

    /// Entering a cell (Enter immediately, a click after its flash delay): select that session, close the
    /// dashboard, then land first responder in the cell's EXACT pane, the `.split` leg mirroring
    /// `revealActiveBlockedPane`'s `.right` branch. Close BEFORE focusing or the
    /// `focusSplitPane`/`focusActiveSession` `dashboardActive` guards block it.
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

    /// The absolute size for every member surface in the current mode, or nil for `.untouched` (each keeps
    /// its own `session.fontSize`). Resolves through the SAME host-free `DashboardFontMode.appliedFontSize`
    /// seam `ControlServer.setDashboard` uses, so the surface overrides and the controller's read-back land
    /// on the identical value. `.auto` derives it from the grid and the Settings font size (nil → ghostty's).
    private func dashboardTargetFontSize(memberCount: Int) -> Double? {
        let base = actions.settingsModel?.settings.fontSize ?? DashboardLayout.ghosttyDefaultFontSize
        return dashboard.fontMode.appliedFontSize(memberCount: memberCount, base: base)
    }

    /// Clear the transient dashboard font override wherever one is set, restoring each surface's real
    /// (session-model) font. Sweeps store-wide rather than over `dashboard.members`, so it stays correct on
    /// close (members already emptied) and on window teardown.
    private func clearDashboardFontOverrides() {
        for session in store.workspaces.flatMap(\.sessions) {
            for surface in [session.surface, session.splitSurface] {
                guard let view = surface as? GhosttySurfaceView, view.dashboardFontOverride != nil else { continue }
                view.dashboardFontOverride = nil
            }
        }
    }

    /// The cell's OWN pane surface as a `GhosttySurfaceView`, for the font override — the SAME slot the
    /// dashboard cell reparents.
    private func dashboardMemberSurface(_ member: DashboardMember) -> GhosttySurfaceView? {
        guard let session = store.session(withID: member.session) else { return nil }
        let surface = member.surface == .split ? session.splitSurface : session.surface
        return surface as? GhosttySurfaceView
    }
}
