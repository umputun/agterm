import agtermCore
import AppKit
import SwiftUI

/// The actual per-window UI: the workspace/session sidebar + the active session's terminal, plus
/// the quick-terminal / palette / switcher overlays. Holds the resolved non-optional `AppStore` so
/// the binding-based wiring is unchanged from the single-window version; `ContentView` resolves the
/// store and hands it in.
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
            // typing in the quick terminal counts as activity, so an idle auto-follow fire can't change this
            // window's selected session behind the overlay while the user types (mirrors the overlay/scratch).
            quickTerminal.onUserInput = { [store] in store.noteUserActivity() }
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
            // themed (chromeText at low opacity), same as the detail-pane half, so it stays visible on
            // light themes too.
            Rectangle()
                .fill(chromeText.opacity(0.1))
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
            // themed (chromeText at low opacity) so it stays visible on light themes too.
            Rectangle()
                .fill(chromeText.opacity(0.1))
                .frame(height: 1)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // the floating overlay renders in-deck inside `sessionDetail` (`floatingOverlayPanel`), not at
                // this `detailPane` level.
                // the search bar, anchored at the `detailPane` level (never inside `sessionDetail`'s
                // HSplitView ZStack) so toggling it can't overrun the NSSplitView up into the titlebar.
                // Sits at the top-right of the detail area, like a standard find bar.
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
        let fullOverlay = session.fullOverlayActive
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
            // a floating overlay therefore leaves the panes hit-testable here; `floatingOverlayPanel`'s
            // transparent catcher absorbs clicks around the panel so they can't reach the panes.
            .allowsHitTesting(!hideForOverlay)
            // the scratch terminal renders here, in-deck, above the (hidden) pane(s) — like the FULL overlay,
            // a full-coverage sibling is safe (the panes go opacity 0, the split's frame is hidden). It sits
            // BELOW the ephemeral overlay (zIndex 1 vs 2) AND goes hidden while a full overlay is up, exactly
            // like the pane(s): under window translucency every surface's background renders fully transparent,
            // so a scratch left visible below would show through the overlay (reading as "the overlay opened
            // under the scratch"). The FLOATING overlay is the `floatingOverlayPanel` sibling below (zIndex 3):
            // it is ALWAYS present with a constant shape (its panel content is gated internally), so adding it
            // never re-hosts the NSSplitView even though the panes stay VISIBLE — and its opaque panel needs no
            // hiding of the scratch behind it.
            if session.scratchActive {
                // gate focus on every surface that covers the scratch — a full overlay (renders above it,
                // zIndex 2) AND the window-level quick terminal — so the deck's focusIfNeeded can't grab the
                // scratch behind them. When the cover goes away, isActive flips true and the deck re-grabs it.
                // (matches the autoFocus suppression in makeScratchSurface.) `deckVisible` mirrors the panes'
                // rule so only an on-screen scratch is a file-drop target.
                TerminalView(session: session, surfaceKeyPath: \.scratchSurface, makeSurface: makeScratchSurface,
                             isActive: isActive && !session.overlayActive && !quickTerminal.isVisible,
                             deckVisible: isActive && !fullOverlay)
                    .opacity(fullOverlay ? 0 : 1)
                    .allowsHitTesting(!fullOverlay)
                    .id("\(session.id.uuidString)-scratch")
                    .zIndex(1)
            }
            if fullOverlay {
                TerminalView(session: session, surfaceKeyPath: \.overlaySurface,
                             makeSurface: makeOverlaySurface, isActive: isActive, deckVisible: isActive)
                    .id("\(session.id.uuidString)-overlay")
                    .zIndex(2)
            }
            // the FLOATING overlay renders IN-DECK (per session) so its surface mounts + program runs even
            // when the session isn't active. ALWAYS PRESENT (constant ZStack shape) — the panel content is
            // gated INSIDE `floatingOverlayPanel`, the sibling itself never appears/disappears, so opening a
            // floating overlay never re-hosts the NSSplitView (the titlebar-overrun trigger). Unlike the full
            // overlay, it leaves the pane(s) visible behind its opaque framed panel.
            floatingOverlayPanel(session: session, isActive: isActive)
                .zIndex(3)
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

    /// The FLOATING overlay, rendered IN-DECK inside each session's `sessionDetail` ZStack as an
    /// ALWAYS-PRESENT sibling — the panel content is gated INSIDE the GeometryReader, so the ZStack's child
    /// count never changes when the overlay opens (constant shape = no NSSplitView re-host = no titlebar
    /// overrun). Because it is per-session in the eager deck, the surface mounts and its program runs even
    /// when the session isn't active. The panel is an opaque, framed terminal sized to `overlaySizePercent`%
    /// of the detail area and centered, with the session's pane(s) visible around it.
    @ViewBuilder private func floatingOverlayPanel(session: Session, isActive: Bool) -> some View {
        GeometryReader { geo in
            ZStack {
                if session.floatingOverlayActive, let percent = session.overlaySizePercent {
                    let fraction = CGFloat(percent) / 100
                    // transparent click-catcher over the whole detail area: absorbs clicks AROUND the panel so
                    // they can't reach the still-hit-testable panes behind and steal the overlay's first responder.
                    Color.clear.contentShape(Rectangle())
                    TerminalView(session: session, surfaceKeyPath: \.overlaySurface,
                                 makeSurface: makeOverlaySurface, isActive: isActive, deckVisible: isActive)
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
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // when not floating the panel is an empty full-frame GeometryReader — make it inert so it never
        // intercepts clicks meant for the pane(s).
        .allowsHitTesting(session.floatingOverlayActive)
    }

    /// The terminal search bar, attached as a top-aligned `.overlay` on `detailPane` — NOT inside any
    /// session's `sessionDetail`/HSplitView ZStack, so toggling it never perturbs the split and overruns the
    /// NSSplitView into the titlebar. Shown only while the active session's `searchActive` is set; the needle
    /// binding drives the query through `actions.updateSearchNeedle`.
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
    /// is identifiable at a glance. Auto "window N" names are omitted. "Agterm" when nothing is selected.
    private var windowTitle: String {
        let session = store.activeSession?.displayName ?? "Agterm"
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
