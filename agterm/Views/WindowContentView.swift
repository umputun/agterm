import agtermCore
import AppKit
import SwiftUI

/// Window-local handoff between picker dismissal and the owning window becoming frontmost: a background
/// window must not claim first responder, yet its removed picker field cannot stay the responder later.
struct PickFocusRestorationState {
    private(set) var isDeferred = false

    mutating func pickerResolved(isFrontmost: Bool) -> Bool {
        isDeferred = !isFrontmost
        return isFrontmost
    }

    mutating func windowBecameFrontmost(pickPending: Bool) -> Bool {
        guard isDeferred, !pickPending else { return false }
        isDeferred = false
        return true
    }
}

/// The per-window UI: the workspace/session sidebar + the active session's terminal, plus the
/// quick-terminal / palette / switcher overlays. `ContentView` resolves the store and hands in the
/// non-optional `AppStore` the binding-based wiring needs.
struct WindowContentView: View {
    let windowID: WindowInfo.ID
    @Bindable var store: AppStore
    let library: WindowLibrary
    let makeSurface: (Session) -> GhosttySurfaceView
    let makeSplitSurface: (Session) -> GhosttySurfaceView
    let makeOverlaySurface: (Session) -> GhosttySurfaceView
    let makeScratchSurface: (Session) -> GhosttySurfaceView
    let quickTerminalEnv: (WindowInfo.ID) -> [String: String]
    let actions: AppActions
    let palette: PaletteController
    let sessionSwitcher: SessionSwitcher
    /// This window's own quick terminal (one per window). Registered in `QuickTerminalRegistry` on appear
    /// so the frontmost-window call sites reach it; its `cwdProvider` binds to this window's active session.
    @State var quickTerminal = QuickTerminalController()
    /// Window-level terminal zoom: rehosts the currently visible terminal surface above the sidebar,
    /// titlebar, quick terminal frame, palettes, and switcher until the toggle is invoked again.
    @State var terminalZoom = TerminalZoomController()
    /// Window-level dashboard grid overlay: reparents a control-picked set of member session surfaces into a
    /// view-only grid. Registered in `DashboardControllerRegistry` on appear so the socket can drive it; the
    /// `+Dashboard` extension owns the overlay branch, deck yield, font override, and modal lifecycle.
    @State var dashboard = DashboardController()
    /// Per-window native picker presented through the shared palette view. Registered for control-socket
    /// lookup while this window is mounted; unlike `palette`, its pending state is window-scoped.
    @State var pick = PickController()
    /// Tracks this view's balanced auto-follow suppression so window teardown can release it even when
    /// SwiftUI removes the observer before the pick controller publishes its cancellation.
    @State private var pickSuppressesAutoFollow = false
    /// Defers picker focus restoration when a control request resolves in a background window. The
    /// always-mounted frontmost observer consumes it without activating or ordering that window.
    @State private var pickFocusRestoration = PickFocusRestorationState()
    /// The terminal background color, mirrored from the non-observable `GhosttyApp` and used as the quick
    /// terminal's opaque backing; `.agtermAppearanceChanged` re-renders it live on a settings theme change.
    @State var terminalColor: Color = WindowContentView.resolvedTerminalColor()
    /// Mirror of `GhosttyApp.toolbarMode`: `normal` shows the cwd subtitle, `compact` collapses the title bar
    /// to a single line, `hidden` drops the row (and the traffic lights) for a full-bleed terminal. Refreshed
    /// on `.agtermAppearanceChanged`, like every mirror below.
    @State var toolbarMode: ToolbarMode = WindowContentView.resolvedToolbarMode()
    /// Mirror of `GhosttyApp.inactivePaneMuteStrength` (0...10): how strongly `paneDim` mutes the inactive
    /// split pane's text.
    @State private var inactivePaneMute: Int = WindowContentView.resolvedInactivePaneMute()
    /// Mirror of `GhosttyApp.sidebarBackgroundShift` (0...10, 5 = neutral): how much lighter/darker the
    /// sidebar background is than the terminal. Drives `sidebarTintWash`.
    @State var sidebarShift: Int = WindowContentView.resolvedSidebarShift()
    /// The terminal theme's foreground, mirrored from `GhosttyApp` for the chrome text (title bar text +
    /// buttons, sidebar bottom bar) so non-terminal text tracks the theme.
    @State var chromeText: Color = WindowContentView.resolvedChromeText()
    /// Mirror of `GhosttyApp.attentionButtonEnabled`: when true the title bar shows the attention bell, so
    /// flipping the Settings toggle shows/hides it live without a relaunch.
    @State var attentionButtonEnabled: Bool = WindowContentView.resolvedAttentionButtonEnabled()
    /// Mirror of `GhosttyApp.hiddenInterfaceElements`: the title-bar / sidebar-footer chrome the user hid in
    /// Settings ▸ Interface, read by `shows(_:)`; a toggle flip applies live without a relaunch.
    @State var hiddenInterfaceElements: Set<InterfaceElement> = WindowContentView.resolvedHiddenInterfaceElements()
    /// Whether the recent-sessions popover (the mouse form of the Ctrl-Tab switcher) is shown, anchored on
    /// the title-bar clock button. Non-private so `+RecentSessions`'s button/rows can toggle it.
    @State var recentSessionsShown = false
    /// Whether the attention popover (the mouse equivalent of the ⌃⇧I attention palette) is shown, anchored
    /// on the title-bar bell. Non-private so the `+RecentSessions` extension's bell/rows can toggle it.
    @State var attentionPopoverShown = false
    /// Custom sidebar width and show/hide live on the per-window `AppStore` (`sidebarWidth` /
    /// `sidebarVisible`), persisted in `Snapshot`; the toolbar button, View menu, palette, and the
    /// `sidebar` control command share `sidebarVisible`.
    /// Height of the custom titlebar row: two lines (title + cwd) normal, one short line compact, zero
    /// hidden (an invisible drag strip, terminal full-bleed). The split content is inset by this.
    var titlebarHeight: CGFloat {
        switch toolbarMode {
        case .normal: return 48
        case .compact: return 30
        case .hidden: return 0
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // the AppKit HSplitView can overrun into the titlebar zone and steal header clicks, so the deck
            // stays inset below it. Kept mounted while zoomed (the zoom layer owns the visible window) so
            // background sessions and control-opened overlays still realize their surfaces and run.
            alwaysMountedSplitLayer
            if let zoomTarget = terminalZoom.target {
                terminalZoomLayer(zoomTarget)
                    .zIndex(10)
                zoomTitlebar
                    .zIndex(11)
            } else {
                // the window overlays (quick terminal / palettes / switcher) sit BELOW the titlebar, inset by
                // its height — NOT a body-level `.overlay` above everything: a full-window overlay's dim scrim
                // would composite over the transparent custom titlebar (backing deliberately hidden for
                // translucency, WindowAppearance) and darken + seam the non-compact one. Keeping the titlebar
                // at the highest zIndex means a scrim can never cover it.
                windowOverlayLayer
                    .padding(.top, titlebarHeight)
                    .zIndex(1)
                if dashboard.isOpen {
                    // the open dashboard is a view-only modal like zoom: a stripped bar (mirroring
                    // zoomTitlebar) so titlebar buttons can't steal the key-catcher's first responder — which
                    // strands Esc — or drive actions meaningless behind the grid. The two modes are exclusive.
                    dashboardTitlebar
                        .zIndex(2)
                } else {
                    customTitlebar
                        .zIndex(2)
                }
            }
            // A control picker is the window's topmost modal. It must stay visible and interactive even
            // when terminal zoom or the dashboard was already active when the request arrived.
            pickPaletteOverlay
                .padding(.top, titlebarHeight)
                .zIndex(20)
        }
        // with the title bar hidden (.hiddenTitleBar), pull our header to the very top so the traffic
        // lights overlay it as one row; no system title bar is left to clip the content.
        .ignoresSafeArea(.container, edges: .top)
        // re-tint the sidebar after a collapse/expand: the re-attached NSScrollView comes back with a
        // default (lighter) background until the next WindowAppearance sync; nudge that sync now.
        .onChange(of: store.sidebarVisible) { _, visible in
            if visible {
                DispatchQueue.main.async { NotificationCenter.default.post(name: .agtermAppearanceChanged, object: nil) }
            }
        }
        // when the quick terminal hides, return focus to the active session's terminal — unless THIS
        // window's zoom owns focus (zoom-enter hides the quick terminal itself, and `actions` targets
        // the FRONTMOST window, so a background window's zoom-driven hide must not move focus there).
        .onChange(of: quickTerminal.isVisible) { _, visible in
            if !visible, terminalZoom.target == .quick { terminalZoom.clear() }
            if !visible, terminalZoom.target == nil { actions.focusActiveSession() }
        }
        .onChange(of: terminalZoom.target) { old, new in
            handleZoomTargetChange(old: old, new: new)
            closeDashboardIfZoomActive(new)
        }
        // dashboard open/close drives the modal lifecycle + auto-follow pause; the font key (members + font
        // mode) drives the per-member transient font override, so a retarget OR a same-members re-open with a
        // new font mode re-sizes; the session-id set drives member reconcile (prune a closed member).
        .onChange(of: dashboard.isOpen) { _, isOpen in
            handleDashboardOpenChange(isOpen)
        }
        .onChange(of: dashboardFontKey) { _, _ in
            handleDashboardFontChange()
        }
        .onChange(of: dashboardValidMembers) { _, _ in
            reconcileDashboardMembers()
        }
        // Editor-overlay reload hooks must stay mounted while terminal zoom replaces the normal deck.
        .onChange(of: openOverlaySessionIDs) { old, new in
            handleClosedEditorOverlays(previousOpenOverlaySessionIDs: old, currentOpenOverlaySessionIDs: new)
        }
        // a palette is a transient overlay that owns the keyboard: suppress this window's auto-follow while
        // it is open so an armed idle jump can't reshuffle the selection under it (an action-palette run
        // would then hit the wrong session), and resume + return focus to the terminal when it closes.
        .onChange(of: palette.mode == nil) { _, closed in
            if closed {
                store.resumeAutoFollow()
                actions.focusActiveSession()
            } else {
                store.suppressAutoFollow()
            }
        }
        // A native picker owns keyboard focus just like a built-in palette. Pair auto-follow suppression
        // per window, then return first responder to this window's terminal after every resolution path.
        .onChange(of: pick.pending?.id) { old, new in
            if old == nil, new != nil, !pickSuppressesAutoFollow {
                // A socket-driven picker may arrive while either title-bar popover is already open.
                // Dismiss both immediately so no second interactive surface remains above the modal picker.
                recentSessionsShown = false
                attentionPopoverShown = false
                store.suppressAutoFollow()
                pickSuppressesAutoFollow = true
            } else if old != nil, new == nil, pickSuppressesAutoFollow {
                store.resumeAutoFollow()
                pickSuppressesAutoFollow = false
                if pickFocusRestoration.pickerResolved(isFrontmost: isFrontmost) {
                    restoreFocusAfterPick()
                }
            }
        }
        // a settings appearance change isn't observable through GhosttyApp, so re-render on the
        // notification to pick up the new terminal color in the quick terminal backing.
        .onReceive(NotificationCenter.default.publisher(for: .agtermAppearanceChanged)) { _ in
            terminalColor = WindowContentView.resolvedTerminalColor()
            toolbarMode = WindowContentView.resolvedToolbarMode()
            chromeText = WindowContentView.resolvedChromeText()
            attentionButtonEnabled = WindowContentView.resolvedAttentionButtonEnabled()
            hiddenInterfaceElements = WindowContentView.resolvedHiddenInterfaceElements()
            inactivePaneMute = WindowContentView.resolvedInactivePaneMute()
            sidebarShift = WindowContentView.resolvedSidebarShift()
        }
        // blend the title bar with the terminal; report frontmost/close to the library; surface the window
        // un-minimized on launch. the title token re-runs the blend in updateNSView on a session switch.
        .background(WindowAccessor(titleToken: windowTitle, windowID: windowID, library: library, store: store))
        // own a per-window quick terminal: register it so the frontmost-window call sites resolve it,
        // and spawn its shell in THIS window's active session's directory.
        .onAppear {
            quickTerminal.cwdProvider = { [store] in
                store.activeSession?.effectiveCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            }
            // the quick terminal's shell sees this window's AGTERM_* env (scratch: ENABLED + WINDOW_ID + SOCKET).
            quickTerminal.envProvider = { [quickTerminalEnv, windowID] in quickTerminalEnv(windowID) }
            // typing in the quick terminal counts as activity, so an idle auto-follow fire can't change this
            // window's selected session behind the overlay while the user types (mirrors the overlay/scratch).
            quickTerminal.onUserInput = { [store] in store.noteUserActivity() }
            quickTerminal.focusAllowed = { [pick] in pick.pending == nil }
            QuickTerminalRegistry.shared.register(windowID, controller: quickTerminal)
            terminalZoom.targetResolver = { [store, quickTerminal] in
                TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: quickTerminal.isVisible)
            }
            TerminalZoomRegistry.shared.register(windowID, controller: terminalZoom)
            registerDashboard()
            PickRegistry.shared.register(windowID, controller: pick)
        }
        .onDisappear {
            QuickTerminalRegistry.shared.unregister(windowID)
            TerminalZoomRegistry.shared.unregister(windowID)
            tearDownDashboard()
            if pickSuppressesAutoFollow {
                store.resumeAutoFollow()
                pickSuppressesAutoFollow = false
            }
            PickRegistry.shared.unregister(windowID)
        }
    }

    private var openOverlaySessionIDs: [UUID] {
        store.workspaces.flatMap(\.sessions).compactMap { session in
            session.overlayActive ? session.id : nil
        }
    }

    private func handleClosedEditorOverlays(previousOpenOverlaySessionIDs old: [UUID],
                                            currentOpenOverlaySessionIDs new: [UUID]) {
        let closed = Set(old).subtracting(new)
        if let id = actions.keymapEditOverlaySession, closed.contains(id) {
            actions.keymapEditOverlaySession = nil
            actions.reloadKeymap()
        }
        if let id = actions.ghosttyEditOverlaySession, closed.contains(id) {
            // the reload is skipped when the file is unchanged, so a no-op editor session keeps its font zoom.
            actions.ghosttyEditOverlaySession = nil
            actions.reloadGhosttyConfigIfEdited()
        }
    }

    /// Our own split instead of `NavigationSplitView`, so macOS 26 cannot impose the Liquid-Glass sidebar
    /// chrome (inset panel, toggle capsule) or couple it to the toolbar style: a plain `HStack` of the
    /// sidebar tree + a themed draggable divider + the terminal.
    @ViewBuilder private var splitRoot: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible {
                sidebarColumn
                    .frame(width: CGFloat(store.sidebarWidth))
                sidebarDivider
                    // the divider is the middle HStack child, so without this the detail column (drawn last)
                    // shadows the right half of the grab handle and only a few points stay grabbable.
                    .zIndex(1)
            }
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // DO NOT animate visibility: the width animation interpolates the detail column's frame every
        // display frame, and detailPane is the EAGER deck (every session's surface mounted), so each frame
        // reflows the grid (set_size) AND force-repaints (refresh) EVERY surface, hidden opacity-0 panes
        // included — a cost scaling with session count that janks a many-session window. An instant toggle
        // reflows each surface once. The mode switch below is safe: it swaps sidebar CONTENT, not the split
        // width, so the detail column (and the deck) never resize.
        .animation(.easeInOut(duration: 0.15), value: store.sidebarMode)
    }

    /// The eager split/deck stays mounted behind every modal presentation, zoom included. Frontmost-driven
    /// cleanup belongs here, not on `windowOverlayLayer` (absent while zoomed): otherwise a palette owned by
    /// the old front window survives the handoff and remounts after the picker and zoom both close.
    private var alwaysMountedSplitLayer: some View {
        splitRoot
            .padding(.top, titlebarHeight)
            .opacity(terminalZoom.target == nil ? 1 : 0)
            .allowsHitTesting(terminalZoom.target == nil)
            .onChange(of: isFrontmost) { _, frontmost in
                if frontmost, pick.pending != nil { palette.close() }
                if frontmost, pickFocusRestoration.windowBecameFrontmost(pickPending: pick.pending != nil) {
                    restoreFocusAfterPick()
                }
            }
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            // matches the detail pane's hairline so the line runs the full width under the title bar (the
            // vertical divider hangs from it at the junction); themed so it stays visible on light themes.
            Rectangle()
                .fill(chromeText.opacity(0.1))
                .frame(height: 1)
            WorkspaceSidebar(store: store, actions: actions)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        // the sidebar tint wash sits behind the transparent outline + bottom bar so the column reads as one
        // surface, behind the content (never tints row text) and over the window background (composes with
        // translucency/blur). Neutral paints nothing.
        .background(sidebarTintWash)
    }

    /// The wash for the current `sidebarShift`: black (darker) or white (lighter) at the shift's magnitude
    /// over the window background — equivalent to blending the terminal color toward black/white, and the
    /// same over an opaque or a translucent+blurred backdrop. Neutral (`amount == 0`) renders nothing.
    @ViewBuilder private var sidebarTintWash: some View {
        let amount = AppSettings.sidebarShiftAmount(strength: sidebarShift)
        if amount != 0 {
            Color(white: amount > 0 ? 0 : 1).opacity(abs(amount))
        }
    }

    /// A 1px themed vertical separator with a wider invisible drag handle to resize the sidebar. The divider
    /// carries `.zIndex(1)` at the call site so the full grab strip is reachable from both sides (the
    /// terminal column would otherwise shadow its right half).
    private var sidebarDivider: some View {
        Rectangle()
            .fill(chromeText.opacity(0.1))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        // width comes from the absolute cursor X, NOT accumulated translation: the divider
                        // moves with the width, so translation feeds back on itself and the line flickers.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                store.sidebarWidth = min(AppStore.sidebarWidthMax, max(AppStore.sidebarWidthMin, Double(value.location.x)))
                            }
                            // persist the new width once, on release, not on every drag tick.
                            .onEnded { _ in store.save() }
                    )
            }
    }

    @ViewBuilder private var detailColumn: some View {
        VStack(spacing: 0) {
            // hairline between the title bar and the terminal; in the detail pane so it starts at the
            // sidebar's right edge, themed (chromeText, low opacity) so it stays visible on light themes.
            Rectangle()
                .fill(chromeText.opacity(0.1))
                .frame(height: 1)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // the overlay renders in-deck inside `sessionDetail` (`overlayPanel`), not at this level.
                .overlay(alignment: .topTrailing) { searchBarLayer }
        }
    }

    /// The terminal area: a DECK of EVERY session's terminal, all mounted so each spawns its shell at
    /// startup, only the selected one visible + hit-testable. Switching is a visibility flip, never a
    /// re-host (re-hosting invalidates the Metal drawable and flickers). A placeholder shows when nothing
    /// is selected.
    @ViewBuilder private var detailPane: some View {
        let sessions = store.workspaces.flatMap(\.sessions)
        ZStack {
            if store.activeSession == nil {
                Text("No session selected")
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions, id: \.id) { session in
                let isActive = session.id == store.selectedSessionID
                sessionDetail(session, isActive: isActive)
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
            }
        }
    }

    /// One session's terminal content: the primary pane, a side-by-side split (`HSplitView`), or the
    /// maximized hidden-split pane, plus any overlay. `isActive` gates which pane auto-grabs focus — only
    /// the visible deck entry, and within a split only the focused pane.
    ///
    /// While zoom hosts one of these surfaces the deck entry stays MOUNTED at the SAME shape, only the
    /// zoom-owned slot swapping to its `deckHostsSurface` placeholder (an NSView lives in one host at a
    /// time), so a control-opened split/scratch/overlay still spawns and runs behind the zoom layer —
    /// swapping the whole entry out would re-host the NSSplitView (the titlebar-overrun rule) and orphan
    /// those surfaces until zoom exits. The arranged panes are stable ZStack wrappers (content swaps
    /// INSIDE), so the NSSplitView never re-layouts on a zoom toggle and the divider stays put;
    /// `SplitRatioAccessor` rides the primary wrapper as one persistent instance, suspended while zoomed.
    @ViewBuilder private func sessionDetail(_ session: Session, isActive: Bool) -> some View {
        // a FULL overlay (no size) hides the session beneath it (opacity 0) and draws translucent; a
        // FLOATING overlay (overlaySizePercent set) leaves the session VISIBLE and draws a smaller
        // opaque framed panel on top. Either way the pane(s) stay non-interactive while an overlay is up.
        let fullOverlay = session.fullOverlayActive
        // While zoomed OR while the dashboard is open, the normal deck stays mounted only to realize
        // surfaces; it must not focus, register drag targets, or show focusable controls behind the
        // full-window modal layer (both are mutually exclusive, so at most one gate is ever active).
        let deckInteractive = terminalZoom.target == nil && !dashboard.isOpen
        // the scratch is full-coverage too, so `hideForOverlay` hides the pane(s) like a FULL overlay
        // (opacity + hit-testing); `overlaid` (any overlay OR scratch) owns focus, so it gates the panes'
        // `isActive`. `hideForOverlay` stays false for a FLOATING overlay — this subtree's shape and
        // hit-testing must not change when one opens (NSSplitView overrun).
        let hideForOverlay = fullOverlay || session.scratchActive
        let overlaid = session.overlayActive || session.scratchActive
        // on-screen = selected, not hidden by a full overlay/scratch, not covered by the quick terminal.
        // Shared by BOTH split panes (unlike the focus-gated `isActive`), it gates each surface's drag-type
        // (un)registration AND its mouse-cursor tracking (the `deckVisible` note in libghostty.md), so no
        // file drop or cursor write lands off-screen. Without `!quickTerminal.isVisible` the covered pane
        // keeps deckVisible=true, races the quick-terminal surface for the cursor, and fans mouse-motion
        // into the covered TUI (issue #225 quick-terminal path).
        let visible = deckInteractive && isActive && !hideForOverlay && !quickTerminal.isVisible
        // focus gate: a visible quick terminal OWNS first responder, so no deck surface may be `isActive`
        // behind it — `TerminalView.updateNSView` would grab focus and send keystrokes to a covered session.
        // Every automatic reselection (`reselectIfSelectionHidden`, auto-follow) reaches this, not just a
        // click; the quick terminal's own hide flips it back.
        let focusable = deckInteractive && isActive && !quickTerminal.isVisible
        ZStack {
            // the session's pane(s), kept MOUNTED while an overlay is up — shells stay alive, like the deck
            // does for inactive sessions. a FULL overlay hides them (opacity 0) so its translucency reveals the
            // window backing, not the session; a FLOATING overlay leaves them visible behind its opaque panel.
            Group {
                if session.isSplit {
                    HSplitView {
                        // each arranged pane is a STABLE ZStack wrapper whose CONTENT swaps between the live
                        // TerminalView and the zoom placeholder: swapping the arranged subview itself makes
                        // NSSplitView re-layout and normalize the divider on every zoom enter/exit, and with
                        // no stored ratio there is nothing to restore. The wrapper keeps both arranged
                        // NSViews' identity, so the divider never moves.
                        ZStack {
                            if deckHostsSurface(session: session, surface: .primary) {
                                TerminalView(session: session, surfaceKeyPath: \.surface, makeSurface: makeSurface,
                                             isActive: focusable && !session.splitFocused && !overlaid,
                                             deckVisible: visible)
                                    .overlay { paneDim(session.splitFocused) }
                                    .id(primarySurfaceID(session))
                            } else {
                                Color.clear
                                    .id("\(session.id.uuidString)-primary-placeholder")
                            }
                        }
                        // introspects the AppKit NSSplitView to persist/restore the divider ratio and clip it
                        // out of the titlebar strip (see SplitRatioAccessor); a background on the stable
                        // wrapper (not a third pane, not inside the swapped content), so ONE probe survives
                        // zoom and its suspend/resume flips in place.
                        .background { SplitRatioAccessor(session: session, titlebarHeight: titlebarHeight, suspended: !deckInteractive, onPersist: { store.save() }) }
                        ZStack {
                            if deckHostsSurface(session: session, surface: .split) {
                                TerminalView(session: session, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface,
                                             isActive: focusable && session.splitFocused && !overlaid,
                                             deckVisible: visible)
                                    .overlay { paneDim(!session.splitFocused) }
                                    .id("\(session.id.uuidString)-split")
                            } else {
                                Color.clear
                                    .id("\(session.id.uuidString)-split-placeholder")
                            }
                        }
                    }
                    // per-session identity: without it SwiftUI reuses one NSSplitView across session
                    // switches and the divider (and arranged subviews) leak between sessions.
                    .id("\(session.id.uuidString)-hsplit")
                } else if session.splitFocused, session.splitSurface != nil {
                    // split hidden while the right pane had focus: show that pane maximized.
                    if deckHostsSurface(session: session, surface: .split) {
                        TerminalView(session: session, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface,
                                     isActive: focusable && !overlaid, deckVisible: visible)
                            .id("\(session.id.uuidString)-split")
                    } else {
                        Color.clear
                            .id("\(session.id.uuidString)-split-placeholder")
                    }
                } else {
                    if deckHostsSurface(session: session, surface: .primary) {
                        TerminalView(session: session, surfaceKeyPath: \.surface, makeSurface: makeSurface,
                                     isActive: focusable && !overlaid, deckVisible: visible)
                            .id(primarySurfaceID(session))
                    } else {
                        Color.clear
                            .id("\(session.id.uuidString)-primary-placeholder")
                    }
                }
            }
            .opacity(hideForOverlay ? 0 : 1)
            // gate on `hideForOverlay` (full overlay OR scratch), NOT `session.overlayActive`: this modifier
            // must not change when a floating overlay opens, or the NSSplitView re-lays-out and overruns up
            // into the titlebar (same perturbation class as adding a sibling). A floating overlay leaves the
            // panes hit-testable; `overlayPanel`'s transparent catcher absorbs the clicks around it.
            .allowsHitTesting(deckInteractive && !hideForOverlay)
            // the scratch renders in-deck above the (hidden) pane(s) — a full-coverage sibling is safe (the
            // panes go opacity 0, the split's frame is hidden). It sits BELOW the ephemeral overlay (zIndex 1
            // vs `overlayPanel`'s 3) and hides under a FULL overlay like the panes: under window translucency
            // every surface background renders fully transparent, so a scratch left visible would show THROUGH
            // it (reading as "the overlay opened under the scratch"); a FLOATING panel's opaque backing needs
            // no such hiding. `overlayPanel` hosts BOTH variants, always present at a constant shape (content
            // gated internally), so opening or resizing an overlay never re-hosts the NSSplitView.
            if session.scratchActive, deckHostsSurface(session: session, surface: .scratch) {
                // a full overlay renders above the scratch (`overlayPanel`, zIndex 3), so it gates focus on
                // top of `focusable` (matching makeScratchSurface's autoFocus suppression); `deckVisible`
                // mirrors the panes' rule so only an on-screen scratch is a file-drop target.
                TerminalView(session: session, surfaceKeyPath: \.scratchSurface, makeSurface: makeScratchSurface,
                             isActive: focusable && !session.overlayActive,
                             deckVisible: deckInteractive && isActive && !fullOverlay && !quickTerminal.isVisible)
                    .opacity(fullOverlay ? 0 : 1)
                    .allowsHitTesting(!fullOverlay)
                    .id("\(session.id.uuidString)-scratch")
                    .zIndex(1)
            }
            // the overlay renders IN-DECK per session, so its program runs even when the session isn't
            // active; see `overlayPanel` for the constant-shape rule that keeps open/close/resize from
            // re-hosting the NSSplitView or re-parenting the surface.
            overlayPanel(session: session, isActive: focusable)
                .zIndex(3)
        }
        // on overlay close, refocus the topmost remaining surface (scratch if still shown, else the pane)
        // via the shared `topmostSurface` precedence — never a pane hidden under the scratch. A single
        // makeFirstResponder loses the race with the overlay view's teardown/re-host, so drive the bounded
        // retry the split-collapse survivor uses. Gated on isActive so only the visible session reclaims
        // focus, and skipped while the quick terminal covers the window (it owns focus; its own hide
        // restores the session).
        .onChange(of: session.overlayActive) { _, isOpen in
            if !isOpen, deckInteractive, isActive, !quickTerminal.isVisible {
                (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
            }
        }
        // scratch show AND hide both need the bounded focus retry: the surface is kept alive across hides,
        // so a re-show remounts it and `autoFocus`'s one-shot latch won't re-fire (same remount race as the
        // split-collapse survivor). `topmostSurface` routes focus correctly either way — on show it is the
        // scratch (or a still-open overlay above it), on hide the overlay-if-up else the pane.
        .onChange(of: session.scratchActive) { _, _ in
            // skip while the quick terminal covers the window — it owns focus above the session layers
            // (mirrors focusActiveSession); the deck re-grabs the scratch when the quick terminal hides.
            guard deckInteractive, isActive, !quickTerminal.isVisible else { return }
            (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
        }
    }

    /// The overlay — FULL or FLOATING — rendered IN-DECK inside each session's `sessionDetail` ZStack as ONE
    /// ALWAYS-PRESENT sibling, its content gated INSIDE the GeometryReader so the ZStack's child count never
    /// changes (constant shape = no NSSplitView re-host = no titlebar overrun). Both variants share this one
    /// surface host, so `session.overlay.resize` switching full<->% only re-flows the frame and never
    /// re-parents the NSView (which would blank its Metal drawable). A nil `overlaySizePercent` fills the
    /// detail area translucent (no backing/frame), panes hidden by `hideForOverlay`; a percent draws an
    /// opaque framed panel at that size, centered, panes visible around it. Per-session in the eager deck,
    /// so the surface mounts and its program runs while the session is inactive.
    @ViewBuilder private func overlayPanel(session: Session, isActive: Bool) -> some View {
        GeometryReader { geo in
            ZStack {
                if session.overlayActive, deckHostsSurface(session: session, surface: .overlay) {
                    let floating = session.overlaySizePercent != nil
                    let fraction = session.overlaySizePercent.map { CGFloat($0) / 100 } ?? 1
                    // transparent click-catcher: absorbs clicks AROUND a floating panel so they can't reach
                    // the still-hit-testable panes and steal the overlay's first responder (the full variant
                    // hides the panes anyway).
                    Color.clear.contentShape(Rectangle())
                    TerminalView(session: session, surfaceKeyPath: \.overlaySurface,
                                 makeSurface: makeOverlaySurface, isActive: isActive, deckVisible: isActive)
                        .frame(width: geo.size.width * fraction, height: geo.size.height * fraction)
                        // floating = opaque backing + hairline frame + shadow so it reads as a distinct window
                        // over the still-visible session; full = translucent, no chrome (libghostty draws only
                        // the terminal, so the window backing shows through). The modifier CHAIN is constant
                        // across both — only the parameters go inert for full — so a full<->% resize keeps
                        // the same view tree and never re-hosts the surface NSView.
                        .background(floating ? terminalColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: floating ? 12 : 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: floating ? 12 : 0)
                                .strokeBorder(floating ? Color.white.opacity(0.18) : Color.clear, lineWidth: 1)
                        )
                        .shadow(radius: floating ? 24 : 0)
                        .id("\(session.id.uuidString)-overlay")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // when no overlay is up the panel is an empty full-frame GeometryReader — make it inert so it never
        // intercepts clicks meant for the pane(s).
        .allowsHitTesting(isActive && session.overlayActive && deckHostsSurface(session: session, surface: .overlay))
    }

    /// The terminal search bar, a top-aligned `.overlay` on `detailPane` — NOT inside any session's
    /// `sessionDetail`/HSplitView ZStack, so toggling it can't perturb the split and overrun the NSSplitView
    /// into the titlebar. Shown while zoom is off and the active session's `searchActive` is set; the needle
    /// binding drives the query through `actions.updateSearchNeedle`.
    @ViewBuilder private var searchBarLayer: some View {
        if terminalZoom.target == nil, let session = store.activeSession, session.searchActive {
            TerminalSearchBar(
                needle: Binding(
                    get: { session.searchNeedle },
                    // updateSearchNeedle is the single writer of the active session's searchNeedle.
                    set: { actions.updateSearchNeedle($0) }
                ),
                displayText: session.searchDisplayText,
                onNext: { actions.navigateSearch(.next) },
                onPrevious: { actions.navigateSearch(.previous) },
                onClose: { actions.endSearch() },
                chromeText: chromeText,
                terminalColor: terminalColor
            )
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
    }

    /// Keeps a primary host stable through lazy surface creation and ordinary updates, but remounts it when
    /// one live surface replaces another (split-survivor promotion): `TerminalView.updateNSView` cannot
    /// replace the view `makeNSView` returned, so session identity alone would keep hosting the torn-down
    /// prior primary.
    func primarySurfaceID(_ session: Session) -> String {
        "\(session.id.uuidString)-primary-\(session.primarySurfaceHostRevision)"
    }

    /// Mutes the inactive split pane's TEXT without darkening the background: a translucent wash of the
    /// terminal background over the pane, so background pixels blend bg→bg (unchanged) and text pixels
    /// text→bg (less bright). Opacity comes from the Settings mute-strength slider via
    /// `AppSettings.muteOpacity` (0...10, strength 0 renders nothing); clicks pass through so the muted
    /// pane can still be focused.
    @ViewBuilder private func paneDim(_ dimmed: Bool) -> some View {
        let opacity = AppSettings.muteOpacity(strength: inactivePaneMute)
        if dimmed, opacity > 0 {
            terminalColor.opacity(opacity).allowsHitTesting(false)
        }
    }

    /// The terminal background color from the ghostty config, with a dark fallback if libghostty has none.
    private static func resolvedTerminalColor() -> Color {
        Color(nsColor: GhosttyApp.shared.terminalBackgroundColor
            ?? NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1))
    }

    /// The toolbar mode from the (non-observable) `GhosttyApp`; see the `toolbarMode` mirror.
    private static func resolvedToolbarMode() -> ToolbarMode {
        GhosttyApp.shared.toolbarMode
    }

    /// The attention-button flag from the non-observable `GhosttyApp`; see the `attentionButtonEnabled` mirror.
    private static func resolvedAttentionButtonEnabled() -> Bool {
        GhosttyApp.shared.attentionButtonEnabled
    }

    /// The hidden-chrome-element set from the non-observable `GhosttyApp`; see the mirror above.
    private static func resolvedHiddenInterfaceElements() -> Set<InterfaceElement> {
        GhosttyApp.shared.hiddenInterfaceElements
    }

    /// Whether a title-bar / sidebar-footer chrome element should be drawn. Everything is shown unless the
    /// user hid it in Settings ▸ Interface.
    func shows(_ element: InterfaceElement) -> Bool {
        !hiddenInterfaceElements.contains(element)
    }

    /// The inactive-pane mute strength from the non-observable `GhosttyApp`; see the `inactivePaneMute` mirror.
    private static func resolvedInactivePaneMute() -> Int {
        GhosttyApp.shared.inactivePaneMuteStrength
    }

    /// The sidebar background shift from the (non-observable) `GhosttyApp`; see the `sidebarShift` mirror.
    private static func resolvedSidebarShift() -> Int {
        GhosttyApp.shared.sidebarBackgroundShift
    }

    /// The terminal theme's foreground color, with a light fallback if libghostty hasn't reported one.
    private static func resolvedChromeText() -> Color {
        Color(nsColor: GhosttyApp.shared.terminalForegroundColor ?? .labelColor)
    }

    /// The base text with the action's current shortcut appended in parentheses (`Toggle Sidebar (⌃⌘S)`),
    /// or bare when the action has none — via the SAME `AppActions.shortcutGlyph` resolver the action
    /// palette uses, so a rebind shows the new chord. Non-private so the `+RecentSessions` extension's
    /// attention button can build its tooltip.
    func helpHint(_ base: String, _ action: BuiltinAction) -> String {
        guard let glyph = actions.shortcutGlyph(for: action) else { return base }
        return "\(base) (\(glyph))"
    }

    /// The quick-terminal overlay: the scratch terminal centered at 90% of the window, framed by a hairline
    /// border and shadow so it reads as a distinct floating window over the (undimmed) content — libghostty
    /// renders only the terminal, so the frame is drawn here. The margin is a transparent tap-catcher that
    /// dismisses on click; no dim, because the overlay cannot cover the AppKit title bar and would shade the
    /// body but not the chrome. Rendered only while visible; the controller owns the surface, so hiding
    /// keeps the shell alive.
    /// The window-level overlays (quick terminal, command palettes, Ctrl-Tab switcher) as one layer: a ZStack
    /// sibling INSIDE the body's root ZStack, not body-level `.overlay`s, so it can be inset below the
    /// titlebar and ordered BELOW `customTitlebar` (which a body-level `.overlay` cannot). Every child is
    /// conditional, so with none showing this is an empty frame — not hit-testable, so the terminal below
    /// stays interactive; each overlay's own `GeometryReader` fills the inset area. Order here = z-order
    /// (switcher over palette over quick terminal).
    private var windowOverlayLayer: some View {
        ZStack {
            quickTerminalOverlay
            commandPaletteOverlay
            sessionSwitcherOverlay
            // the dashboard is the topmost window overlay: opening it closes the three above (mirrors the
            // zoom lifecycle), so ordering only settles the empty case, but it renders last for clarity.
            dashboardOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var quickTerminalOverlay: some View {
        if quickTerminal.isVisible {
            GeometryReader { geo in
                ZStack {
                    // the tap-catcher carries the `quick-terminal` accessibility id: a SwiftUI view is in
                    // the a11y tree (the Metal-backed `QuickTerminalPane` is not), so tests query this one.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { quickTerminal.hide() }
                        .accessibilityElement()
                        .accessibilityIdentifier("quick-terminal")
                    QuickTerminalPane(controller: quickTerminal)
                        .frame(width: geo.size.width * 0.9, height: geo.size.height * 0.9)
                        // solid backing so the quick terminal stays opaque even when the main window
                        // is translucent (its ghostty surface draws transparent under background-opacity=0).
                        .background(terminalColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(radius: 24)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// True only for the frontmost window. The palette and session switcher are app-global singles acting on
    /// the frontmost store, so only that window mounts their overlays — otherwise every open window renders
    /// a duplicate, contending for focus and showing the wrong window's candidates. `activeWindowID`
    /// (frontmost-or-first-open, the accessor the palette/actions resolve through) matches exactly one
    /// window even before the first `didBecomeKey` sets `frontmostWindowID`, and is observed, so this reacts.
    private var isFrontmost: Bool { library.activeWindowID == windowID }

    /// The command-palette overlay, mounted only while a palette is open in the frontmost window. Its
    /// content (search field + result list) is rebuilt from `palette.mode`.
    @ViewBuilder private var commandPaletteOverlay: some View {
        if isFrontmost, pick.pending == nil, palette.mode != nil {
            CommandPalette(controller: palette, actions: actions)
        }
    }

    /// A control picker is per-window rather than frontmost-global, so a caller can present one in a
    /// background window without duplicating it elsewhere. Selection preserves the caller's original item
    /// index even though fuzzy filtering reorders the visible rows. Keyed by the pending id so a picker
    /// replacing another in the same view update gets fresh palette state instead of the previous picker's
    /// rows, whose select closures capture the previous picker's items.
    @ViewBuilder private var pickPaletteOverlay: some View {
        if let pending = pick.pending {
            CommandPalette(
                controller: palette,
                actions: actions,
                items: pending.items.enumerated().map { index, item in
                    PaletteItem(id: item.id, title: item.label, subtitle: item.subtitle) {
                        pick.resolve(ControlPickResult(
                            result: .picked,
                            id: item.id,
                            label: item.label,
                            index: index
                        ))
                    }
                },
                prompt: pending.prompt,
                allowCustom: pending.allowCustom,
                onCustom: { query in
                    pick.resolve(ControlPickResult(result: .custom, query: query))
                },
                onDismiss: { pick.cancel() }
            )
            .id(pending.id)
        }
    }

    /// The Ctrl-Tab session switcher overlay, mounted only while cycling in the frontmost window.
    @ViewBuilder private var sessionSwitcherOverlay: some View {
        if isFrontmost, sessionSwitcher.isActive {
            SessionSwitcherOverlay(switcher: sessionSwitcher, store: store)
        }
    }

    /// The sidebar footer, source-list style: two add controls on the left (a workspace; a menu adding a
    /// session to the current workspace at the default cwd or at a picked directory) and two view toggles on
    /// the right (the workspace focus filter, the flagged working-set view). Each of the four is
    /// individually hideable via Settings ▸ Interface (`shows(_:)`).
    private var bottomBar: some View {
        HStack(spacing: 2) {
            if shows(.newWorkspace) {
                Button {
                    actions.newWorkspace()
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(helpHint("New Workspace", .newWorkspace))
                .accessibilityLabel("New Workspace")
            }

            if shows(.newSession) {
                Menu {
                    Button("New Session") { actions.newSession() }
                    Button("Open Directory…") { actions.openDirectory() }
                } label: {
                    Image(systemName: "plus.rectangle")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                // a borderless Menu ignores foregroundStyle on its glyph but follows the accent tint.
                .tint(chromeText)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(helpHint("New Session", .newSession))
                .accessibilityLabel("Add session")
                .accessibilityIdentifier("add-session")
            }

            Spacer()

            // apply or suspend the marked-workspace filter WITHOUT losing the set, so peeking at the whole
            // tree costs one click each way. 2-state glyph (filled while applied): indicator and control.
            if shows(.focusFilter) {
                Button {
                    actions.toggleFocusFilter()
                } label: {
                    Image(systemName: store.focusEnabled ? "square.grid.2x2.fill" : "square.grid.2x2")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                // nothing marked = nothing to filter to, and the store refuses an empty set anyway. The
                // explicit chromeText foregroundStyle defeats SwiftUI's disabled dimming, so mute by hand.
                .disabled(store.focusedWorkspaceIDs.isEmpty)
                .opacity(store.focusedWorkspaceIDs.isEmpty ? 0.35 : 1)
                .help(helpHint(store.focusEnabled ? "Show all workspaces" : "Show only focused workspaces",
                               .toggleWorkspaceFilter))
                .accessibilityLabel("Toggle Workspace Filter")
                // the only accessibility-observable read of the filter state now that the pill is gone.
                .accessibilityValue(store.focusEnabled ? "on" : "off")
                .accessibilityIdentifier("focus-filter-toggle")
            }

            // flip the sidebar between the workspace tree and the flat flagged working-set list. 2-state
            // glyph (filled in flagged mode); the switch animates via splitRoot's `.animation(value:)`.
            if shows(.flaggedView) {
                Button {
                    actions.toggleFlaggedView()
                } label: {
                    let flagged = store.sidebarMode == .flagged
                    Image(systemName: flagged ? "flag.fill" : "flag")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                // disable entering an empty flagged view (tree mode + no flags); stays enabled in flagged
                // mode so the button can always switch back to the tree. Hand-muted, like the filter above.
                .disabled(store.sidebarMode == .tree && store.flaggedSessions.isEmpty)
                .opacity(store.sidebarMode == .tree && store.flaggedSessions.isEmpty ? 0.35 : 1)
                .help(helpHint(store.sidebarMode == .flagged ? "Show all sessions" : "Show flagged sessions", .toggleFlaggedView))
                .accessibilityLabel("Toggle Flagged View")
                .accessibilityIdentifier("flagged-view-toggle")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // the add buttons track the terminal theme's foreground, matching the sidebar rows above.
        .foregroundStyle(chromeText)
        // no explicit background: the sidebar is transparent (the window's terminal color shows through),
        // so a `.bar` material here would paint a mismatched darker strip.
    }

}
