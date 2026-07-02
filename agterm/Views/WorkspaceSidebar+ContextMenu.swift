import agtermCore
import AppKit

/// `WorkspaceSidebar.Coordinator` per-row context menu and its actions — the double-click rename
/// trigger, the menu builder, and the `@objc` handlers that drive the store/`AppActions`. Split out of
/// `WorkspaceSidebar.swift` to keep that file under the swiftlint size limit. Selector dispatch from an
/// extension works, so the handlers stay private.
extension WorkspaceSidebar.Coordinator {
    // MARK: - Context menu

    @objc func handleDoubleClick(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0, let node = sender.item(atRow: row) as? SidebarNode else { return }
        renameController.beginEditing(node: node)
    }

    /// Builds the per-row context menu. Resolves the clicked row lazily so the
    /// same menu serves every row.
    func menu(forRow row: Int) -> NSMenu? {
        guard let outline = outlineView, row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return nil }
        let menu = NSMenu()
        // manage enabled state explicitly (the Delete item is disabled at the last workspace)
        // rather than via the responder-chain auto-enabling.
        menu.autoenablesItems = false

        // "Clear Status" sits first for a session row that has a status to clear (same effect as
        // `agtermctl session status idle`).
        if node.kind == .session, store.session(withID: node.id)?.agentIndicator.status != .idle {
            let clearStatus = NSMenuItem(title: "Clear Status", action: #selector(menuClearStatus(_:)), keyEquivalent: "")
            clearStatus.target = self
            clearStatus.representedObject = node
            menu.addItem(clearStatus)
            menu.addItem(.separator())
        }

        let rename = NSMenuItem(title: "Rename", action: #selector(menuRename(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = node
        menu.addItem(rename)

        switch node.kind {
        case .session:
            let targets = store.workspaces.filter { $0.id != ownerWorkspaceID(ofSession: node.id) }
            if !targets.isEmpty {
                let moveTo = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for target in targets {
                    let item = NSMenuItem(title: target.name, action: #selector(menuMove(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = MoveRequest(sessionID: node.id, targetID: target.id)
                    submenu.addItem(item)
                }
                moveTo.submenu = submenu
                menu.addItem(moveTo)
            }
            // "Flag"/"Unflag" toggles the session's flagged working-set membership; the label
            // reflects the current state.
            let flagged = store.session(withID: node.id)?.flagged == true
            let flag = NSMenuItem(title: flagged ? "Unflag" : "Flag", action: #selector(menuToggleFlag(_:)), keyEquivalent: "")
            flag.target = self
            flag.representedObject = node
            menu.addItem(flag)
            let close = NSMenuItem(title: "Close Session", action: #selector(menuClose(_:)), keyEquivalent: "")
            close.target = self
            close.representedObject = node
            menu.addItem(close)
        case .workspace:
            let newSession = NSMenuItem(title: "New Session", action: #selector(menuNewSession(_:)), keyEquivalent: "")
            newSession.target = self
            newSession.representedObject = node
            menu.addItem(newSession)
            let openSession = NSMenuItem(title: "Open Directory…", action: #selector(menuOpenSession(_:)), keyEquivalent: "")
            openSession.target = self
            openSession.representedObject = node
            menu.addItem(openSession)
            // "Focus"/"Unfocus" collapses the tree to this workspace's subtree (or restores all when it
            // is already the focused one); the label reflects the current state.
            let focused = store.focusedWorkspaceID == node.id
            let focus = NSMenuItem(title: focused ? "Unfocus" : "Focus", action: #selector(menuFocusWorkspace(_:)), keyEquivalent: "")
            focus.target = self
            focus.representedObject = node
            menu.addItem(focus)
            menu.addItem(.separator())
            let delete = NSMenuItem(title: "Delete Workspace", action: #selector(menuDeleteWorkspace(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = node
            delete.isEnabled = store.canRemoveWorkspace
            menu.addItem(delete)
        }
        return menu
    }

    private func ownerWorkspaceID(ofSession id: UUID) -> UUID? {
        store.workspaces.first(where: { ws in ws.sessions.contains(where: { $0.id == id }) })?.id
    }

    /// Wraps a move command so a `Move to ▸ <ws>` item can carry both ids.
    private final class MoveRequest {
        let sessionID: UUID
        let targetID: UUID
        init(sessionID: UUID, targetID: UUID) {
            self.sessionID = sessionID
            self.targetID = targetID
        }
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        renameController.beginEditing(node: node)
    }

    @objc private func menuMove(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? MoveRequest else { return }
        store.moveSession(request.sessionID, toWorkspace: request.targetID)
    }

    @objc private func menuClose(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        // pass THIS sidebar's window-local store — a background window's Close must target its own
        // session, not the frontmost window's (which `AppActions.store` would resolve to).
        actions.closeSession(node.id, in: store)
    }

    @objc private func menuClearStatus(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        store.setAgentIndicator(AgentIndicator(), forSession: node.id)
    }

    @objc private func menuToggleFlag(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        actions.toggleFlag(node.id)
    }

    @objc private func menuNewSession(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        // resolve the cwd via the same new-session-directory setting as AppActions.newSession(), so the
        // workspace-row New Session honors it too (home / current session's cwd / a fixed custom dir).
        addSession(toWorkspace: node.id, cwd: actions.resolvedNewSessionCwd())
    }

    @objc private func menuDeleteWorkspace(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        actions.deleteWorkspace(node.id)
    }

    @objc private func menuFocusWorkspace(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        actions.focusWorkspace(node.id)
    }

    /// "Open Directory…": pick a folder and add a session rooted there.
    @objc private func menuOpenSession(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        openDirectoryAndAddSession(toWorkspace: node.id)
    }

    /// Adds a session to `workspaceID` at `cwd` and selects it.
    private func addSession(toWorkspace workspaceID: UUID, cwd: String) {
        if let session = store.addSession(toWorkspace: workspaceID, cwd: cwd) {
            store.selectSession(session.id)
            actions.focusActiveSession()
        }
    }

    private func openDirectoryAndAddSession(toWorkspace workspaceID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a directory for the new session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addSession(toWorkspace: workspaceID, cwd: url.path)
    }
}
