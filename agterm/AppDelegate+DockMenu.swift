import agtermCore
import AppKit

/// A retained target for one Dock-menu command. The Dock invokes menu actions with a nil sender, so a
/// recent/attention session's identity lives in this closure instead of in `representedObject`.
@MainActor
final class DockMenuActionTarget: NSObject {
    private let action: () -> Void
    private var isValid = true

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func invalidate() {
        isValid = false
    }

    @objc func performDockMenuAction(_: Any?) {
        guard isValid else { return }
        action()
    }
}

private enum DockSessionGroup {
    case recent
    case attention

    var title: String {
        switch self {
        case .recent: "Recent Sessions"
        case .attention: "Sessions Needing Attention"
        }
    }

    var emptyTitle: String {
        switch self {
        case .recent: "No Recent Sessions"
        case .attention: "No Sessions Need Attention"
        }
    }
}

extension AppDelegate {
    /// Builds the app-specific portion of the Dock icon's contextual menu from the last-active window.
    /// AppKit asks for it when the user opens the Dock menu, so MRU order and attention state are current
    /// without maintaining a second observed menu model.
    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        dockMenuActionTargets.forEach { $0.invalidate() }
        dockMenuActionTargets.removeAll(keepingCapacity: true)

        let menu = NSMenu()
        menu.autoenablesItems = false
        let store = library?.activeStore
        let windowID = store.flatMap { library?.windowID(for: $0) }
        let actionsEnabled = actions?.uiActionsEnabled(for: windowID) == true

        addDockMenuItem(
            "New Session",
            enabled: actionsEnabled && store?.currentWorkspaceID != nil,
            to: menu
        ) { [weak self, weak store] in
            guard let self, let store, let windowID,
                  actions?.uiActionsEnabled(for: windowID) == true,
                  store.currentWorkspaceID != nil,
                  activate(windowID: windowID, store: store)
            else { return }
            actions?.newSession()
        }

        // the one app-level item: a new window belongs to no existing window, so unlike its neighbours it
        // captures nothing and skips the frontmost-window modal gate. It activates the app itself because
        // ordinary window presentation does not (`WindowAccessor.bringForward` unhides and activates only on
        // the UI-test path), else the new window opens behind whatever app the Dock was right-clicked from.
        // Enabled on the action hub alone, never on the captured window: `actions` is wired in the scene
        // `.task`, so before that runs every other item is disabled (nil library → nil windowID) and an
        // always-enabled one here would be the menu's only live item, activating the app and doing nothing.
        addDockMenuItem("New Window", enabled: actions != nil, to: menu) { [weak self] in
            guard let self else { return }
            NSApp.unhide(nil)
            NSApp.activate()
            actions?.newWindow(ignoringModals: true)
        }

        // the quick terminal is app-level, so unlike its neighbours here there is no per-window controller to
        // find; the captured window still has to come forward, the panel spawning in its active session's cwd.
        addDockMenuItem(
            "Quick Terminal",
            enabled: actionsEnabled,
            to: menu
        ) { [weak self, weak store] in
            guard let self, let store, let windowID,
                  actions?.uiActionsEnabled(for: windowID) == true,
                  activate(windowID: windowID, store: store)
            else { return }
            actions?.toggleQuickTerminal()
        }

        let dashboard = windowID.flatMap { DashboardControllerRegistry.shared.controller(for: $0) }
        let terminalZoom = windowID.flatMap { TerminalZoomRegistry.shared.controller(for: $0) }
        let dashboardWasOpen = dashboard?.isOpen == true
        let dashboardHasContent = !(store?.recentSessions(limit: 1).isEmpty ?? true)
        addDockMenuItem(
            "Dashboard",
            enabled: dashboard != nil && terminalZoom?.target == nil
                && (dashboard?.isOpen == true || dashboardHasContent),
            to: menu
        ) { [weak self, weak store] in
            guard let self, let store, let windowID,
                  let dashboard = DashboardControllerRegistry.shared.controller(for: windowID),
                  TerminalZoomRegistry.shared.controller(for: windowID)?.target == nil,
                  dashboard.isOpen == dashboardWasOpen,
                  dashboard.isOpen || !store.recentSessions(limit: 1).isEmpty,
                  activate(windowID: windowID, store: store)
            else { return }
            actions?.toggleDashboard()
        }

        menu.addItem(.separator())
        addSessionSubmenu(recentDockSessions(in: store), in: store, group: .recent,
                          enabled: actionsEnabled, to: menu)
        addSessionSubmenu(store?.attentionSessions ?? [], in: store, group: .attention,
                          enabled: actionsEnabled, to: menu)
        return menu
    }

    /// Resolves the shared title-bar/Dock recent-session candidates into their current session objects.
    private func recentDockSessions(in store: AppStore?) -> [Session] {
        guard let store else { return [] }
        return store.navigableRecentSessions(limit: SessionSwitcher.maxCandidates)
            .compactMap(store.session(withID:))
    }

    private func addSessionSubmenu(
        _ sessions: [Session],
        in store: AppStore?,
        group: DockSessionGroup,
        enabled: Bool,
        to menu: NSMenu
    ) {
        let submenu = NSMenu(title: group.title)
        submenu.autoenablesItems = false

        if sessions.isEmpty || store == nil {
            let emptyItem = NSMenuItem(title: group.emptyTitle, action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else if let store {
            for session in sessions {
                let sessionID = session.id
                let workspaceName = store.workspace(forSession: sessionID)?.name
                let title = workspaceName.flatMap { $0.isEmpty ? nil : "\(session.displayName) — \($0)" }
                    ?? session.displayName
                addDockMenuItem(title, enabled: enabled, to: submenu) { [weak self, weak store] in
                    guard let store else { return }
                    self?.activate(sessionID, in: store)
                }
            }
        }

        let parent = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        parent.isEnabled = true
        menu.addItem(parent)
    }

    private func addDockMenuItem(
        _ title: String,
        enabled: Bool,
        to menu: NSMenu,
        action: @escaping () -> Void
    ) {
        let target = DockMenuActionTarget(action: action)
        dockMenuActionTargets.append(target)
        let item = NSMenuItem(
            title: title,
            action: #selector(DockMenuActionTarget.performDockMenuAction(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.isEnabled = enabled
        menu.addItem(item)
    }

    /// Dock commands do not activate or unhide the app automatically. Raise and synchronously publish the
    /// window captured when AppKit built the menu, keeping every top-level and session action scoped to it
    /// even when another window becomes frontmost while the menu is tracking.
    @discardableResult
    private func activate(windowID: UUID, store: AppStore) -> Bool {
        guard let library, library.store(for: windowID) === store else { return false }
        NSApp.unhide(nil)
        NSApp.activate()
        WindowRegistry.shared.raise(windowID)
        // WindowAccessor reports ordinary key-window changes asynchronously; publish this Dock-driven one
        // now so shared AppActions resolve through the captured store during this same invocation.
        if library.frontmostWindowID != windowID {
            library.frontmostWindowID = windowID
            library.saveIndex()
            NotificationCenter.default.post(name: .agtermWindowFrontmostChanged, object: nil)
        }
        return true
    }

    /// Selects a session captured when the Dock menu was built. Its store is captured too, keeping the
    /// action window-scoped; synchronously marking that window frontmost lets the shared action hub focus
    /// the selected session and reveal the pane that raised its status, when present.
    private func activate(_ sessionID: UUID, in store: AppStore) {
        guard store.session(withID: sessionID) != nil,
              let library,
              let windowID = library.windowID(for: store),
              actions?.uiActionsEnabled(for: windowID) == true,
              activate(windowID: windowID, store: store)
        else { return }

        store.noteUserActivity()
        let indicator = store.selectSession(sessionID)
        actions?.revealActiveBlockedPane(captured: indicator)
    }
}
