import agtCore
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
    @Bindable var store: AppStore
    let makeSurface: (Session) -> GhosttySurfaceView
    let makeSplitSurface: (Session) -> GhosttySurfaceView
    let makeOverlaySurface: (Session) -> GhosttySurfaceView
    let quickTerminal: QuickTerminalController
    let actions: AppActions
    let palette: PaletteController
    let sessionSwitcher: SessionSwitcher
    /// The terminal background color, mirrored from the (non-observable) `GhosttyApp` into view
    /// state and read by the status bar, so a settings theme change (posting `.agtAppearanceChanged`)
    /// re-renders it live.
    @State private var terminalColor: Color = ContentView.resolvedTerminalColor()

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(store: store, actions: actions)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .safeAreaInset(edge: .bottom) { bottomBar }
        } detail: {
            VStack(spacing: 0) {
                // a subtle hairline between the title bar and the terminal; lives in the
                // detail pane so it starts at the sidebar's right edge, not the full width.
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !store.statusBarHidden {
                    // hairline between the terminal and the status bar, matching the one
                    // under the title bar.
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 1)
                    statusBar
                }
            }
        }
        // native two-line titlebar title (session name bold + working-directory subtitle),
        // driven through SwiftUI so it isn't clobbered by NavigationSplitView.
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            // .sharedBackgroundVisibility(.hidden) drops the macOS 26 toolbar-item glass capsule
            // (synthesized around adjacent items) so the icons sit flush on the dark title bar.
            // Gated: the deployment target is macOS 14, where the API doesn't exist (older systems
            // keep the default chrome).
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { splitButton }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) { quickTerminalButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { splitButton }
                ToolbarItem(placement: .primaryAction) { quickTerminalButton }
            }
        }
        // the quick terminal: an in-app overlay above the whole split view (sidebar + terminal),
        // so it covers everything but the title bar (the toolbar button stays reachable to toggle).
        .overlay { quickTerminalOverlay }
        // the command palettes (actions / sessions): a top-centered overlay above everything.
        .overlay { commandPaletteOverlay }
        // the Ctrl-Tab most-recently-used session switcher.
        .overlay { sessionSwitcherOverlay }
        // when the quick terminal hides, return focus to the active session's terminal.
        .onChange(of: quickTerminal.isVisible) { _, visible in
            if !visible { actions.focusActiveSession() }
        }
        // when a palette closes, return focus to the active session's terminal.
        .onChange(of: palette.mode == nil) { _, closed in
            if closed { actions.focusActiveSession() }
        }
        // a settings appearance change isn't observable through GhosttyApp, so re-render on the
        // notification to pick up the new terminal color in the status bar.
        .onReceive(NotificationCenter.default.publisher(for: .agtAppearanceChanged)) { _ in
            terminalColor = ContentView.resolvedTerminalColor()
        }
        // blend the title bar with the terminal; surface the window un-minimized on launch.
        // the title token makes updateNSView re-run the blend on a session switch.
        .background(WindowAccessor(titleToken: windowTitle))
    }

    /// The active session's terminal, or a placeholder when nothing is selected. When the
    /// session is split, the primary and split surfaces sit side by side in an `HSplitView`
    /// (a draggable vertical divider). Hiding the split removes the second `TerminalView`;
    /// its surface survives (owned by the session), so the shell isn't destroyed.
    @ViewBuilder private var detailPane: some View {
        if let active = store.activeSession {
            ZStack {
                if active.isSplit {
                    HSplitView {
                        TerminalView(session: active, surfaceKeyPath: \.surface, makeSurface: makeSurface)
                            .overlay { paneDim(active.splitFocused) }
                            .id(active.id)
                        TerminalView(session: active, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface)
                            .overlay { paneDim(!active.splitFocused) }
                            .id("\(active.id.uuidString)-split")
                    }
                } else {
                    TerminalView(session: active, surfaceKeyPath: \.surface, makeSurface: makeSurface)
                        .id(active.id)
                }
                // an ephemeral overlay terminal on top, at full single-pane size, hiding the
                // single/split content underneath while its one program runs.
                if active.overlayActive {
                    TerminalView(session: active, surfaceKeyPath: \.overlaySurface, makeSurface: makeOverlaySurface)
                        .id("\(active.id.uuidString)-overlay")
                }
            }
        } else {
            Text("No session selected")
                .foregroundStyle(.secondary)
        }
    }

    /// A slim bottom status bar. Holds the active session's git status now and is the
    /// place for other info elements (the trailing area is intentionally left open).
    /// A translucent dim over the inactive split pane so the active one stands out. Clicks
    /// pass through (`allowsHitTesting(false)`) so the dimmed pane can still be focused;
    /// `dimmed == false` renders nothing.
    @ViewBuilder private func paneDim(_ dimmed: Bool) -> some View {
        if dimmed {
            Color.black.opacity(0.12).allowsHitTesting(false)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            GitStatusPill(status: store.activeSession?.gitStatus)
        }
        // more bottom than top padding nudges the pill up a touch: the right-aligned pill sits by
        // the window's rounded bottom-right corner, whose clipping makes a geometrically-centered
        // pill read as slightly low. minHeight keeps the bar a consistent height when empty; the
        // extra trailing inset keeps the content clear of that rounded corner.
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.top, 2.5)
        .padding(.bottom, 5.5)
        .frame(maxWidth: .infinity, minHeight: 22)
        // blend with the terminal: same background, so the status bar reads as a
        // continuation of it (separated only by the hairline above).
        .background(terminalColor)
    }

    /// The terminal background color from the ghostty config (a dark fallback if libghostty hasn't
    /// reported one), used to blend the status bar with the terminal. Read into the `terminalColor`
    /// view state so the status bar re-renders when the theme changes.
    private static func resolvedTerminalColor() -> Color {
        Color(nsColor: GhosttyApp.shared.terminalBackgroundColor
            ?? NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1))
    }

    /// The titlebar title (first line): the active session's display name, or "agt"
    /// when nothing is selected.
    private var windowTitle: String {
        store.activeSession?.displayName ?? "agt"
    }

    /// The titlebar subtitle (second line): the active session's working directory.
    private var windowSubtitle: String {
        store.activeSession?.effectiveCwd ?? ""
    }

    /// Toolbar button (right of the title bar) that toggles the active session's one-level
    /// vertical split: first press shows the second pane, the next hides it.
    private var splitButton: some View {
        let isSplit = store.activeSession?.isSplit ?? false
        return Button {
            actions.toggleSplit()
        } label: {
            // a Label (icon + title) so the toolbar's "Icon and Text" mode has text to show;
            // the title is hidden in the default icon-only mode.
            Label("Split", systemImage: "rectangle.split.2x1")
        }
        .help(isSplit ? "Hide split" : "Split right")
        .disabled(store.activeSession == nil)
        .accessibilityIdentifier("split-toggle")
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
        .help("Quick Terminal")
        .accessibilityIdentifier("quick-terminal-toggle")
    }

    /// The quick-terminal overlay: the scratch terminal centered at 90% of the window, framed by a
    /// hairline border and shadow so it reads as a distinct floating window over the (undimmed)
    /// content. libghostty renders only the terminal content, so the frame is drawn here. The margin
    /// is a transparent tap-catcher that dismisses on click — no darkening, because the overlay
    /// can't cover the AppKit title bar, so a dim would shade the body but not the chrome. Rendered
    /// only while visible; the surface it hosts is owned by the controller, so hiding keeps the
    /// shell alive.
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
                    QuickTerminalPane()
                        .frame(width: geo.size.width * 0.9, height: geo.size.height * 0.9)
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

    /// The command-palette overlay, mounted only while a palette is open. Its content (search
    /// field + result list) is rebuilt from `palette.mode`.
    @ViewBuilder private var commandPaletteOverlay: some View {
        if palette.mode != nil {
            CommandPalette(controller: palette, actions: actions)
        }
    }

    /// The Ctrl-Tab session switcher overlay, mounted only while cycling.
    @ViewBuilder private var sessionSwitcherOverlay: some View {
        if sessionSwitcher.isActive {
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
            .help("New Workspace")
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
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Session")
            .accessibilityLabel("Add session")
            .accessibilityIdentifier("add-session")

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // no explicit background: the sidebar is transparent (the window's terminal color shows
        // through), so a `.bar` material here would paint a mismatched darker strip.
    }

}

/// Blends the window title bar with the terminal (the title text itself is set by
/// SwiftUI's `.navigationTitle`/`.navigationSubtitle`). The probe's `window` is nil at
/// make time, so the blend is applied from `viewDidMoveToWindow` (window attachment) and
/// re-applied on every `titleToken` change (session switch) and on the window key/
/// fullscreen transitions where AppKit rebuilds the titlebar subviews.
private struct WindowAccessor: NSViewRepresentable {
    /// Changes when the active session changes, so `updateNSView` re-runs the blend.
    let titleToken: String

    func makeNSView(context _: Context) -> TitleProbeView {
        TitleProbeView()
    }

    func updateNSView(_ nsView: TitleProbeView, context _: Context) {
        _ = titleToken
        nsView.reapplyBlend()
    }

    final class TitleProbeView: NSView {
        /// Observer tokens for window key/fullscreen transitions, after which AppKit
        /// rebuilds the titlebar subviews and the blend must be re-applied.
        nonisolated(unsafe) private var titlebarObservers: [NSObjectProtocol] = []

        /// Re-apply the blend (called from `updateNSView` on a session switch).
        func reapplyBlend() {
            if let window { applyTitlebarBlend(window) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            titlebarObservers.forEach(NotificationCenter.default.removeObserver)
            titlebarObservers.removeAll()
            guard let window else { return }
            applyTitlebarBlend(window)
            // the private titlebar subviews may not exist yet / get rebuilt after layout.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.applyTitlebarBlend(window)
            }
            // AppKit rebuilds the titlebar subviews on key/main/fullscreen transitions
            // (becomeKey fires right at launch), undoing the cleared layer — re-apply.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didExitFullScreenNotification] {
                // the observer block is @Sendable, so it must not touch main-actor state
                // directly; hop through DispatchQueue.main like the re-applies above.
                let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let window = self.window else { return }
                        self.applyTitlebarBlend(window)
                    }
                }
                titlebarObservers.append(token)
            }
            // a settings theme change updates GhosttyApp.terminalBackgroundColor; re-apply the
            // blend so the title bar and the (transparent) sidebar pick up the new window color
            // live, not just when the window next re-keys.
            let appearanceToken = NotificationCenter.default.addObserver(forName: .agtAppearanceChanged, object: nil, queue: .main) { _ in
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
        }

        deinit {
            titlebarObservers.forEach(NotificationCenter.default.removeObserver)
        }

        private func bringForward(_ window: NSWindow) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }

        private func applyTitlebarBlend(_ window: NSWindow) {
            let background = GhosttyApp.shared.terminalBackgroundColor
                ?? NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1)
            WindowAppearance.sync(window: window, background: background)
        }
    }
}
