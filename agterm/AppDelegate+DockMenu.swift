import agtermCore
import AppKit

/// A retained target for one Dock-menu command. The Dock invokes menu actions with a nil sender, so a
/// recent/attention session's identity lives in this target's closure instead of in `representedObject`.
@MainActor
final class DockMenuActionTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func performDockMenuAction(_: Any?) {
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
    /// AppKit asks for this menu when the user opens the Dock menu, so MRU order and attention state are
    /// current without maintaining a second observed menu model.
    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        dockMenuActionTargets.removeAll(keepingCapacity: true)

        let menu = NSMenu()
        menu.autoenablesItems = false
        let store = library?.activeStore
        let actionsEnabled = actions?.uiActionsEnabled == true

        addDockMenuItem(
            "New Session",
            enabled: actionsEnabled && store?.currentWorkspaceID != nil,
            to: menu
        ) { [weak self] in
            self?.activateActiveWindow()
            self?.actions?.newSession()
        }
        addDockMenuItem(
            "Quick Terminal",
            enabled: actionsEnabled && actions?.frontmostQuickTerminal != nil,
            to: menu
        ) { [weak self] in
            self?.activateActiveWindow()
            self?.actions?.toggleQuickTerminal()
        }

        let dashboard = actions?.frontmostDashboard
        let dashboardHasContent = !(store?.recentSessions(limit: 1).isEmpty ?? true)
        addDockMenuItem(
            "Dashboard",
            enabled: dashboard != nil && actions?.terminalZoomActive == false
                && (dashboard?.isOpen == true || dashboardHasContent),
            to: menu
        ) { [weak self] in
            self?.activateActiveWindow()
            self?.actions?.toggleDashboard()
        }

        menu.addItem(.separator())
        addSessionSubmenu(recentDockSessions(in: store), in: store, group: .recent,
                          enabled: actionsEnabled, to: menu)
        addSessionSubmenu(store?.attentionSessions ?? [], in: store, group: .attention,
                          enabled: actionsEnabled, to: menu)
        return menu
    }

    /// Matches the title-bar recent-session picker: up to ten MRU sessions in the visible navigation
    /// scope, excluding the current session because selecting it would not navigate anywhere.
    private func recentDockSessions(in store: AppStore?) -> [Session] {
        guard let store else { return [] }
        var valid = Set(store.navigableSessions.map(\.id))
        if let activeID = store.activeSession?.id { valid.remove(activeID) }
        return store.sessionRecency.top(SessionSwitcher.maxCandidates, in: valid)
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
                let workspaceName = store.workspace(forSession: session.id)?.name
                let title = workspaceName.flatMap { $0.isEmpty ? nil : "\(session.displayName) — \($0)" }
                    ?? session.displayName
                addDockMenuItem(title, enabled: enabled, to: submenu) { [weak self, weak store] in
                    guard let store else { return }
                    self?.activate(session.id, in: store)
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

    /// Dock commands do not activate or unhide the app automatically. Surface the last-active window before
    /// running an action so New Session, Quick Terminal, and Dashboard are immediately visible.
    private func activateActiveWindow() {
        NSApp.unhide(nil)
        NSApp.activate()
        if let windowID = library?.activeWindowID {
            WindowRegistry.shared.raise(windowID)
        }
    }

    /// Selects a session captured when the Dock menu was built. The store is captured as well, so the action
    /// remains correctly window-scoped; synchronously marking that window frontmost lets the shared action
    /// hub focus the selected session and reveal the pane that raised its status, when present.
    private func activate(_ sessionID: UUID, in store: AppStore) {
        guard store.session(withID: sessionID) != nil,
              let library,
              let windowID = library.windowID(for: store),
              actions?.uiActionsEnabled(for: windowID) == true
        else { return }

        NSApp.unhide(nil)
        NSApp.activate()
        WindowRegistry.shared.raise(windowID)
        // WindowAccessor reports ordinary key-window changes asynchronously. Publish this Dock-driven
        // change now so the action hub targets this store synchronously without suppressing persistence
        // or the control server's cached window-list refresh.
        if library.frontmostWindowID != windowID {
            library.frontmostWindowID = windowID
            library.saveIndex()
            NotificationCenter.default.post(name: .agtermWindowFrontmostChanged, object: nil)
        }
        store.noteUserActivity()
        store.selectSession(sessionID)
        actions?.revealActiveBlockedPane()
    }
}
