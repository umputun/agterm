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

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .safeAreaInset(edge: .bottom) { bottomBar }
        } detail: {
            VStack(spacing: 0) {
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !store.statusBarHidden {
                    Divider()
                    statusBar
                }
            }
        }
        // native two-line titlebar title (session name bold + working-directory subtitle),
        // driven through SwiftUI so it isn't clobbered by NavigationSplitView.
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        // blend the title bar with the terminal; surface the window un-minimized on launch.
        // the title token makes updateNSView re-run the blend on a session switch.
        .background(WindowAccessor(titleToken: windowTitle))
    }

    /// The active session's terminal, or a placeholder when nothing is selected.
    @ViewBuilder private var detailPane: some View {
        if let active = store.activeSession {
            TerminalView(session: active, makeSurface: makeSurface)
                .id(active.id)
        } else {
            Text("No session selected")
                .foregroundStyle(.secondary)
        }
    }

    /// A slim bottom status bar. Holds the active session's git status now and is the
    /// place for other info elements (the trailing area is intentionally left open).
    private var statusBar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            GitStatusPill(status: store.activeSession?.gitStatus)
        }
        // symmetric vertical padding centers the content by construction (no reliance
        // on frame alignment); minHeight keeps the bar a consistent height when empty.
        // extra trailing inset keeps the right-aligned content clear of the window's
        // rounded bottom-right corner.
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 22)
        .background(.bar)
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

    /// Two distinct add controls, source-list style: add a workspace, and a menu
    /// to add a session to the current workspace (default cwd) or a picked directory.
    private var bottomBar: some View {
        HStack(spacing: 2) {
            Button {
                store.addWorkspace(name: defaultWorkspaceName)
            } label: {
                Image(systemName: "rectangle.stack.badge.plus")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New Workspace")
            .accessibilityLabel("New Workspace")

            Menu {
                Button("New Session") { addSessionToCurrentWorkspace() }
                Button("Open Directory…") { openDirectoryThenAddSession() }
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
        .background(.bar)
    }

    private var defaultWorkspaceName: String {
        "workspace \(store.workspaces.count + 1)"
    }

    /// The workspace a new session should land in: the selected session's
    /// workspace, else the last workspace. (Empty/specific workspaces can still be
    /// targeted via the workspace row's right-click menu.)
    private var currentWorkspaceID: UUID? {
        if let selected = store.selectedSessionID, let workspace = store.workspace(forSession: selected) {
            return workspace.id
        }
        return store.workspaces.last?.id
    }

    private func addSessionToCurrentWorkspace() {
        guard let workspaceID = currentWorkspaceID,
              let session = store.addSession(toWorkspace: workspaceID, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
        else { return }
        store.selectSession(session.id)
    }

    private func openDirectoryThenAddSession() {
        guard let workspaceID = currentWorkspaceID else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a directory for the new session"
        guard panel.runModal() == .OK, let url = panel.url,
              let session = store.addSession(toWorkspace: workspaceID, cwd: url.path)
        else { return }
        store.selectSession(session.id)
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
                let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    guard let self, let window = self.window else { return }
                    self.applyTitlebarBlend(window)
                }
                titlebarObservers.append(token)
            }
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
