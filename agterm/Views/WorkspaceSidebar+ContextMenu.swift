import agtermCore
import AppKit

/// `WorkspaceSidebar.Coordinator` per-row context menu and its actions — the double-click rename
/// trigger, the menu builder, and the `@objc` handlers that drive the store/`AppActions`. Split out of
/// `WorkspaceSidebar.swift` to keep that file under the swiftlint size limit. Selector dispatch from an
/// extension works, so the handlers stay private.
extension WorkspaceSidebar.Coordinator {
    // MARK: - Context menu

    /// Single click on a workspace row toggles its expansion, so the whole row is a hit target for
    /// expand/collapse (not just the disclosure triangle). The toggle is DEFERRED by the double-click
    /// interval: a double-click (`handleDoubleClick`) cancels it, so renaming a workspace no longer flips
    /// it open/closed on the way into edit mode. `action` fires on a genuine click, never during a drag,
    /// so workspace drag-reorder is unaffected.
    @objc func handleSingleClick(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0, let node = sender.item(atRow: row) as? SidebarNode, node.kind == .workspace else { return }
        // clicking the disclosure triangle already toggles natively — ignore that region so we don't double-toggle.
        if let event = NSApp.currentEvent {
            let point = sender.convert(event.locationInWindow, from: nil)
            if point.x < sender.frameOfOutlineCell(atRow: row).maxX { return }
        }
        pendingRowToggle?.cancel()
        let toggle = DispatchWorkItem { [weak self, weak node] in
            guard let self, let node, let outline = self.outlineView else { return }
            self.toggleExpansion(of: node, in: outline)
        }
        pendingRowToggle = toggle
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: toggle)
    }

    @objc func handleDoubleClick(_ sender: NSOutlineView) {
        // a double-click is a rename, not an expand/collapse: cancel the pending single-click toggle.
        pendingRowToggle?.cancel()
        pendingRowToggle = nil
        let row = sender.clickedRow
        guard row >= 0, let node = sender.item(atRow: row) as? SidebarNode else { return }
        renameController.beginEditing(node: node)
    }

    private func toggleExpansion(of node: SidebarNode, in outline: NSOutlineView) {
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    /// Builds the per-row context menu. Resolves the clicked row lazily so the
    /// same menu serves every row.
    func menu(forRow row: Int) -> NSMenu? {
        guard let outline = outlineView, row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return nil }
        let menu = NSMenu()
        // manage enabled state explicitly (the Delete item is disabled at the last workspace)
        // rather than via the responder-chain auto-enabling.
        menu.autoenablesItems = false
        let sessionTargets = node.kind == .session ? store.sidebarSelectionTargets(forContextSession: node.id) : []
        let sessionCount = sessionTargets.count

        // "Clear Status" sits first for a session row that has a status to clear (same effect as
        // `agtermctl session status idle`).
        if node.kind == .session, sessionTargets.contains(where: { store.session(withID: $0)?.agentIndicator.status != .idle }) {
            let clearStatus = NSMenuItem(title: sessionCount == 1 ? "Clear Status" : "Clear Statuses",
                                         action: #selector(menuClearStatus(_:)), keyEquivalent: "")
            clearStatus.target = self
            clearStatus.representedObject = SessionBatchRequest(sessionIDs: sessionTargets)
            menu.addItem(clearStatus)
            menu.addItem(.separator())
        }

        if node.kind == .workspace || sessionCount <= 1 {
            let rename = NSMenuItem(title: "Rename", action: #selector(menuRename(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = node
            menu.addItem(rename)
        }

        switch node.kind {
        case .session:
            let targets = store.workspaces.filter { workspace in
                sessionTargets.contains { ownerWorkspaceID(ofSession: $0) != workspace.id }
            }
            if !targets.isEmpty {
                let moveTo = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for target in targets {
                    let item = NSMenuItem(title: target.name, action: #selector(menuMove(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = SessionBatchRequest(sessionIDs: sessionTargets, targetID: target.id)
                    submenu.addItem(item)
                }
                moveTo.submenu = submenu
                menu.addItem(moveTo)
            }
            // "Flag"/"Unflag" toggles the session's flagged working-set membership; the label
            // reflects the current state.
            let allFlagged = !sessionTargets.isEmpty && sessionTargets.allSatisfy { store.session(withID: $0)?.flagged == true }
            let flagTitle: String
            if sessionCount == 1 {
                flagTitle = allFlagged ? "Unflag" : "Flag"
            } else {
                flagTitle = allFlagged ? "Unflag Sessions" : "Flag Sessions"
            }
            let flag = NSMenuItem(title: flagTitle, action: #selector(menuToggleFlag(_:)), keyEquivalent: "")
            flag.target = self
            flag.representedObject = SessionBatchRequest(sessionIDs: sessionTargets)
            menu.addItem(flag)
            if sessionCount == 1 {
                let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(menuRevealInFinder(_:)), keyEquivalent: "")
                reveal.target = self
                reveal.representedObject = node
                reveal.isEnabled = actions.canRevealSessionInFinder(node.id, in: store)
                menu.addItem(reveal)
            }
            let closeTitle = sessionCount == 1 ? "Close Session" : "Close \(sessionCount) Sessions"
            let close = NSMenuItem(title: closeTitle, action: #selector(menuClose(_:)), keyEquivalent: "")
            close.target = self
            close.representedObject = SessionBatchRequest(sessionIDs: sessionTargets)
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

    /// Wraps session batch commands so menu items can carry both the selected ids and a target workspace.
    private final class SessionBatchRequest {
        let sessionIDs: [UUID]
        let targetID: UUID?
        init(sessionIDs: [UUID], targetID: UUID? = nil) {
            self.sessionIDs = sessionIDs
            self.targetID = targetID
        }
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        renameController.beginEditing(node: node)
    }

    @objc private func menuMove(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SessionBatchRequest, let targetID = request.targetID else { return }
        store.moveSessions(request.sessionIDs, toWorkspace: targetID)
    }

    @objc private func menuClose(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SessionBatchRequest else { return }
        // pass THIS sidebar's window-local store — a background window's Close must target its own
        // session, not the frontmost window's (which `AppActions.store` would resolve to).
        actions.closeSessions(request.sessionIDs, in: store)
    }

    @objc private func menuClearStatus(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SessionBatchRequest else { return }
        for id in request.sessionIDs { store.setAgentIndicator(AgentIndicator(), forSession: id) }
    }

    @objc private func menuToggleFlag(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? SessionBatchRequest else { return }
        actions.toggleFlags(request.sessionIDs, in: store)
    }

    @objc private func menuRevealInFinder(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        actions.revealSessionInFinder(node.id, in: store)
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
            // creating + selecting from the sidebar context menu is a user-initiated selection on THIS
            // window's store: note activity so it buys the full idle grace before auto-follow pulls away.
            store.noteUserActivity()
            store.selectSession(session.id)
            actions.focusActiveSession()
        }
    }

    private func openDirectoryAndAddSession(toWorkspace workspaceID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = DirectoryPanelDefaults.url(paths: store.activeSession?.focusedCwd)
        panel.prompt = "Open"
        panel.message = "Choose a directory for the new session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addSession(toWorkspace: workspaceID, cwd: url.path)
    }
}
