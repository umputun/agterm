import agtermCore
import AppKit
import SwiftUI

/// Window-local handoff from picker dismissal to the window becoming frontmost: a background window must
/// not claim first responder, yet its removed picker field cannot remain the responder.
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

/// The per-window UI: sidebar + active session terminal, plus the quick-terminal / palette / switcher
/// overlays. `ContentView` resolves the store and hands in the non-optional `AppStore` the bindings need.
struct WindowContentView: View {
    let windowID: WindowInfo.ID
    @Bindable var store: AppStore
    let library: WindowLibrary
    let makeSurface: (Session) -> GhosttySurfaceView
    let makeSplitSurface: (Session) -> GhosttySurfaceView
    /// nil builds the session-wide overlay surface, `left`/`right` the pane-scoped one reading that pane's slot.
    let makeOverlaySurface: (Session, OverlayPane?) -> GhosttySurfaceView
    let makeScratchSurface: (Session) -> GhosttySurfaceView
    let quickTerminalEnv: (WindowInfo.ID) -> [String: String]
    let actions: AppActions
    let palette: PaletteController
    let sessionSwitcher: SessionSwitcher
    /// Mirrors `WindowAppearance`'s other opaque-forcing condition; SwiftUI keeps it current by itself.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// One quick terminal per window, registered in `QuickTerminalRegistry` on appear so the
    /// frontmost-window call sites reach it; its `cwdProvider` binds to this window's active session.
    @State var quickTerminal = QuickTerminalController()
    /// Window-level zoom: rehosts the visible terminal surface above the sidebar, titlebar, quick terminal
    /// frame, palettes and switcher until toggled off.
    @State var terminalZoom = TerminalZoomController()
    /// View-only grid of reparented member surfaces, registered in `DashboardControllerRegistry` on appear so
    /// the socket drives it; `+Dashboard` owns the overlay branch, deck yield, font override and lifecycle.
    @State var dashboard = DashboardController()
    /// Per-window native picker on the shared palette view, registered for control-socket lookup while this
    /// window is mounted; unlike `palette`, its pending state is window-scoped.
    @State var pick = PickController()
    /// Tracks this view's balanced auto-follow suppression so window teardown can release it even when
    /// SwiftUI removes the observer before the pick controller publishes its cancellation.
    @State private var pickSuppressesAutoFollow = false
    /// Defers picker focus restoration when a control request resolves in a background window. The
    /// always-mounted frontmost observer consumes it without activating or ordering that window.
    @State private var pickFocusRestoration = PickFocusRestorationState()
    /// The terminal background color, the quick terminal's opaque backing. This and every mirror below track
    /// the non-observable `GhosttyApp`, refreshed on `.agtermAppearanceChanged` so Settings applies live.
    @State var terminalColor: Color = WindowContentView.resolvedTerminalColor()
    /// `normal` shows the cwd subtitle, `compact` collapses the title bar to a single line, `hidden` drops
    /// the row (and the traffic lights) for a full-bleed terminal.
    @State var toolbarMode: ToolbarMode = WindowContentView.resolvedToolbarMode()
    /// How strongly the mute wash fades the text of a terminal that does not hold focus (0...10).
    @State private var inactivePaneMute: Int = WindowContentView.resolvedInactivePaneMute()
    /// The window's saved background opacity, which scales the mute wash — see `muteWashOpacity`.
    @State private var windowOpacity: Double = WindowContentView.resolvedWindowOpacity()
    /// Whether THIS window is in native fullscreen, where AppKit renders it opaque whatever the saved
    /// opacity says. Per-window, so it cannot ride the app-global mirrors.
    @State private var windowFullscreen = false
    /// Live pointer/drag state for `sidebarDivider`'s grab handle, read by its deferred cursor re-assert.
    @State private var dividerHovered = false
    @State private var dividerDragging = false
    /// How much lighter/darker the sidebar background is than the terminal (0...10, 5 = neutral). Drives
    /// `sidebarTintWash`.
    @State var sidebarShift: Int = WindowContentView.resolvedSidebarShift()
    /// The terminal theme's foreground, used for the chrome text (title bar text + buttons, sidebar bottom
    /// bar) so non-terminal text tracks the theme.
    @State var chromeText: Color = WindowContentView.resolvedChromeText()
    /// When true the title bar shows the attention bell.
    @State var attentionButtonEnabled: Bool = WindowContentView.resolvedAttentionButtonEnabled()
    /// The title-bar / sidebar-footer chrome the user hid in Settings ▸ Interface, read by `shows(_:)`.
    @State var hiddenInterfaceElements: Set<InterfaceElement> = WindowContentView.resolvedHiddenInterfaceElements()
    /// Whether the recent-sessions popover (the mouse form of the Ctrl-Tab switcher) is shown, anchored on
    /// the title-bar clock button. Non-private so `+RecentSessions`'s button/rows can toggle it.
    @State var recentSessionsShown = false
    /// Whether the attention popover (the mouse equivalent of the ⌃⇧I attention palette) is shown, anchored
    /// on the title-bar bell. Non-private so the `+RecentSessions` extension's bell/rows can toggle it.
    @State var attentionPopoverShown = false
    /// Sidebar width and visibility live on the per-window `AppStore`, persisted in `Snapshot` and shared
    /// with the toolbar button, View menu, palette and the `sidebar` control command.
    /// Height of the custom titlebar row: title + cwd normal, one short line compact, zero hidden (an
    /// invisible drag strip, terminal full-bleed). The split content is inset by this.
    var titlebarHeight: CGFloat {
        switch toolbarMode {
        case .normal: return 48
        case .compact: return 30
        case .hidden: return 0
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // the AppKit HSplitView overruns into the titlebar and steals header clicks, so the deck stays
            // inset below it; kept mounted while zoomed so background sessions and overlays still realize.
            alwaysMountedSplitLayer
            if let zoomTarget = terminalZoom.target {
                terminalZoomLayer(zoomTarget)
                    .zIndex(10)
                zoomTitlebar
                    .zIndex(11)
            } else {
                // overlays sit BELOW the titlebar, inset by its height: a body-level `.overlay`'s scrim
                // composites over the titlebar (backing hidden for translucency) and seams the non-compact one.
                windowOverlayLayer
                    .padding(.top, titlebarHeight)
                    .zIndex(1)
                if dashboard.isOpen {
                    // view-only modal like zoom: a stripped bar so titlebar buttons can't steal the key
                    // catcher's first responder (stranding Esc) or drive actions behind the grid.
                    dashboardTitlebar
                        .zIndex(2)
                } else {
                    customTitlebar
                        .zIndex(2)
                }
            }
            // the picker is the window's topmost modal: it stays visible and interactive even when terminal
            // zoom or the dashboard was already active when the request arrived.
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
            } else {
                // hiding mid-drag (⌘⌃S, the palette, `sidebar hide`, inactive-window auto-hide) removes the
                // divider and cancels its gesture without `onEnded`, so these would stay latched on this
                // view: ↔ would survive the next hover exit and the arrow would never be restored.
                dividerHovered = false
                dividerDragging = false
            }
        }
        // on quick-terminal hide refocus the active session, unless this window's zoom owns focus: zoom-enter
        // hides it, and `actions` targets the FRONTMOST window, so a background hide must not move focus.
        .onChange(of: quickTerminal.isVisible) { _, visible in
            if !visible, terminalZoom.target == .quick { terminalZoom.clear() }
            if !visible, terminalZoom.target == nil { actions.focusActiveSession() }
        }
        .onChange(of: terminalZoom.target) { old, new in
            handleZoomTargetChange(old: old, new: new)
            closeDashboardIfZoomActive(new)
        }
        // open/close drives the modal lifecycle + auto-follow pause; the font key (members + mode) drives the
        // transient font override, so a re-open with a new mode re-sizes too; the id set prunes closed members.
        .onChange(of: dashboard.isOpen) { _, isOpen in
            handleDashboardOpenChange(isOpen)
        }
        .onChange(of: dashboardFontKey) { _, _ in
            handleDashboardFontChange()
        }
        .onChange(of: dashboardValidMembers) { _, _ in
            reconcileDashboardMembers()
        }
        // editor-overlay reload hooks must stay mounted while terminal zoom replaces the normal deck.
        .onChange(of: openOverlaySessionIDs) { old, new in
            handleClosedEditorOverlays(previousOpenOverlaySessionIDs: old, currentOpenOverlaySessionIDs: new)
        }
        // a palette owns the keyboard: suppress auto-follow while it is open so an armed idle jump can't
        // reshuffle the selection under it and an action-palette run hit the wrong session.
        .onChange(of: palette.mode == nil) { _, closed in
            if closed {
                store.resumeAutoFollow()
                actions.focusActiveSession()
            } else {
                store.suppressAutoFollow()
            }
        }
        // a native picker owns keyboard focus like a palette: pair auto-follow suppression per window, then
        // return first responder to this window's terminal after every resolution path.
        .onChange(of: pick.pending?.id) { old, new in
            if old == nil, new != nil, !pickSuppressesAutoFollow {
                // a socket-driven picker may arrive with either title-bar popover already open; dismiss
                // both so no second interactive surface remains above the modal picker.
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
        // `GhosttyApp` isn't observable, so re-read every mirror when a settings appearance change posts.
        .onReceive(NotificationCenter.default.publisher(for: .agtermAppearanceChanged)) { _ in
            terminalColor = WindowContentView.resolvedTerminalColor()
            toolbarMode = WindowContentView.resolvedToolbarMode()
            chromeText = WindowContentView.resolvedChromeText()
            attentionButtonEnabled = WindowContentView.resolvedAttentionButtonEnabled()
            hiddenInterfaceElements = WindowContentView.resolvedHiddenInterfaceElements()
            inactivePaneMute = WindowContentView.resolvedInactivePaneMute()
            windowOpacity = WindowContentView.resolvedWindowOpacity()
            sidebarShift = WindowContentView.resolvedSidebarShift()
        }
        .modifier(FullscreenEdgeObserver { note in
            if let state = fullscreenState(from: note) { windowFullscreen = state }
        })
        // blend the title bar with the terminal; report frontmost/close to the library; surface the window
        // un-minimized on launch. the title token re-runs the blend in updateNSView on a session switch.
        .background(WindowAccessor(titleToken: windowTitle, windowID: windowID, library: library, store: store))
        .onAppear {
            quickTerminal.cwdProvider = { [store] in
                store.activeSession?.effectiveCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            }
            // the quick terminal's shell sees this window's AGTERM_* env (scratch: ENABLED + WINDOW_ID + SOCKET).
            quickTerminal.envProvider = { [quickTerminalEnv, windowID] in quickTerminalEnv(windowID) }
            // typing counts as activity, so an idle auto-follow fire can't change this window's selected
            // session behind the overlay while the user types (mirrors the overlay/scratch).
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

    /// A plain `HStack` (sidebar + themed draggable divider + terminal) instead of `NavigationSplitView`, so
    /// macOS 26 can't impose Liquid-Glass sidebar chrome (inset panel, toggle capsule) or the toolbar style.
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
        // DO NOT animate visibility: interpolating the detail column's frame reflows (set_size) and
        // force-repaints (refresh) EVERY eager-deck surface each display frame, hidden opacity-0 panes
        // included, and janks a many-session window. The mode switch is safe — it swaps sidebar CONTENT,
        // not the split width, so the detail column (and the deck) never resize.
        .animation(.easeInOut(duration: 0.15), value: store.sidebarMode)
    }

    /// Stays mounted behind every modal, zoom included, so frontmost-driven cleanup belongs here, not on
    /// `windowOverlayLayer` (absent while zoomed): else the old front window's palette survives the handoff.
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
            // matches the detail pane's hairline so the line runs full width under the title bar.
            Rectangle()
                .fill(chromeText.opacity(0.1))
                .frame(height: 1)
            WorkspaceSidebar(store: store, actions: actions)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        // sits behind the transparent outline + bottom bar so the column reads as one surface, behind the
        // content (never tints row text) and over the window background (composes with translucency/blur).
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

    /// A 1px themed vertical separator with a wider invisible drag handle to resize the sidebar.
    private var sidebarDivider: some View {
        Rectangle()
            .fill(chromeText.opacity(0.1))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    // per MOVE, not just on entry: the handle overhangs the terminal, whose surface re-asserts
                    // its own shape on every move, and one set on entry cannot hold against it (issue #324).
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            dividerHovered = true
                            setDividerCursor()
                        case .ended:
                            dividerHovered = false
                            // a drag past the width clamp leaves the handle under the pointer; the drag's own
                            // re-assert owns the cursor until release.
                            if !dividerDragging { NSCursor.arrow.set() }
                        }
                    }
                    .gesture(
                        // width comes from the absolute cursor X, NOT accumulated translation: the divider
                        // moves with the width, so translation feeds back on itself and the line flickers.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                dividerDragging = true
                                store.sidebarWidth = min(AppStore.sidebarWidthMax, max(AppStore.sidebarWidthMin, Double(value.location.x)))
                                // past the clamp the divider stops following the pointer, which ends up over
                                // live terminal with no hover event left to repaint ↔.
                                setDividerCursor()
                            }
                            // persist the new width once, on release, not on every drag tick.
                            .onEnded { _ in
                                dividerDragging = false
                                if !dividerHovered { NSCursor.arrow.set() }
                                store.save()
                            }
                    )
            }
    }

    /// Paint ↔ for the sidebar handle, then once more on the next runloop turn: a cursor replacement still
    /// lands after this synchronous `.set()` returns — SwiftUI hosts the terminal surface and resets the
    /// cursor as the mouse moves (see `GhosttySurfaceView.cursorUpdate`) — so a single set loses the race.
    /// The deferred pass re-reads `dividerHovered` rather than capturing it, so a re-assert arriving after
    /// the pointer left cannot strand ↔ over live terminal text.
    private func setDividerCursor() {
        NSCursor.resizeLeftRight.set()
        DispatchQueue.main.async {
            guard dividerHovered || dividerDragging else { return }
            NSCursor.resizeLeftRight.set()
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

    /// A top-aligned `.overlay` on `detailPane` — NOT inside any session's `sessionDetail`/HSplitView ZStack,
    /// so toggling it can't perturb the split and overrun the NSSplitView into the titlebar. Shown while zoom
    /// is off and the active session's `searchActive` is set.
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

    /// Keeps the primary host stable through lazy surface creation, but remounts it when one live surface
    /// replaces another (split-survivor promotion): `updateNSView` cannot replace the view `makeNSView`
    /// returned, so session identity alone would keep hosting the torn-down prior primary.
    func primarySurfaceID(_ session: Session) -> String {
        "\(session.id.uuidString)-primary-\(session.primarySurfaceHostRevision)"
    }

    /// Opacity of the mute wash, shared by the inactive split pane and the backdrop behind a floating panel
    /// (overlay, quick terminal). 0 = the user turned muting off.
    ///
    /// Scaled by the opacity the window actually renders at, because the wash color is opaque while a
    /// translucent backing is not: painting alpha `m` over backing alpha `p` leaves the body at `m + p(1-m)`
    /// against a title bar still at `p`. Nothing removes that difference — coverage only adds — so the scale
    /// shrinks it in step with the window's own transparency and is a no-op at full opacity.
    var muteWashOpacity: Double {
        AppSettings.muteOpacity(strength: inactivePaneMute) * effectiveWindowOpacity
    }

    /// The saved opacity, except where `WindowAppearance.sync` forces the window opaque without touching
    /// that setting. There body and title bar share one opaque backing, so the wash needs no scaling and
    /// scaling it would under-mute — down to nothing at a saved opacity of 0.
    private var effectiveWindowOpacity: Double {
        windowFullscreen || reduceTransparency ? 1 : windowOpacity
    }

    /// The wash color for a session: its own solid background when it set one, else the theme background.
    /// The wash must blend background→background to fade text alone, so a session running on a different
    /// background needs that color or the wash tints it.
    ///
    /// Sampled at redraw, and neither source is observed: `backgroundWatermark` is `@ObservationIgnored`
    /// and a live OSC 11 color lives on the surface view. Every path that PUTS a wash on screen re-reads it
    /// (overlay, quick-terminal and split-focus state are all observed), so only a background set while a
    /// wash is already painted holds the old color, until the next observed change.
    func washColor(for session: Session) -> Color {
        guard let watermark = session.backgroundWatermark, watermark.kind == .color,
              let nsColor = NSColor(agtermHex: watermark.colorHex) else { return terminalColor }
        return Color(nsColor: nsColor)
    }

    /// This window's live fullscreen state from a fullscreen notification, nil when another window posted it.
    private func fullscreenState(from note: Notification) -> Bool? {
        guard let window = note.object as? NSWindow,
              WindowRegistry.shared.windowID(for: window) == windowID else { return nil }
        return window.styleMask.contains(.fullScreen)
    }

    /// The terminal background color from the ghostty config, with a dark fallback if libghostty has none.
    private static func resolvedTerminalColor() -> Color {
        Color(nsColor: GhosttyApp.shared.terminalBackgroundColor
            ?? NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1))
    }

    private static func resolvedToolbarMode() -> ToolbarMode {
        GhosttyApp.shared.toolbarMode
    }

    private static func resolvedAttentionButtonEnabled() -> Bool {
        GhosttyApp.shared.attentionButtonEnabled
    }

    private static func resolvedHiddenInterfaceElements() -> Set<InterfaceElement> {
        GhosttyApp.shared.hiddenInterfaceElements
    }

    /// Whether a title-bar / sidebar-footer chrome element should be drawn. Everything is shown unless the
    /// user hid it in Settings ▸ Interface.
    func shows(_ element: InterfaceElement) -> Bool {
        !hiddenInterfaceElements.contains(element)
    }

    private static func resolvedInactivePaneMute() -> Int {
        GhosttyApp.shared.inactivePaneMuteStrength
    }

    private static func resolvedWindowOpacity() -> Double {
        GhosttyApp.shared.windowOpacity
    }

    private static func resolvedSidebarShift() -> Int {
        GhosttyApp.shared.sidebarBackgroundShift
    }

    /// The terminal theme's foreground color, with a light fallback if libghostty hasn't reported one.
    private static func resolvedChromeText() -> Color {
        Color(nsColor: GhosttyApp.shared.terminalForegroundColor ?? .labelColor)
    }

    /// The base text with the action's current shortcut appended (`Toggle Sidebar (⌃⌘S)`), or bare when it
    /// has none — via the SAME `AppActions.shortcutGlyph` the palette uses, so a rebind shows the new chord.
    /// Non-private so the `+RecentSessions` attention button can build its tooltip.
    func helpHint(_ base: String, _ action: BuiltinAction) -> String {
        guard let glyph = actions.shortcutGlyph(for: action) else { return base }
        return "\(base) (\(glyph))"
    }

    /// The window-level overlays (quick terminal, palettes, Ctrl-Tab switcher) as one ZStack sibling INSIDE
    /// the body's root ZStack, not body-level `.overlay`s, so it can be inset below the titlebar and ordered
    /// BELOW `customTitlebar`. Every child is conditional, so an empty layer is not hit-testable and the
    /// terminal below stays interactive. Order here = z-order (switcher over palette over quick terminal).
    private var windowOverlayLayer: some View {
        ZStack {
            quickTerminalOverlay
            commandPaletteOverlay
            sessionSwitcherOverlay
            // opening the dashboard closes the three above, so ordering only settles the empty case.
            dashboardOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The scratch terminal centered at 90% of the window, framed by a hairline border and shadow so it reads
    /// as a distinct floating window over the content — libghostty renders only the terminal, so the frame is
    /// drawn here. The margin is a tap-catcher that dismisses on click and carries the same backdrop mute as
    /// a floating overlay. A dark scrim was rejected here and stays rejected: this layer is inset below the
    /// AppKit title bar, so anything painted over the body raises its opacity against unchanged chrome. The
    /// mute wash is neutral at full window opacity and `muteWashOpacity` scales it down under translucency,
    /// which shrinks the seam without closing it. The controller owns the surface, so hiding keeps the shell
    /// alive.
    @ViewBuilder private var quickTerminalOverlay: some View {
        if quickTerminal.isVisible {
            GeometryReader { geo in
                ZStack {
                    // the tap-catcher carries the `quick-terminal` accessibility id: a SwiftUI view is in
                    // the a11y tree (the Metal-backed `QuickTerminalPane` is not), so tests query this one.
                    // it spans the sidebar too, unlike the overlay's pane-scoped backdrop.
                    (store.activeSession.map { washColor(for: $0) } ?? terminalColor).opacity(muteWashOpacity)
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

    /// True only for the frontmost window: the palette and switcher are app-global singles on the frontmost
    /// store, so only that window mounts their overlays — else every open window renders a duplicate,
    /// contending for focus and showing the wrong window's candidates. `activeWindowID`
    /// (frontmost-or-first-open) matches exactly one window even before the first `didBecomeKey` sets
    /// `frontmostWindowID`, and is observed, so this reacts.
    private var isFrontmost: Bool { library.activeWindowID == windowID }

    /// Mounted only while a palette is open in the frontmost window; its content (search field + result
    /// list) is rebuilt from `palette.mode`.
    @ViewBuilder private var commandPaletteOverlay: some View {
        if isFrontmost, pick.pending == nil, palette.mode != nil {
            CommandPalette(controller: palette, actions: actions)
        }
    }

    /// Per-window rather than frontmost-global, so a caller can present one in a background window without
    /// duplicating it elsewhere. Selection reports the caller's original item index even though fuzzy
    /// filtering reorders the visible rows. Keyed by the pending id so a picker replacing another in the same
    /// view update gets fresh palette state, not the previous picker's rows and their captured items.
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
                initialQuery: pending.query,
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
    /// session at the default cwd or a picked directory) and two view toggles on the right (the workspace
    /// focus filter, the flagged working-set view). Each is hideable via Settings ▸ Interface (`shows(_:)`).
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
                // the only accessibility-observable read of the filter state.
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

/// Both native-fullscreen edges as ONE modifier on `WindowContentView`'s root chain: that body is at the
/// type checker's limit and two more `onReceive`s there fail to compile in reasonable time. The handler
/// reads the live style mask, so one closure serves both edges.
private struct FullscreenEdgeObserver: ViewModifier {
    let onEdge: (Notification) -> Void

    func body(content: Content) -> some View {
        let center = NotificationCenter.default
        return content
            .onReceive(center.publisher(for: NSWindow.didEnterFullScreenNotification), perform: onEdge)
            .onReceive(center.publisher(for: NSWindow.didExitFullScreenNotification), perform: onEdge)
    }
}
