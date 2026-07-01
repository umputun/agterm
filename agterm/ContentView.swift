import agtermCore
import AppKit
import SwiftUI

/// Top-level layout: the workspace/session sidebar on the left, the active
/// session's terminal surface on the right. The detail pane swaps surfaces via
/// `.id(session.id)` — each session gets its own `TerminalView` identity, so the
/// session-owned surfaces survive switching.
///
/// The sidebar is an AppKit `NSOutlineView` (`WorkspaceSidebar`) so cross-workspace
/// drag-and-drop works natively. The bottom bar holds two add affordances: a
/// workspace button and a session menu (New Session / Open Directory…).
struct ContentView: View {
    let library: WindowLibrary
    let makeSurface: (Session, AppStore) -> GhosttySurfaceView
    let makeSplitSurface: (Session, AppStore) -> GhosttySurfaceView
    let makeOverlaySurface: (Session, AppStore) -> GhosttySurfaceView
    let makeScratchSurface: (Session, AppStore) -> GhosttySurfaceView
    /// The `AGTERM_*` environment a window's quick terminal exposes (ENABLED + WINDOW_ID + SOCKET),
    /// resolved per window id. Threaded down so `WindowContentView` can bind its quick terminal's
    /// `envProvider` with its own window id.
    let quickTerminalEnv: (WindowInfo.ID) -> [String: String]
    let actions: AppActions
    let palette: PaletteController
    let sessionSwitcher: SessionSwitcher

    /// The resolved per-window store (lazy-loaded / created on appear). `nil` until resolved, or for
    /// a stray restored id with no library entry.
    @State private var store: AppStore?
    /// The id this window settled on (created for a nil `windowID`), used for frontmost/close
    /// reporting and the frame autosave name.
    @State private var resolvedID: WindowInfo.ID?

    /// Set when this window is a SwiftUI-restored stray with no library id to claim. The stray branch
    /// then closes the NSWindow via AppKit — SwiftUI's `@Environment(\.dismiss)` is unreliable for
    /// restored WindowGroup windows (they linger on screen as empty windows).
    @State private var isStray = false

    /// True when running under an isolated XCUITest (`AGTERM_STATE_DIR` set AND the
    /// `AGTERM_UITEST_FORCE_SIDEBAR_VISIBLE` env sentinel present). Gates the FB11763863 window-present
    /// workaround. The custom sidebar is always visible, so this no longer forces sidebar state; the
    /// env var keeps its historical name.
    static var isUITestLaunch: Bool {
        let process = ProcessInfo.processInfo
        // the sentinel rides launch ENVIRONMENT, not launch arguments: a process-launched SwiftUI
        // WindowGroup app fails to present its window under some launch-arg patterns on macOS 15+
        // (FB11763863). Env sidesteps that.
        return process.environment["AGTERM_STATE_DIR"] != nil
            && process.environment["AGTERM_UITEST_FORCE_SIDEBAR_VISIBLE"] != nil
    }

    var body: some View {
        Group {
            if let store, let resolvedID {
                WindowContentView(
                    windowID: resolvedID,
                    store: store,
                    library: library,
                    makeSurface: { makeSurface($0, store) },
                    makeSplitSurface: { makeSplitSurface($0, store) },
                    makeOverlaySurface: { makeOverlaySurface($0, store) },
                    makeScratchSurface: { makeScratchSurface($0, store) },
                    quickTerminalEnv: quickTerminalEnv,
                    actions: actions,
                    palette: palette,
                    sessionSwitcher: sessionSwitcher
                )
            } else if isStray {
                // a SwiftUI-restored stray beyond the app's open set: close its NSWindow via AppKit.
                Color.clear.background(StrayWindowCloser())
            } else {
                // transient: resolveStore hasn't run yet (or is still resolving).
                Color.clear
            }
        }
        .onAppear(perform: resolveStore)
    }

    /// Resolves the window's store once on appear by claiming the next open window id from the
    /// library's queue (the scene is a plain `WindowGroup`, so a window has no presented id). The
    /// launch window claims the launch id, additional `openWindow()`-opened windows claim the rest in
    /// order. A window beyond the open set — a SwiftUI-restored extra (Task 0 dedup-by-id) — gets no
    /// id and dismisses itself, so stale restoration state can't pile up windows. Idempotent —
    /// re-running with an already-resolved store is a no-op.
    private func resolveStore() {
        guard store == nil, !isStray else { return }
        guard let id = claimWindowID(),
              let resolved = library.store(for: id) ?? library.loadStore(for: id) else {
            isStray = true
            return
        }
        store = resolved
        resolvedID = id
        // reopening a window loads an @ObservationIgnored store, which the Dock badge's observation can't
        // see (symmetric to the willClose close poke) — recompute so a reopened window's unseen total counts.
        DockBadgeController.shared.refresh()
    }

    /// The window id this view adopts: normally the next id in the library's claim queue. If the
    /// queue is empty before the launch reopen-all has seeded it (the scene `.task` may not have run
    /// `consumeReopen()` when this `.onAppear` fires), adopt the launch id rather than dismissing the
    /// launch window — `adoptLaunchWindowID()` records it so the later `consumeReopen()` excludes it
    /// from the seeded queue (no second window claims it). Once the queue has been seeded
    /// (`hasReopened`), an empty queue genuinely means this is a SwiftUI-restored stray, so return nil
    /// and let the caller dismiss it.
    private func claimWindowID() -> WindowInfo.ID? {
        if let id = library.claimNextWindowID() { return id }
        return library.hasReopened ? nil : library.adoptLaunchWindowID()
    }
}

/// Closes a SwiftUI-restored stray `WindowGroup` window via AppKit. SwiftUI's `@Environment(\.dismiss)`
/// is unreliable for restored windows — they linger on screen as empty windows — so this reaches the
/// backing `NSWindow` and `close()`s it directly. It also clears `isRestorable` so SwiftUI stops
/// persisting + re-restoring this stray on the next launch.
private struct StrayWindowCloser: NSViewRepresentable {
    func makeNSView(context _: Context) -> ClosingView { ClosingView() }
    func updateNSView(_ view: ClosingView, context _: Context) { view.closeIfNeeded() }

    final class ClosingView: NSView {
        private weak var closingWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            closeIfNeeded()
        }

        func closeIfNeeded() {
            guard let window, closingWindow !== window else { return }
            closingWindow = window
            window.isRestorable = false
            window.restorationClass = nil
            window.disableSnapshotRestoration()
            window.invalidateRestorableState()
            // defer past the current presentation/attach pass so the close lands cleanly.
            DispatchQueue.main.async { [weak window] in
                window?.close()
                DispatchQueue.main.async { [weak window] in
                    window?.orderOut(nil)
                    window?.close()
                }
            }
        }
    }
}

/// The actual per-window UI: the workspace/session sidebar + the active session's terminal, plus
/// the quick-terminal / palette / switcher overlays. Holds the resolved non-optional `AppStore` so
/// the binding-based wiring is unchanged from the single-window version; `ContentView` resolves the
/// store and hands it in.
private struct WindowContentView: View {
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
    /// This window's own quick terminal, owned here (one per window). Registered in
    /// `QuickTerminalRegistry` on appear so the frontmost-window call sites can reach it, and its
    /// `cwdProvider` binds to this window's active session.
    @State private var quickTerminal = QuickTerminalController()
    /// The terminal background color, mirrored from the (non-observable) `GhosttyApp` into view
    /// state and used as the quick terminal's opaque backing, so a settings theme change (posting
    /// `.agtermAppearanceChanged`) re-renders it live.
    @State private var terminalColor: Color = WindowContentView.resolvedTerminalColor()
    /// Mirror of `GhosttyApp.compactToolbar`: when true the cwd subtitle is dropped so the title bar
    /// collapses to a single line. Refreshed on `.agtermAppearanceChanged`, like `terminalColor`.
    @State private var compactToolbar: Bool = WindowContentView.resolvedCompactToolbar()
    /// Mirror of `GhosttyApp.inactivePaneMuteStrength` (0...10): how strongly `paneDim` mutes the
    /// inactive split pane's text. Refreshed on `.agtermAppearanceChanged`, like `compactToolbar`.
    @State private var inactivePaneMute: Int = WindowContentView.resolvedInactivePaneMute()
    /// Mirror of `GhosttyApp.sidebarBackgroundShift` (0...10, 5 = neutral): how much lighter/darker the
    /// sidebar background is than the terminal. Drives `sidebarTintWash`; refreshed on
    /// `.agtermAppearanceChanged`, like `inactivePaneMute`.
    @State private var sidebarShift: Int = WindowContentView.resolvedSidebarShift()
    /// The terminal theme's foreground color, mirrored from `GhosttyApp` and used for the chrome text
    /// (title bar text + buttons, sidebar bottom bar) so non-terminal text tracks the theme. Refreshed
    /// on `.agtermAppearanceChanged`, like `terminalColor`.
    @State private var chromeText: Color = WindowContentView.resolvedChromeText()
    /// Mirror of `GhosttyApp.attentionButtonEnabled`: when true the title bar shows the attention bell.
    /// Refreshed on `.agtermAppearanceChanged`, like `compactToolbar`, so flipping the Settings toggle
    /// shows/hides the bell live without a relaunch.
    @State private var attentionButtonEnabled: Bool = WindowContentView.resolvedAttentionButtonEnabled()
    /// Custom sidebar width and show/hide both live on the per-window `AppStore` (`sidebarWidth` /
    /// `sidebarVisible`), persisted in `Snapshot` so they restore on relaunch. The toolbar button, the View
    /// menu, the palette, and the `sidebar` control command share `sidebarVisible`.
    /// Height of the custom titlebar row: one short line in compact mode, two lines (title + cwd)
    /// otherwise. The split content is inset by this so it sits below the row.
    private var titlebarHeight: CGFloat { compactToolbar ? 30 : 48 }

    var body: some View {
        ZStack(alignment: .top) {
            // the split's AppKit HSplitView overruns its frame up into the titlebar zone and would
            // steal the header's clicks; keep the header in front (highest zIndex) and inset the split
            // content below it so the buttons stay hittable in split mode.
            splitRoot
                .padding(.top, titlebarHeight)
            // the window overlays (quick terminal / palettes / switcher) sit BELOW the titlebar, inset by
            // its height — NOT as a body-level `.overlay` above EVERYTHING. A full-window overlay's dim
            // scrim composites OVER the transparent custom titlebar (whose AppKit backing is deliberately
            // hidden for translucency, WindowAppearance), darkening + seaming the tall non-compact titlebar
            // (the corruption). Keeping the titlebar at the highest zIndex means a scrim can never cover it.
            windowOverlayLayer
                .padding(.top, titlebarHeight)
                .zIndex(1)
            customTitlebar
                .zIndex(2)
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
        // when the quick terminal hides, return focus to the active session's terminal.
        .onChange(of: quickTerminal.isVisible) { _, visible in
            if !visible { actions.focusActiveSession() }
        }
        // when a palette closes, return focus to the active session's terminal.
        .onChange(of: palette.mode == nil) { _, closed in
            if closed { actions.focusActiveSession() }
        }
        // a settings appearance change isn't observable through GhosttyApp, so re-render on the
        // notification to pick up the new terminal color in the quick terminal backing.
        .onReceive(NotificationCenter.default.publisher(for: .agtermAppearanceChanged)) { _ in
            terminalColor = WindowContentView.resolvedTerminalColor()
            compactToolbar = WindowContentView.resolvedCompactToolbar()
            chromeText = WindowContentView.resolvedChromeText()
            attentionButtonEnabled = WindowContentView.resolvedAttentionButtonEnabled()
            inactivePaneMute = WindowContentView.resolvedInactivePaneMute()
            sidebarShift = WindowContentView.resolvedSidebarShift()
        }
        // blend the title bar with the terminal; report frontmost/close to the library; surface the
        // window un-minimized on launch. the title token makes updateNSView re-run the blend on a
        // session switch.
        .background(WindowAccessor(titleToken: windowTitle, windowID: windowID, library: library, store: store))
        // own a per-window quick terminal: register it so the frontmost-window call sites resolve it,
        // and spawn its shell in THIS window's active session's directory.
        .onAppear {
            quickTerminal.cwdProvider = { [store] in
                store.activeSession?.effectiveCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            }
            // the quick terminal's shell sees this window's AGTERM_* env (scratch: ENABLED + WINDOW_ID + SOCKET).
            quickTerminal.envProvider = { [quickTerminalEnv, windowID] in quickTerminalEnv(windowID) }
            QuickTerminalRegistry.shared.register(windowID, controller: quickTerminal)
        }
        .onDisappear { QuickTerminalRegistry.shared.unregister(windowID) }
    }

    /// EXPERIMENT (custom-sidebar branch): our own split instead of `NavigationSplitView`, so macOS 26
    /// doesn't impose the Liquid-Glass sidebar chrome (inset panel, toggle capsule) or couple it to the
    /// toolbar style. A plain `HStack` gives the sidebar tree + a themed draggable divider + the terminal.
    @ViewBuilder private var splitRoot: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible {
                sidebarColumn
                    .frame(width: CGFloat(store.sidebarWidth))
                sidebarDivider
                    // draw/hit above the terminal: the divider is the middle HStack child, so without this
                    // the detail column (drawn last) shadows the right half of the grab handle, leaving only
                    // a few points grabbable. zIndex lifts the whole handle on top so the full strip works.
                    .zIndex(1)
            }
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // animate the collapse/expand uniformly, whatever flips the flag (toolbar button, menu, palette,
        // control), now that the toggle no longer wraps its own `withAnimation`.
        .animation(.easeInOut(duration: 0.15), value: store.sidebarVisible)
        // animate the tree↔flagged sidebar mode switch the same way, for every caller (bottom-bar
        // toggle, menu, palette, control).
        .animation(.easeInOut(duration: 0.15), value: store.sidebarMode)
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            // matches the detail pane's hairline so the line continues across the full width under
            // the title bar (the vertical divider hangs from it at the sidebar/terminal junction).
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
            WorkspaceSidebar(store: store, actions: actions)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        // the lighter/darker sidebar tint: a wash behind the transparent outline + bottom bar, so the
        // whole column reads as one surface a touch darker/lighter than the terminal. Behind the column
        // content (so it never tints row text) and over the window background (so it composes with
        // translucency/blur). Neutral paints nothing.
        .background(sidebarTintWash)
    }

    /// The sidebar lighter/darker wash for the current `sidebarShift`: black (darker) or white (lighter)
    /// at the shift's magnitude, composited over the window background. Compositing this over the window
    /// background equals blending the terminal color toward black/white, and works the same over an
    /// opaque or a translucent+blurred backdrop. Neutral (`amount == 0`) renders nothing.
    @ViewBuilder private var sidebarTintWash: some View {
        let amount = AppSettings.sidebarShiftAmount(strength: sidebarShift)
        if amount != 0 {
            Color(white: amount > 0 ? 0 : 1).opacity(abs(amount))
        }
    }

    /// A 1px themed vertical separator with a wider invisible drag handle to resize the sidebar. The
    /// handle is wider than the line and the divider carries `.zIndex(1)` at the call site so the full
    /// grab strip is reachable from both sides (the terminal column would otherwise shadow its right half).
    private var sidebarDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
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
                        // drive width from the absolute cursor X (window coords), NOT accumulated
                        // translation: the divider moves with the width, so translation-based resize
                        // feeds back on itself and the line flickers. Absolute position is stable.
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
            // a subtle hairline between the title bar and the terminal; lives in the
            // detail pane so it starts at the sidebar's right edge, not the full width.
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // the floating overlay panel, anchored on the detail (terminal) area so its GeometryReader
                // reports that area exactly — correct centering, no manual sidebar/titlebar insets. It sits
                // OUTSIDE each session's HSplitView-hosting ZStack, so opening it never perturbs the split.
                .overlay { floatingOverlayLayer }
                // the search bar, anchored at the SAME `detailPane` level as the floating overlay (never
                // inside `sessionDetail`'s HSplitView ZStack) so toggling it can't overrun the NSSplitView
                // up into the titlebar. Sits at the top-right of the detail area, like a standard find bar.
                .overlay(alignment: .topTrailing) { searchBarLayer }
        }
    }

    /// The terminal area: a DECK of EVERY session's terminal, all mounted so each is realized (its
    /// shell spawned) at startup, with only the selected one visible + hit-testable. Switching is a
    /// visibility flip, not a re-host, so the surface NSView is never detached/re-attached (re-hosting
    /// invalidates the Metal drawable and flickers). A placeholder shows behind when nothing is selected.
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
    /// maximized hidden-split pane, plus any overlay. `isActive` gates which pane auto-grabs focus —
    /// only the visible deck entry, and within a split only the focused pane.
    @ViewBuilder private func sessionDetail(_ session: Session, isActive: Bool) -> some View {
        // a FULL overlay (no size) hides the session beneath it (opacity 0) and draws translucent; a
        // FLOATING overlay (overlaySizePercent set) leaves the session VISIBLE and draws a smaller
        // opaque framed panel on top. Either way the pane(s) stay non-interactive while an overlay is up.
        let fullOverlay = session.overlayActive && session.overlaySizePercent == nil
        // the scratch terminal is a full-coverage overlay too, so it hides the pane(s) exactly like a
        // FULL overlay; `hideForOverlay` drives opacity + hit-testing. `overlaid` (any overlay OR scratch)
        // is what owns focus, so it gates the pane(s)' `isActive` (focus goes to the overlay/scratch, not
        // the pane). NOTE `hideForOverlay` stays false for a FLOATING overlay — preserving the rule that
        // this subtree's shape/hit-testing must not change when a floating overlay opens (NSSplitView overrun).
        let hideForOverlay = fullOverlay || session.scratchActive
        let overlaid = session.overlayActive || session.scratchActive
        // on-screen = selected session, not hidden by a full overlay/scratch. Shared by BOTH split panes
        // (unlike the focus-gated `isActive`), it gates each surface's drag-type (un)registration so a file
        // drop lands on the visible pane, not an invisible background deck surface (matches the panes' hit-testing).
        let visible = isActive && !hideForOverlay
        ZStack {
            // the session's pane(s), kept MOUNTED while an overlay is up — shells stay alive, like the deck
            // does for inactive sessions. a FULL overlay hides them (opacity 0) so its translucency reveals the
            // window backing, not the session; a FLOATING overlay leaves them visible behind its opaque panel.
            Group {
                if session.isSplit {
                    HSplitView {
                        TerminalView(session: session, surfaceKeyPath: \.surface, makeSurface: makeSurface,
                                     isActive: isActive && !session.splitFocused && !overlaid, deckVisible: visible)
                            .overlay { paneDim(session.splitFocused) }
                            // introspects the AppKit NSSplitView to persist/restore the divider ratio AND to
                            // clip its divider out of the titlebar strip (see SplitRatioAccessor); a background
                            // (not a third pane), unconditional so it never perturbs the split shape.
                            .background { SplitRatioAccessor(session: session, titlebarHeight: titlebarHeight, onPersist: { store.save() }) }
                            .id(session.id)
                        TerminalView(session: session, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface,
                                     isActive: isActive && session.splitFocused && !overlaid, deckVisible: visible)
                            .overlay { paneDim(!session.splitFocused) }
                            .id("\(session.id.uuidString)-split")
                    }
                    // per-session identity: without it SwiftUI reuses one NSSplitView across session
                    // switches and the divider (and arranged subviews) leak between sessions.
                    .id("\(session.id.uuidString)-hsplit")
                } else if session.splitFocused, session.splitSurface != nil {
                    // split hidden while the right pane had focus: show that pane maximized.
                    TerminalView(session: session, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface,
                                 isActive: isActive && !overlaid, deckVisible: visible)
                        .id("\(session.id.uuidString)-split")
                } else {
                    TerminalView(session: session, surfaceKeyPath: \.surface, makeSurface: makeSurface,
                                 isActive: isActive && !overlaid, deckVisible: visible)
                        .id(session.id)
                }
            }
            .opacity(hideForOverlay ? 0 : 1)
            // gate hit-testing on `hideForOverlay` (full overlay OR scratch), NOT `session.overlayActive`:
            // this modifier must NOT change when a floating overlay opens, or the AppKit NSSplitView
            // re-lays-out and overruns up into the titlebar (same class of perturbation as adding a sibling).
            // a floating overlay therefore leaves the panes hit-testable here; `floatingOverlayLayer`'s
            // transparent catcher absorbs clicks around the panel so they can't reach the panes.
            .allowsHitTesting(!hideForOverlay)
            // the scratch terminal renders here, in-deck, above the (hidden) pane(s) — like the FULL overlay,
            // a full-coverage sibling is safe (the panes go opacity 0, the split's frame is hidden). It sits
            // BELOW the ephemeral overlay (zIndex 1 vs 2) so a normal overlay launched over the scratch is on
            // top. The FLOATING overlay is deliberately NOT a sibling here (it renders as a `detailPane`
            // `.overlay`), since adding a child while the panes stay VISIBLE overruns the NSSplitView.
            if session.scratchActive {
                // gate focus on every surface that covers the scratch — a full overlay (renders above it,
                // zIndex 2) AND the window-level quick terminal — so the deck's focusIfNeeded can't grab the
                // scratch behind them. When the cover goes away, isActive flips true and the deck re-grabs it.
                // (matches the autoFocus suppression in makeScratchSurface.)
                TerminalView(session: session, surfaceKeyPath: \.scratchSurface, makeSurface: makeScratchSurface,
                             isActive: isActive && !session.overlayActive && !quickTerminal.isVisible)
                    .id("\(session.id.uuidString)-scratch")
                    .zIndex(1)
            }
            if fullOverlay {
                TerminalView(session: session, surfaceKeyPath: \.overlaySurface,
                             makeSurface: makeOverlaySurface, isActive: isActive)
                    .id("\(session.id.uuidString)-overlay")
                    .zIndex(2)
            }
        }
        // when the overlay closes, the underlying pane must reclaim first responder. the pane re-activating
        // only does a single makeFirstResponder, which loses the race with the overlay view's teardown/
        // re-host — so drive the bounded retry the split-collapse survivor uses. gated on isActive so only
        // the visible session reclaims focus.
        // on overlay close, refocus the topmost remaining surface (scratch if still shown, else the pane)
        // via the shared `topmostSurface` precedence — never a pane hidden under the scratch, and not at all
        // while the quick terminal covers the window (it owns focus; its own hide restores the session).
        .onChange(of: session.overlayActive) { _, isOpen in
            if !isOpen, isActive, !quickTerminal.isVisible {
                (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
            }
            // a keymap-edit overlay just closed → reapply the edited keymap.
            if !isOpen, actions.keymapEditOverlaySession == session.id {
                actions.keymapEditOverlaySession = nil
                actions.reloadKeymap()
            }
            // a ghostty.conf-edit overlay just closed → reload the edited ghostty config (skipped when the
            // file is unchanged, so a no-op editor session keeps per-session font zoom).
            if !isOpen, actions.ghosttyEditOverlaySession == session.id {
                actions.ghosttyEditOverlaySession = nil
                actions.reloadGhosttyConfigIfEdited()
            }
        }
        // scratch show AND hide both need the bounded focus retry: the surface is kept alive across hides,
        // so a re-show remounts it and `autoFocus`'s one-shot latch won't re-fire (same remount race as the
        // split-collapse survivor). `topmostSurface` routes focus correctly either way — on show it is the
        // scratch (or a still-open overlay above it), on hide the overlay-if-up else the pane.
        .onChange(of: session.scratchActive) { _, _ in
            // skip while the quick terminal covers the window — it owns focus above the session layers
            // (mirrors focusActiveSession); the deck re-grabs the scratch when the quick terminal hides.
            guard isActive, !quickTerminal.isVisible else { return }
            (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
        }
    }

    /// The FLOATING overlay, attached as an `.overlay` on `detailPane` (NOT inside any session's
    /// `sessionDetail`/HSplitView ZStack, so opening it never perturbs the split layout). Anchoring it on
    /// `detailPane` means the `GeometryReader` reports the terminal area EXACTLY — no manual sidebar/titlebar
    /// insets (computing those at the window level mis-positioned the panel one line low). The panel is an
    /// opaque, framed terminal sized to `overlaySizePercent`% of the detail area and centered in it, with the
    /// active session's pane(s) visible around it. Only the active session's overlay shows — overlays are
    /// active-session UI — so `ControlServer` selects the target when opening a floating overlay, ensuring its
    /// surface mounts and its program runs (otherwise a `--block` open on a non-active target would hang).
    @ViewBuilder private var floatingOverlayLayer: some View {
        if let session = store.activeSession, session.overlayActive, let percent = session.overlaySizePercent {
            GeometryReader { geo in
                let fraction = CGFloat(percent) / 100
                ZStack {
                    // a transparent click-catcher over the whole detail area: it absorbs clicks AROUND the
                    // panel so they can't reach the still-hit-testable panes behind and steal the overlay's
                    // first responder. it lives here (the detailPane `.overlay`), NOT in `sessionDetail`, so
                    // unlike toggling the panes' own `allowsHitTesting` it never perturbs the NSSplitView.
                    Color.clear.contentShape(Rectangle())
                    TerminalView(session: session, surfaceKeyPath: \.overlaySurface,
                                 makeSurface: makeOverlaySurface, isActive: true)
                        .frame(width: geo.size.width * fraction, height: geo.size.height * fraction)
                        // solid backing + hairline frame + shadow so the floating panel reads as a distinct
                        // opaque window over the still-visible session (libghostty draws only the terminal).
                        .background(terminalColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(radius: 24)
                        .id("\(session.id.uuidString)-overlay")
                }
                // center the panel (and span the catcher) within the detail area (the GeometryReader is it).
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// The terminal search bar, attached as a top-aligned `.overlay` on `detailPane` (the SAME level as
    /// `floatingOverlayLayer`, NOT inside any session's `sessionDetail`/HSplitView ZStack — so opening it
    /// never perturbs the split and overruns the NSSplitView into the titlebar). Shown only while the active
    /// session's `searchActive` is set; the needle binding drives the query through `actions.updateSearchNeedle`.
    @ViewBuilder private var searchBarLayer: some View {
        if let session = store.activeSession, session.searchActive {
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

    /// Mutes the inactive split pane's TEXT so the active pane stands out, WITHOUT darkening the
    /// background: a translucent wash of the terminal background color over the pane. Background pixels
    /// blend bg→bg (unchanged), text pixels blend text→bg (less bright) — the way other terminals dim an
    /// inactive pane. The opacity comes from the Settings mute-strength slider (0...10) via
    /// `AppSettings.muteOpacity`, so strength 0 renders nothing. Clicks pass through
    /// (`allowsHitTesting(false)`) so the muted pane can still be focused; `dimmed == false` renders nothing.
    @ViewBuilder private func paneDim(_ dimmed: Bool) -> some View {
        let opacity = AppSettings.muteOpacity(strength: inactivePaneMute)
        if dimmed, opacity > 0 {
            terminalColor.opacity(opacity).allowsHitTesting(false)
        }
    }

    /// The terminal background color from the ghostty config (a dark fallback if libghostty hasn't
    /// reported one), used as the quick terminal's opaque backing. Read into the `terminalColor`
    /// view state so it re-renders when the theme changes.
    private static func resolvedTerminalColor() -> Color {
        Color(nsColor: GhosttyApp.shared.terminalBackgroundColor
            ?? NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1))
    }

    /// The compact-toolbar flag from the (non-observable) `GhosttyApp`, mirrored into view state so a
    /// settings change (posting `.agtermAppearanceChanged`) drops/restores the cwd subtitle live.
    private static func resolvedCompactToolbar() -> Bool {
        GhosttyApp.shared.compactToolbar
    }

    /// The attention-button flag from the (non-observable) `GhosttyApp`, mirrored into view state so a
    /// settings change (posting `.agtermAppearanceChanged`) shows/hides the title bar bell live.
    private static func resolvedAttentionButtonEnabled() -> Bool {
        GhosttyApp.shared.attentionButtonEnabled
    }

    /// The inactive-pane mute strength from the (non-observable) `GhosttyApp`, mirrored into view state
    /// so a settings change (posting `.agtermAppearanceChanged`) re-renders the inactive pane live.
    private static func resolvedInactivePaneMute() -> Int {
        GhosttyApp.shared.inactivePaneMuteStrength
    }

    /// The sidebar background shift from the (non-observable) `GhosttyApp`, mirrored into view state so a
    /// settings change (posting `.agtermAppearanceChanged`) re-tints the sidebar wash live.
    private static func resolvedSidebarShift() -> Int {
        GhosttyApp.shared.sidebarBackgroundShift
    }

    /// The terminal theme's foreground color (a light fallback if libghostty hasn't reported one),
    /// mirrored into view state so a theme change re-tints the chrome text live.
    private static func resolvedChromeText() -> Color {
        Color(nsColor: GhosttyApp.shared.terminalForegroundColor ?? .labelColor)
    }

    /// The titlebar title (first line): the active session's display name, suffixed with the window
    /// name as "session — window" when the window has a custom (user-set) name, so a renamed window
    /// is identifiable at a glance. Auto "window N" names are omitted. "agterm" when nothing is selected.
    private var windowTitle: String {
        let session = store.activeSession?.displayName ?? "agterm"
        guard let info = library.windows.first(where: { $0.id == windowID }), info.hasCustomName else {
            return session
        }
        return "\(session) — \(info.name)"
    }

    /// The titlebar subtitle (second line): the focused pane's `subtitleDetail` — its terminal title for
    /// a remote (SSH) session whose local cwd is stale, else its working directory (the split pane's while
    /// it's focused, else the primary's). Dropped in compact mode so the title bar is a single short row.
    private var windowSubtitle: String {
        compactToolbar ? "" : (store.activeSession?.subtitleDetail ?? "")
    }

    /// The window title at the terminal's leading edge: the session name, plus the cwd subtitle on a
    /// second line when not in compact mode (compact drops it for a single short row).
    private var titleLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(windowTitle).fontWeight(.semibold)
            if !compactToolbar, !windowSubtitle.isEmpty {
                Text(windowSubtitle)
                    .font(.caption)
                    .foregroundStyle(chromeText.opacity(0.6))
            }
        }
    }

    /// Custom titlebar row replacing the system toolbar: the sidebar toggle pinned to the sidebar's
    /// trailing edge (by the divider), the title at the terminal's start, and the split / quick-terminal
    /// buttons at the trailing edge. Positions track `sidebarWidth`; the left inset clears the system
    /// traffic lights.
    private var customTitlebar: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 78).allowsHitTesting(false) // system traffic lights
            if store.sidebarVisible {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    sidebarToggleButton.labelStyle(.iconOnly)
                }
                .frame(width: max(40, CGFloat(store.sidebarWidth) - 78))
                Color.clear.frame(width: 11).allowsHitTesting(false) // 1px divider + gap to the title
            } else {
                sidebarToggleButton.labelStyle(.iconOnly)
                Spacer().frame(width: 12)
            }
            titleLabel
                // the title text falls through to the drag/zoom layer behind it (see `.background` below),
                // so double-clicking it zooms and dragging it moves the window — the rest of the row is
                // empty spacers (already non-hittable) and the buttons, which keep their own clicks.
                .allowsHitTesting(false)
            if attentionButtonEnabled {
                attentionButton.labelStyle(.iconOnly).padding(.leading, 10)
            }
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                scratchButton.labelStyle(.iconOnly)
                splitButton.labelStyle(.iconOnly)
                // separates the per-session view toggles (scratch/split) from the window-level quick terminal.
                Rectangle().fill(chromeText.opacity(0.25)).frame(width: 1, height: 16)
                quickTerminalButton.labelStyle(.iconOnly)
            }
            .padding(.trailing, 14)
        }
        .buttonStyle(.plain)
        // tint the title text and the toolbar buttons with the terminal theme's foreground so the
        // chrome tracks the theme (the cwd subtitle dims itself to 0.6 over this).
        .foregroundStyle(chromeText)
        // larger icons in the taller non-compact row, smaller in the compact row (imageScale hits the
        // SF Symbols, not the title text).
        .imageScale(compactToolbar ? .medium : .large)
        .frame(height: titlebarHeight)
        .frame(maxWidth: .infinity)
        // make the header behave like a standard title bar: single-click drag moves the window, double-click
        // runs the user's configured title-bar action (zoom/minimize/none). The layer sits BEHIND the row,
        // so the buttons render in front and keep their clicks; the empty spacers + the title text opt out of
        // hit-testing (above) so their region falls through to it. Custom titlebar = no native title-bar
        // double-click handling, hence this.
        .background { WindowControlArea() }
    }

    /// A tooltip string with the action's current shortcut appended in parentheses (e.g. `Toggle
    /// Sidebar (⌃⌘S)`), or just the base text when the action has no configured shortcut. Keeps the
    /// toolbar/sidebar hints in lockstep with the keymap — a rebind shows the new chord, an unbound
    /// action shows none — via the SAME `AppActions.shortcutGlyph` resolver the action palette uses.
    private func helpHint(_ base: String, _ action: BuiltinAction) -> String {
        guard let glyph = actions.shortcutGlyph(for: action) else { return base }
        return "\(base) (\(glyph))"
    }

    /// Our own sidebar show/hide toggle (the custom split has no system one). Animated collapse.
    private var sidebarToggleButton: some View {
        Button {
            actions.toggleSidebar()
        } label: {
            Label("Toggle Sidebar", systemImage: "sidebar.left")
        }
        .help(helpHint("Toggle Sidebar", .toggleSidebar))
        .accessibilityIdentifier("sidebar-toggle-button")
    }

    private var splitButton: some View {
        let isSplit = store.activeSession?.isSplit ?? false
        let hasSplit = store.activeSession?.hasSplit ?? false
        let splitFocused = store.activeSession?.splitFocused ?? false
        // filled = pane visible, outline = hidden. no split: an empty two-pane outline. split shown: both
        // panes filled. collapsed to a single pane (hasSplit but not shown): only the VISIBLE pane's half
        // is filled — left for the primary, right for the split pane (`splitFocused` is the shown one when
        // hidden) — so the glyph tells you which pane is up and that the other is parked. `a11y` mirrors the
        // four states for XCUITest, which can't read the symbol name (like the attention bell's value).
        let symbol: String
        let a11y: String
        if !hasSplit {
            symbol = "rectangle.split.2x1"; a11y = "none"
        } else if isSplit {
            symbol = "rectangle.split.2x1.fill"; a11y = "both"
        } else if splitFocused {
            symbol = "rectangle.righthalf.filled"; a11y = "right"
        } else {
            symbol = "rectangle.lefthalf.filled"; a11y = "left"
        }
        return Button {
            actions.toggleSplit()
        } label: {
            // a Label (icon + title) so the toolbar's "Icon and Text" mode has text to show; the title
            // is hidden in the default icon-only mode.
            Label("Split", systemImage: symbol)
        }
        .help(helpHint(isSplit ? "Hide split" : (hasSplit ? "Show split" : "Split right"), .toggleSplit))
        .disabled(store.activeSession == nil)
        .accessibilityValue(a11y)
        .accessibilityIdentifier("split-toggle")
    }

    /// Toolbar button that toggles the active session's scratch terminal — a third, full-overlay login
    /// shell, kept alive when hidden. 2-state glyph (filled while shown): unlike the split there is no
    /// "hidden but exists" indicator, since the shell's own `exit` clears it and the next show is fresh.
    private var scratchButton: some View {
        let active = store.activeSession?.scratchActive ?? false
        return Button {
            actions.toggleScratch()
        } label: {
            Label("Scratch", systemImage: active ? "rectangle.inset.filled" : "rectangle")
        }
        .help(helpHint(active ? "Hide scratch terminal" : "Show scratch terminal", .toggleScratch))
        .disabled(store.activeSession == nil)
        .accessibilityIdentifier("scratch-toggle")
    }

    /// Toolbar button (next to the split toggle) that toggles the quick terminal: a single
    /// scratch terminal overlaid at 90% of the window, on top of the sidebar and terminal.
    /// Click the button again or the surrounding margin to hide; the shell stays alive until quit.
    private var quickTerminalButton: some View {
        Button {
            quickTerminal.toggle()
        } label: {
            Label("Quick Terminal", systemImage: "terminal")
        }
        .help(helpHint("Quick Terminal", .quickTerminal))
        .accessibilityIdentifier("quick-terminal-toggle")
    }

    /// Title-bar bell reflecting the window's attention state at a glance (opt-in, gated by the
    /// `attentionButtonEnabled` mirror). Three states from `store.attentionSessions`: empty → a dimmed
    /// disabled outline bell; non-empty with nothing blocked → a plain enabled bell in `chromeText`; any
    /// blocked session → a filled bell tinted the blocked-status color. No count, no pulse. Click opens
    /// the `.attention` palette. Reading `store.attentionSessions` in the body registers the per-session
    /// `agentIndicator` observation, so the glyph re-renders live as a status changes. `.accessibilityValue`
    /// (none|attention|blocked) exposes the otherwise-unobservable bell↔bell.fill state to XCUITest,
    /// mirroring `StatusIconView`'s state-name value.
    private var attentionButton: some View {
        let sessions = store.attentionSessions
        let blocked = sessions.contains { $0.agentIndicator.status == .blocked }
        let empty = sessions.isEmpty
        return Button {
            actions.toggleAttentionPalette()
        } label: {
            Label("Attention", systemImage: blocked ? "bell.fill" : "bell")
        }
        .foregroundStyle(blocked ? Color(nsColor: GhosttyApp.shared.blockedStatusColor) : chromeText)
        .opacity(empty ? 0.35 : 1)
        .disabled(empty)
        .help(helpHint(empty ? "No sessions need attention" : "Show sessions that need attention", .showAttention))
        .accessibilityIdentifier("attention-button")
        .accessibilityValue(empty ? "none" : (blocked ? "blocked" : "attention"))
    }

    /// The quick-terminal overlay: the scratch terminal centered at 90% of the window, framed by a
    /// hairline border and shadow so it reads as a distinct floating window over the (undimmed)
    /// content. libghostty renders only the terminal content, so the frame is drawn here. The margin
    /// is a transparent tap-catcher that dismisses on click — no darkening, because the overlay
    /// can't cover the AppKit title bar, so a dim would shade the body but not the chrome. Rendered
    /// only while visible; the surface it hosts is owned by the controller, so hiding keeps the
    /// shell alive.
    /// The window-level overlays (quick terminal, command palettes, Ctrl-Tab switcher) as one layer,
    /// rendered as a ZStack sibling INSIDE the body's root ZStack rather than as body-level `.overlay`s —
    /// so it can be inset below the titlebar and ordered BELOW `customTitlebar` (which a body-level
    /// `.overlay` cannot). Each child is conditional, so when none is showing this is empty (an empty
    /// frame is not hit-testable, so the terminal below stays interactive); each overlay's own
    /// `GeometryReader` fills the inset area. Order here = z-order (switcher on top of palette on top of
    /// quick terminal), matching the previous `.overlay` stacking.
    private var windowOverlayLayer: some View {
        ZStack {
            quickTerminalOverlay
            commandPaletteOverlay
            sessionSwitcherOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var quickTerminalOverlay: some View {
        if quickTerminal.isVisible {
            GeometryReader { geo in
                ZStack {
                    // the transparent tap-catcher also carries the `quick-terminal` accessibility id:
                    // a SwiftUI view is exposed in the accessibility tree (the Metal-backed
                    // `QuickTerminalPane` is not), so this is the element control-API tests query for.
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

    /// True only for the frontmost window. The palette and session switcher are app-global single
    /// instances (they act on the frontmost store), so only the frontmost window mounts their
    /// overlays — otherwise every open window would render a duplicate overlay, contending for focus
    /// and showing the wrong window's candidates. Uses `activeWindowID` (frontmost-or-first-open, the
    /// same accessor the palette/actions resolve through), so exactly one window matches even before
    /// the first `didBecomeKey` sets `frontmostWindowID`. Reactive: `frontmostWindowID` is observed.
    private var isFrontmost: Bool { library.activeWindowID == windowID }

    /// The command-palette overlay, mounted only while a palette is open in the frontmost window. Its
    /// content (search field + result list) is rebuilt from `palette.mode`.
    @ViewBuilder private var commandPaletteOverlay: some View {
        if isFrontmost, palette.mode != nil {
            CommandPalette(controller: palette, actions: actions)
        }
    }

    /// The Ctrl-Tab session switcher overlay, mounted only while cycling in the frontmost window.
    @ViewBuilder private var sessionSwitcherOverlay: some View {
        if isFrontmost, sessionSwitcher.isActive {
            SessionSwitcherOverlay(switcher: sessionSwitcher, store: store)
        }
    }

    /// Two distinct add controls, source-list style: add a workspace, and a menu
    /// to add a session to the current workspace (default cwd) or a picked directory.
    private var bottomBar: some View {
        HStack(spacing: 2) {
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

            Spacer()

            // an escape hatch shown only while a workspace is focused: names the focused workspace and
            // unfocuses on its ✕ (the primary affordance; the menu/palette "Clear Focus" mirror it).
            if let focused = store.focusedWorkspace {
                Button {
                    actions.clearFocus()
                } label: {
                    HStack(spacing: 4) {
                        Text(focused.name)
                            .lineLimit(1)
                        Image(systemName: "xmark")
                    }
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(chromeText.opacity(0.15)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .help("Clear focus")
                .accessibilityLabel("Clear focus")
                .accessibilityIdentifier("focus-pill")
            }

            // flip the sidebar between the workspace tree and the flat flagged working-set list. 2-state
            // glyph (filled in flagged mode); the switch animates via splitRoot's `.animation(value:)`.
            Button {
                actions.toggleFlaggedView()
            } label: {
                let flagged = store.sidebarMode == .flagged
                Image(systemName: flagged ? "flag.fill" : "flag")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            // nothing to show: disable entering an empty flagged view (tree mode + no flags). Stays
            // enabled in flagged mode so the button can always switch back to the tree. The explicit
            // chromeText foregroundStyle defeats SwiftUI's default disabled dimming, so mute it by hand.
            .disabled(store.sidebarMode == .tree && store.flaggedSessions.isEmpty)
            .opacity(store.sidebarMode == .tree && store.flaggedSessions.isEmpty ? 0.35 : 1)
            .help(helpHint(store.sidebarMode == .flagged ? "Show all sessions" : "Show flagged sessions", .toggleFlaggedView))
            .accessibilityLabel("Toggle Flagged View")
            .accessibilityIdentifier("flagged-view-toggle")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // the add buttons track the terminal theme's foreground, matching the sidebar rows above.
        .foregroundStyle(chromeText)
        // no explicit background: the sidebar is transparent (the window's terminal color shows
        // through), so a `.bar` material here would paint a mismatched darker strip.
    }

}

/// Blends the window title bar with the terminal (the title text itself is set by
/// SwiftUI's `.navigationTitle`/`.navigationSubtitle`). The probe's `window` is nil at
/// make time, so the blend is applied from `viewDidMoveToWindow` (window attachment) and
/// re-applied on every `titleToken` change (session switch) and on the window key/
/// fullscreen transitions where AppKit rebuilds the titlebar subviews.
///
/// It also carries the per-window plumbing: it sets the frame autosave name, reports
/// frontmost (key/main) and close (`willClose`) to the `WindowLibrary`, and registers the
/// `NSWindow` in `WindowRegistry` for dedup/raise.
private struct WindowAccessor: NSViewRepresentable {
    /// Changes when the active session changes, so `updateNSView` re-runs the blend.
    let titleToken: String
    let windowID: WindowInfo.ID
    let library: WindowLibrary
    let store: AppStore

    func makeNSView(context _: Context) -> TitleProbeView {
        TitleProbeView(windowID: windowID, library: library, store: store)
    }

    func updateNSView(_ nsView: TitleProbeView, context _: Context) {
        nsView.reapplyBlend(title: titleToken)
    }

    final class TitleProbeView: NSView {
        private let windowID: WindowInfo.ID
        private let library: WindowLibrary
        private let store: AppStore

        /// Observer tokens for window key/fullscreen transitions, after which AppKit
        /// rebuilds the titlebar subviews and the blend must be re-applied.
        nonisolated(unsafe) private var titlebarObservers: [NSObjectProtocol] = []

        /// One-shot guard so the saved frame is applied exactly once per window attach.
        private var frameRestored = false

        /// The confirm-before-close delegate proxy, owned here (NSWindow.delegate is weak).
        private var closeProxy: WindowCloseDelegateProxy?

        init(windowID: WindowInfo.ID, library: WindowLibrary, store: AppStore) {
            self.windowID = windowID
            self.library = library
            self.store = store
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// The current window title ("session — window"). Set on the OS window (for the window menu
        /// and XCUITest title-matching) but kept visually hidden via titleVisibility, since our custom
        /// header renders the visible title.
        private var latestTitle = ""

        /// Re-apply the blend with the latest title (called from `updateNSView` on a session switch).
        func reapplyBlend(title: String) {
            latestTitle = title
            if let window { applyTitlebarBlend(window) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            titlebarObservers.forEach(NotificationCenter.default.removeObserver)
            titlebarObservers.removeAll()
            guard let window else { return }
            // the app owns its window set (WindowLibrary + windows.json reopen-all); SwiftUI's own
            // WindowGroup restoration only fights that by re-creating empty stray windows from the
            // remembered window count (shared by bundle id, not isolated). Opt every real window fully
            // out of AppKit/SwiftUI restoration so that remembered set never grows.
            window.isRestorable = false
            window.restorationClass = nil
            window.disableSnapshotRestoration()
            window.invalidateRestorableState()
            frameRestored = false
            // per-window geometry keyed by OUR window id. SwiftUI's WindowGroup autosaves frames under
            // its own index-based name ("terminal-AppWindow-N") and OVERRIDES any setFrameAutosaveName
            // we set — and that index doesn't track a window's identity across an in-session
            // close/reopen, so the reopened window lands on the wrong/default slot. Instead we persist
            // the frame ourselves on close (keyed by the stable window UUID, in UserDefaults) and
            // re-apply it here AFTER SwiftUI's initial .defaultSize pass — on window-key plus a short
            // delayed fallback — one-shot via `frameRestored`.
            let frameKeyToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                DispatchQueue.main.async {
                    guard let self, let window, self.window === window else { return }
                    self.restoreSavedFrame(window)
                }
            }
            titlebarObservers.append(frameKeyToken)
            // fallback on the next run-loop tick (not a fixed delay) so the saved frame snaps in as soon
            // as SwiftUI's initial sizing pass is done, minimizing the visible default-then-resize.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.restoreSavedFrame(window)
            }
            // attach-race guard: if a window.close dropped this window's store while it was still
            // attaching (window.new immediately followed by window.close), it's a zombie — close it
            // rather than register and leave an orphaned on-screen window for a now-closed id.
            guard library.isOpen(windowID) else {
                DispatchQueue.main.async { [weak window] in
                    window?.orderOut(nil)
                    window?.close()
                }
                return
            }
            // register the NSWindow so the app can raise an already-open window for this id (dedup)
            // instead of spawning a second; install the confirm-before-close delegate proxy.
            WindowRegistry.shared.register(windowID, window: window)
            ensureCloseProxy(on: window)
            applyTitlebarBlend(window)
            // the private titlebar subviews may not exist yet / get rebuilt after layout — re-apply the
            // blend and re-assert the close proxy (SwiftUI may re-own the delegate after attach).
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.ensureCloseProxy(on: window)
                self.applyTitlebarBlend(window)
            }
            // AppKit rebuilds the titlebar subviews and re-renders the sidebar Liquid Glass on
            // key/main/fullscreen transitions (becomeKey fires right at launch), undoing the cleared
            // titlebar layer and the glass tint — re-apply on every transition, including resign so a
            // background window keeps the terminal tint instead of the lighter default glass. Only
            // becomeKey/becomeMain mean this window became frontmost; resign/fullscreen do not.
            let frontmostNames: Set<NSNotification.Name> = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification]
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                         NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                         NSWindow.didExitFullScreenNotification] {
                // the observer block is @Sendable, so it must not touch main-actor state
                // directly; hop through DispatchQueue.main like the re-applies above.
                let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [windowID] notification in
                    let becameFrontmost = frontmostNames.contains(notification.name)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let window = self.window else { return }
                        self.applyTitlebarBlend(window)
                        if becameFrontmost { self.reportFrontmost(windowID) }
                    }
                }
                titlebarObservers.append(token)
            }
            // report close: tear down this window's surfaces, then mark it closed in the library.
            // capture library/store/id directly (NOT through `self`) — the view is being deallocated
            // as the window closes, so a `[weak self]` hop would no-op and the index would never update.
            let closeToken = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [library, store, windowID, weak window] _ in
                MainActor.assumeIsolated {
                    // persist this window's final frame (keyed by its id) so an in-session reopen — or
                    // a restart — restores its size/position. SwiftUI's own index-based autosave can't.
                    if let window {
                        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: TitleProbeView.frameKey(windowID))
                    }
                    WindowRegistry.shared.unregister(windowID)
                    // flush cwd drift since the last structural mutation before dropping the store —
                    // AppStore doesn't save on a live `cd`, so a closed-then-reopened window would
                    // otherwise load a stale snapshot. Skip it when the window is no longer open in the
                    // library (a delete already dropped the store + removed the per-window file, so a
                    // save here would resurrect an orphan file).
                    if library.isOpen(windowID) { store.save() }
                    for session in store.workspaces.flatMap(\.sessions) {
                        session.surface?.teardown()
                        session.splitSurface?.teardown()
                        session.overlaySurface?.teardown()
                        session.scratchSurface?.teardown()
                    }
                    library.closeWindow(windowID)
                    // closing a window drops its (unobserved) store, so the Dock badge's observation
                    // tracking won't fire — refresh it explicitly so the unseen total drops this window's.
                    // guard on isTerminating: on quit the willClose fires after applicationWillTerminate's
                    // clear(), and closeWindow no-ops (stores stay loaded), so an unguarded refresh would
                    // recompute the still-positive total and re-pin the badge clear() just zeroed.
                    if !library.isTerminating { DockBadgeController.shared.refresh() }
                }
            }
            titlebarObservers.append(closeToken)
            // a settings theme change updates GhosttyApp.terminalBackgroundColor; re-apply the
            // blend so the title bar and the (transparent) sidebar pick up the new window color
            // live, not just when the window next re-keys.
            let appearanceToken = NotificationCenter.default.addObserver(forName: .agtermAppearanceChanged, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    self.applyTitlebarBlend(window)
                }
            }
            titlebarObservers.append(appearanceToken)
            // a window restored in a miniaturized state isn't on-screen, so a fresh
            // launch shows nothing and UI-test automation has nothing to hit. bring it
            // forward un-minimized; re-assert next tick because state restoration can
            // re-apply the miniaturized state right after the view attaches.
            bringForward(window)
            DispatchQueue.main.async { [weak self] in self?.bringForward(window) }
            scheduleUITestWindowForward(window)
            // the window may already be key here: a reopened/raised window can become key DURING
            // creation, before these observers were installed, so that initial didBecomeKey was missed
            // (and bringForward above is then a no-op). Report frontmost explicitly so the palette /
            // session switcher route to THIS window immediately, not the previously-frontmost one.
            if window.isKeyWindow || window.isMainWindow { reportFrontmost(windowID) }
        }

        deinit {
            titlebarObservers.forEach(NotificationCenter.default.removeObserver)
        }

        /// Record this window as the frontmost in the library and persist the index. A no-op when this
        /// window is already frontmost, so the paired `didBecomeKey`/`didBecomeMain` (and a re-key of
        /// the same window) collapse to a single write instead of a per-focus-change write-storm.
        @MainActor private func reportFrontmost(_ id: WindowInfo.ID) {
            guard library.frontmostWindowID != id else { return }
            library.frontmostWindowID = id
            library.saveIndex()
            // the active-window change is async; let the control server refresh its cached window list
            // so a `window.list` poll sees the new `active` flag without waiting for the next command.
            NotificationCenter.default.post(name: .agtermWindowFrontmostChanged, object: nil)
        }

        private func bringForward(_ window: NSWindow) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }

        /// UserDefaults key for this window's saved frame, keyed by the stable window UUID (NOT
        /// SwiftUI's index-based autosave name, which it overrides and which doesn't track identity).
        static func frameKey(_ id: WindowInfo.ID) -> String { "agterm-frame-\(id.uuidString)" }

        /// Applies the saved frame for this window id, once. Deferred (window-key / next tick) so
        /// SwiftUI's initial `.defaultSize` pass has run and won't clobber the restored geometry.
        private func restoreSavedFrame(_ window: NSWindow) {
            guard !frameRestored else { return }
            frameRestored = true
            guard let saved = UserDefaults.standard.string(forKey: Self.frameKey(windowID)) else { return }
            let frame = NSRectFromString(saved)
            guard frame.width > 0, frame.height > 0 else { return }
            window.setFrame(frame, display: true)
        }

        /// Installs (or re-asserts) the confirm-before-close proxy as the window's delegate, chaining to
        /// whatever delegate SwiftUI set. No-op when it's already the delegate.
        private func ensureCloseProxy(on window: NSWindow) {
            if closeProxy == nil {
                closeProxy = WindowCloseDelegateProxy(windowID: windowID, library: library, store: store)
            }
            guard let closeProxy else { return }
            if (window.delegate as AnyObject?) !== closeProxy {
                closeProxy.forwardingDelegate = window.delegate
                window.delegate = closeProxy
            }
        }

        /// Re-assert the window forward under XCUITest: the FB11763863 reopen can present it slightly
        /// after the view attaches, so keep ordering it front for a short schedule.
        private func scheduleUITestWindowForward(_ window: NSWindow) {
            guard ContentView.isUITestLaunch else { return }
            let delays: [TimeInterval] = [0, 0.05, 0.15, 0.35, 0.7, 0.95]
            for delay in delays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                    guard let self, let window, self.window === window else { return }
                    self.bringForwardForUITests(window)
                }
            }
        }

        /// One-shot latch so the per-window retry presents this window at most once.
        private var didPresentForUITests = false
        private func bringForwardForUITests(_ window: NSWindow) {
            // present a window that isn't on screen yet (FB11763863: created minimized/background), then
            // latch off. Re-fronting on later ticks (or a momentary !isVisible during a re-render) would
            // fight a deliberate window.select and oscillate the key window, flapping the "active" flag.
            guard !didPresentForUITests, window.isMiniaturized || !window.isVisible else { return }
            NSApp.unhide(nil)
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            didPresentForUITests = true
        }

        private func applyTitlebarBlend(_ window: NSWindow) {
            // set the OS window title (kept hidden via titleVisibility in the sync) so the window menu
            // and XCUITest title-matching see it, even though our custom header shows the visible title.
            window.title = latestTitle
            let background = GhosttyApp.shared.terminalBackgroundColor
                ?? NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1)
            WindowAppearance.sync(window: window, background: background,
                                  chrome: .init(opacity: GhosttyApp.shared.windowOpacity,
                                                blurRadius: GhosttyApp.shared.windowBlurRadius))
        }
    }
}

/// A transparent AppKit layer placed behind the custom titlebar's decorative regions (the title text and
/// the empty spacers, which opt out of SwiftUI hit-testing) so the header behaves like a real title bar:
/// a single-click drag moves the window (`performDrag`) and a double-click runs the user's configured
/// title-bar double-click action. The custom titlebar is a SwiftUI view, not AppKit's native title bar,
/// so the OS double-click handling never reaches it; this restores it. The interactive header buttons
/// render in front and keep their own clicks. `mouseDownCanMoveWindow` is off so our `mouseDown` — not
/// AppKit's automatic move — sees the event and can tell a double-click apart from a drag.
private struct WindowControlArea: NSViewRepresentable {
    func makeNSView(context _: Context) -> TitlebarControlView { TitlebarControlView() }
    func updateNSView(_: TitlebarControlView, context _: Context) {}

    final class TitlebarControlView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                performTitlebarDoubleClickAction()
                return
            }
            // a single click that turns into a drag moves the window; a plain click returns at once.
            window?.performDrag(with: event)
        }

        /// Mirror AppKit's native title-bar double-click by honoring the system setting at
        /// Desktop & Dock ▸ "Double-click a window's title bar to" (`AppleActionOnDoubleClick`
        /// in `NSGlobalDomain`): Zoom/Fill → zoom, Minimize → miniaturize, "Do Nothing" → no-op.
        /// The key is absent until the user changes it from the macOS default (Zoom), so an
        /// untouched system reads as `nil` here and still zooms — preserving the prior behavior.
        /// Read live on each double-click so a setting change takes effect without an app relaunch.
        /// "Fill" maps to `zoom` (the closest standard NSWindow action; true Fill uses the newer
        /// window-tiling APIs). Zoom matches the green button and the `window.zoom` control command.
        ///
        /// A UITest env override (`AGTERM_UITEST_DOUBLECLICK_ACTION`) takes precedence so the gesture
        /// tests are hermetic regardless of the host machine's setting; it rides the environment
        /// because launch arguments trip the macOS 15+ no-window-at-launch bug (FB11763863, see
        /// `ui-tests.md`). Production never sets it and falls through to the live system default.
        private func performTitlebarDoubleClickAction() {
            guard let window else { return }
            let action = ProcessInfo.processInfo.environment["AGTERM_UITEST_DOUBLECLICK_ACTION"]
                ?? UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            switch action {
            case "Minimize":
                window.performMiniaturize(nil)
            case "None":
                break
            default: // "Maximize", "Fill", or unset (macOS default) → zoom
                window.zoom(nil)
            }
        }
    }
}

/// App-side bridge mapping a `WindowInfo.ID` to its live `NSWindow`. `WindowLibrary` is host-free
/// (no AppKit), so the NSWindow handles live here. `TitleProbeView` registers/unregisters on window
/// attach/close; `raise(_:)` brings an already-open window forward (the dedup-by-id raise path) and
/// `close(_:)` runs `performClose` (the `window.close` teardown path).
@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()
    private var windows: [WindowInfo.ID: NSWindow] = [:]

    private init() {}

    var registeredCount: Int { windows.count }

    func register(_ id: WindowInfo.ID, window: NSWindow) {
        windows[id] = window
    }

    /// Whether an on-screen window is registered for `id` (i.e. its NSWindow has attached).
    func isRegistered(_ id: WindowInfo.ID) -> Bool { windows[id] != nil }

    func unregister(_ id: WindowInfo.ID) {
        windows[id] = nil
    }

    func contains(_ window: NSWindow) -> Bool {
        windows.values.contains { $0 === window }
    }

    /// Brings the window for `id` to the front if one is live. Returns whether a window was raised.
    @discardableResult
    func raise(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Closes the on-screen window for `id` if one is live. Uses `window.close()` (NOT `performClose`)
    /// so it bypasses the confirm-before-close proxy — this is the programmatic path (Delete Window,
    /// which already confirms, and the control socket, which must stay headless). `close()` still runs
    /// the `willClose` teardown + library mark-closed. Returns whether a window was closed.
    @discardableResult
    func close(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        window.close()
        return true
    }

    /// Resizes the on-screen window for `id` to `width` x `height` points (frame size), keeping its top
    /// edge fixed and clamping into `[window.minSize, screen.visibleFrame]` via `WindowGeometry.clampSize`
    /// (the single clamp path). Returns false if no window is registered for `id` (not open). The
    /// control-channel `window.resize` path.
    @discardableResult
    func resize(_ id: WindowInfo.ID, width: Int, height: Int) -> Bool {
        guard let window = windows[id] else { return false }
        let maxSize = (window.screen ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let size = WindowGeometry.clampSize(WindowGeometry.Size(CGSize(width: CGFloat(width), height: CGFloat(height))),
                                            min: WindowGeometry.Size(window.minSize),
                                            max: WindowGeometry.Size(maxSize)).cgSize
        var frame = window.frame
        frame.origin.y += frame.size.height - size.height // keep the top edge fixed
        frame.size = size
        window.setFrame(frame, display: true)
        return true
    }

    /// Moves the on-screen window for `id` so its top-left corner is at (`x`, `y`) points relative to the
    /// top-left of `display` (an index into the screen list; nil = the window's current display), y down.
    /// The origin is clamped via `WindowGeometry.clampOrigin` so an off-screen request keeps a grabbable
    /// strip on the target display. Returns false if no window is registered for `id` (not open) or
    /// `display` is out of range. The control-channel `window.move` path.
    @discardableResult
    func move(_ id: WindowInfo.ID, x: Int, y: Int, display: Int?) -> Bool {
        guard let window = windows[id] else { return false }
        let screen: NSScreen?
        if let display {
            let screens = NSScreen.screens
            guard display >= 0, display < screens.count else { return false }
            screen = screens[display]
        } else {
            screen = window.screen ?? NSScreen.main
        }
        guard let screen else { return false }
        // (x, y) is the top-left relative to the screen's top-left (y down) → AppKit screen point (y up).
        let size = window.frame.size
        let topLeft = NSPoint(x: screen.frame.minX + CGFloat(x), y: screen.frame.maxY - CGFloat(y))
        // convert top-left to the frame's bottom-left origin, then clamp so a strip stays on the display.
        let requested = WindowGeometry.Point(x: Double(topLeft.x), y: Double(topLeft.y - size.height))
        let origin = WindowGeometry.clampOrigin(requested, windowSize: WindowGeometry.Size(size),
                                                displayFrame: WindowGeometry.Rect(screen.frame)).cgPoint
        window.setFrameOrigin(origin)
        return true
    }

    /// Zooms (the maximize-to-screen toggle) the on-screen window for `id` if one is live, driving the
    /// standard `NSWindow.zoom` — the same action as the green zoom button and the double-click-header
    /// gesture. A second call restores the prior frame. Returns false if no window is registered for `id`
    /// (not open). The control-channel `window.zoom` path.
    @discardableResult
    func zoom(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        window.zoom(nil)
        return true
    }
}

// CoreGraphics <-> host-free WindowGeometry conversions, kept app-side: agtermCore stays Foundation-only
// (a CoreGraphics member reference there crashes the release WMO SIL deserializer — see WindowGeometry).
private extension WindowGeometry.Size {
    init(_ cg: CGSize) { self.init(width: Double(cg.width), height: Double(cg.height)) }
    var cgSize: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }
}

private extension WindowGeometry.Point {
    var cgPoint: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
}

private extension WindowGeometry.Rect {
    init(_ cg: CGRect) {
        self.init(origin: WindowGeometry.Point(x: Double(cg.origin.x), y: Double(cg.origin.y)),
                  size: WindowGeometry.Size(cg.size))
    }
}

/// Forwarding `NSWindowDelegate` that adds a confirm-before-close for a window with running sessions,
/// forwarding every other delegate call to whatever delegate SwiftUI installed. Owned strongly by
/// `TitleProbeView` (`NSWindow.delegate` is weak). Intercepts USER-driven closes (red button, File ▸
/// Close); the programmatic `WindowRegistry.close` uses `window.close()` and skips `windowShouldClose`,
/// so Delete Window / agtermctl don't double-prompt.
@MainActor
private final class WindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    nonisolated(unsafe) weak var forwardingDelegate: NSObjectProtocol?
    private let windowID: WindowInfo.ID
    private let library: WindowLibrary
    private let store: AppStore
    private var sheetOpen = false

    init(windowID: WindowInfo.ID, library: WindowLibrary, store: AppStore) {
        self.windowID = windowID
        self.library = library
        self.store = store
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let count = store.workspaces.reduce(0) { $0 + $1.sessions.count }
        guard count > 0 else { return forwardedShouldClose(sender) }
        guard !sheetOpen else { return false }
        sheetOpen = true
        let name = library.windows.first { $0.id == windowID }?.name ?? "window"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \u{201C}\(name)\u{201D}?"
        alert.informativeText = "This ends \(count) running session\(count == 1 ? "" : "s"). The window can be reopened from File ▸ Open Window."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self, let sender else { return }
            MainActor.assumeIsolated {
                self.sheetOpen = false
                guard response == .alertFirstButtonReturn else { return }
                // force-close: close() doesn't re-enter windowShouldClose (no re-prompt) but still runs
                // the willClose teardown + library mark-closed. The user already confirmed.
                sender.close()
            }
        }
        return false
    }

    private func forwardedShouldClose(_ sender: NSWindow) -> Bool {
        (forwardingDelegate as? NSWindowDelegate)?.windowShouldClose?(sender) ?? true
    }

    // forward every other NSWindowDelegate selector to SwiftUI's delegate so its window bookkeeping
    // (willClose, didResize, …) still runs. Called by the ObjC runtime; reads the weak forward target.
    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwardingDelegate?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        forwardingDelegate?.responds(to: selector) == true ? forwardingDelegate : super.forwardingTarget(for: selector)
    }
}

/// Bridges to the AppKit `NSSplitView` under SwiftUI's `HSplitView` to (1) persist and restore the split
/// divider ratio — no public SwiftUI API exposes the divider position — and (2) clip the split's divider out
/// of the titlebar strip. Attached as a `.background` on the primary pane so its `NSView` lives inside the
/// split's view tree without becoming a third arranged pane.
///
/// (1) Once the split has a real width it restores `session.splitRatio` via `setPosition`; on each divider
/// resize it writes the current left-pane fraction back to the session, which the next `save()` (or the
/// quit-flush) persists, like a live cwd change.
///
/// (2) In COMPACT mode the SwiftUI `.padding(.top, titlebarHeight)` (30px) lands inside the window's
/// safe-area band, so the AppKit `NSSplitView` ignores it and grows to the FULL window height (verified:
/// its frame + both arranged panes span pt 0..windowHeight). The panes' top strip is empty terminal-bg
/// (invisible against the window bg), but the divider draws BLACK through it — a streak up through the
/// transparent titlebar. A 48px inset clears the band so normal mode is already bounded. The fix is a
/// CALayer mask on the split that hides its top `titlebarHeight` strip: a layer mask clips without
/// reflowing the terminal grid (a SwiftUI `.mask`/`.clipped()` here scrolled the top row away), the panes'
/// empty top strip is harmless to clip, and it composes with translucency (it reveals the window backing,
/// never an opaque color over the titlebar).
private struct SplitRatioAccessor: NSViewRepresentable {
    let session: Session
    let titlebarHeight: CGFloat
    let onPersist: () -> Void

    func makeNSView(context _: Context) -> SplitProbeView {
        let view = SplitProbeView(session: session)
        view.onPersist = onPersist
        view.titlebarHeight = titlebarHeight
        return view
    }
    func updateNSView(_ nsView: SplitProbeView, context _: Context) {
        nsView.onPersist = onPersist
        nsView.titlebarHeight = titlebarHeight // re-clip on a compact-toolbar toggle (changes titlebarHeight)
    }

    final class SplitProbeView: NSView {
        private let session: Session
        var onPersist: (() -> Void)?
        /// Top strip (in points) to clip the split's divider out of; updated on a compact-toolbar toggle.
        var titlebarHeight: CGFloat = 0 { didSet { if titlebarHeight != oldValue { updateDividerClip() } } }
        nonisolated(unsafe) private var resizeObserver: NSObjectProtocol?
        nonisolated(unsafe) private var applyObserver: NSObjectProtocol?
        nonisolated(unsafe) private var saveWorkItem: DispatchWorkItem?
        private weak var splitView: NSSplitView?
        private var dividerClipMask: CALayer?
        private var restored = false

        init(session: Session) {
            self.session = session
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            attachIfNeeded()
            updateDividerClip() // keep the titlebar-strip clip sized to the current split bounds
            guard !restored, let split = splitView else { return }
            if let ratio = session.splitRatio {
                let total = split.bounds.width
                guard total > 1 else { return } // wait for a real width; retried on each layout pass
                split.setPosition(total * CGFloat(ratio), ofDividerAt: 0)
            }
            restored = true
        }

        /// Find the enclosing `NSSplitView` once it's in the tree, then observe divider moves.
        private func attachIfNeeded() {
            guard splitView == nil, let split = enclosingSplitView() else { return }
            splitView = split
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main) { [weak self] _ in
                // the observer fires on the main queue; assume the main actor to call the @MainActor
                // `capture()`, matching the codebase's notification-closure pattern (e.g. ControlServer).
                MainActor.assumeIsolated { self?.capture() }
            }
            // `session.resize` stores a new fraction on the session and posts this (object-scoped to the
            // session) to move the LIVE divider — the programmatic analogue of a user drag. Unlike the
            // one-shot restore in `layout()`, it fires on every resize command.
            applyObserver = NotificationCenter.default.addObserver(
                forName: .agtermApplySplitRatio, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyRatio() }
            }
        }

        /// Move the live divider to the session's stored `splitRatio` (set by `session.resize` just before
        /// it posts `.agtermApplySplitRatio`). The follow-on `didResizeSubviews` → `capture()` is a no-op:
        /// the captured fraction equals the value we just set, so `capture()`'s near-equal guard skips it.
        private func applyRatio() {
            guard let split = splitView, let ratio = session.splitRatio else { return }
            let total = split.bounds.width
            // no real width yet (mid-relayout): re-arm the one-shot `layout()` restore so it applies the
            // new fraction on the next pass instead of leaving the model ahead of the divider.
            guard total > 1 else { restored = false; return }
            split.setPosition(total * CGFloat(ratio), ofDividerAt: 0)
        }

        /// Mask the split's divider out of the titlebar zone — the strip ABOVE the window's titlebar boundary
        /// (`titlebarHeight` points from the content top) that the NSSplitView overruns into in compact mode.
        /// The clip amount is the split's overrun ABOVE that boundary, computed live: ~`titlebarHeight` in
        /// compact (the split spans the full window) and 0 in normal (the split is already bounded at the
        /// content top, so clipping a fixed strip would eat real terminal rows). A layer mask, not a frame
        /// change, so the panes never reflow.
        private func updateDividerClip() {
            guard let split = splitView, let contentH = split.window?.contentView?.bounds.height else { return }
            split.wantsLayer = true
            // split's top edge measured in points DOWN from the content top (window base coords, AppKit
            // origin bottom-left, so the top edge is maxY); then how far it rises above the titlebar boundary.
            let splitTopFromContentTop = contentH - split.convert(split.bounds, to: nil).maxY
            let overrun = max(0, titlebarHeight - splitTopFromContentTop)
            // no overrun (normal mode, or any state where the split is already bounded at the content top) →
            // no clip: drop the mask so the split composites untouched, like a single pane.
            guard overrun > 0 else {
                if dividerClipMask != nil { split.layer?.mask = nil; dividerClipMask = nil }
                return
            }
            let visibleHeight = max(0, split.bounds.height - overrun)
            // the mask's OPAQUE rect = the region that stays visible (everything below the overrun strip).
            // the strip sits at the view's TOP: high-y when not flipped, low-y (origin) when flipped.
            let originY = split.isFlipped ? overrun : 0
            let frame = CGRect(x: 0, y: originY, width: split.bounds.width, height: visibleHeight)
            let mask = dividerClipMask ?? CALayer()
            mask.backgroundColor = NSColor.black.cgColor // opaque -> the masked layer shows through here
            // no implicit fade as the mask resizes during a window/divider drag
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.frame = frame
            CATransaction.commit()
            if dividerClipMask == nil {
                dividerClipMask = mask
            }
            split.layer?.mask = mask // re-assert (SwiftUI may rebuild the split's layer)
        }

        /// Record the current left-pane fraction onto the session, skipping no-op and degenerate values so a
        /// window resize that keeps the ratio doesn't churn it.
        private func capture() {
            guard restored, let split = splitView, let first = split.arrangedSubviews.first else { return }
            let total = split.bounds.width
            guard total > 1 else { return }
            let ratio = Double(first.frame.width / total)
            guard ratio > AppStore.splitRatioMin, ratio < AppStore.splitRatioMax else { return }
            if let current = session.splitRatio, abs(current - ratio) < 0.004 { return }
            session.splitRatio = ratio
            // persist shortly after the drag settles (debounced) so a force-quit keeps it too, symmetric
            // with the sidebar width; coalesces the many resize ticks of one drag into a single save().
            saveWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onPersist?() }
            saveWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        private func enclosingSplitView() -> NSSplitView? {
            var view: NSView? = superview
            while let current = view {
                if let split = current as? NSSplitView { return split }
                view = current.superview
            }
            return nil
        }

        deinit {
            saveWorkItem?.cancel()
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let applyObserver { NotificationCenter.default.removeObserver(applyObserver) }
        }
    }
}
