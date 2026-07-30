import agtermCore
import AppKit

/// `WorkspaceSidebar.Coordinator`'s per-row context menu and actions — the double-click rename trigger, the
/// menu builder, and the `@objc` handlers driving the store/`AppActions`. Split from `WorkspaceSidebar.swift`
/// for the swiftlint size limit; selector dispatch from an extension works, so the handlers stay private.
extension WorkspaceSidebar.Coordinator {
    // MARK: - Context menu

    /// Single click anywhere on a workspace row toggles its expansion, so the whole row is the hit target,
    /// not just the disclosure triangle. The toggle is DEFERRED by the double-click interval and cancelled
    /// by `handleDoubleClick`, so renaming does not flip the row open/closed on the way into edit mode.
    /// `action` fires on a genuine click, never during a drag, so workspace drag-reorder is unaffected.
    @objc func handleSingleClick(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0, let node = sender.item(atRow: row) as? SidebarNode, node.kind == .workspace else { return }
        if let event = NSApp.currentEvent {
            let point = sender.convert(event.locationInWindow, from: nil)
            // clicking the disclosure triangle already toggles natively — ignore that region so we don't double-toggle.
            if point.x < sender.frameOfOutlineCell(atRow: row).maxX { return }
            // clicking the inline "+" button is handled by the button itself — don't schedule the toggle.
            if let cell = sender.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView,
               let btn = cell.addButton,
               btn.convert(btn.bounds, to: sender).contains(point) { return }
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

    /// Builds the per-row context menu, resolving the clicked row lazily so one menu serves every row.
    func menu(forRow row: Int) -> NSMenu? {
        guard let outline = outlineView, row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return nil }
        let menu = NSMenu()
        // explicit enabled state (Delete is disabled at the last workspace), not responder-chain auto-enabling.
        menu.autoenablesItems = false
        let sessionTargets = node.kind == .session ? store.sidebarSelectionTargets(forContextSession: node.id) : []
        let sessionCount = sessionTargets.count

        // "Clear Status" sits first for a session row with a status, the `agtermctl session status idle` effect.
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
            // "Duplicate Session" opens a fresh shell in this session's directory, right after it.
            // Single-selection only and next to Rename, mirroring Finder; the title matches the New
            // Session / Close Session naming on this menu.
            if sessionCount == 1 {
                let duplicate = NSMenuItem(title: "Duplicate Session", action: #selector(menuDuplicate(_:)), keyEquivalent: "")
                duplicate.target = self
                duplicate.representedObject = node
                menu.addItem(duplicate)
            }
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
            // "Flag"/"Unflag" toggles flagged working-set membership; the label reflects the current state.
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
            // the focus items are their own group: they filter what the tree shows, unlike the create items
            // above and the destructive one below.
            menu.addItem(.separator())
            // "Focus"/"Unfocus" REPLACES the marked set with this workspace (or clears it when this is
            // already the only marked one, with the filter on); the label reflects the current state.
            let focused = store.isSoleFocus(node.id) // the same predicate the item's action toggles on
            let focus = NSMenuItem(title: focused ? "Unfocus" : "Focus", action: #selector(menuFocusWorkspace(_:)), keyEquivalent: "")
            focus.target = self
            focus.representedObject = node
            menu.addItem(focus)
            // "Add to Focus"/"Remove from Focus" toggles THIS workspace's membership, leaving the other
            // marked workspaces alone — how a multi-workspace working set is built up row by row.
            let member = store.focusedWorkspaceIDs.contains(node.id)
            let membership = NSMenuItem(title: member ? "Remove from Focus" : "Add to Focus",
                                        action: #selector(menuToggleFocusMembership(_:)), keyEquivalent: "")
            membership.target = self
            membership.representedObject = node
            menu.addItem(membership)
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

    @objc private func menuDuplicate(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        // this sidebar's window-local store, like Close/Flag — a background window acts on its own row.
        actions.duplicateSession(node.id, in: store)
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

    /// Inline "+" button on a workspace row, the right-click "New Session" action. The button carries no
    /// workspace id, so it is derived from the outline row at click time — reused cells target the right one.
    @objc func addSessionButtonClicked(_ sender: NSButton) {
        // cancel any pending single-click workspace toggle so clicking "+" doesn't also flip expansion.
        pendingRowToggle?.cancel()
        pendingRowToggle = nil
        guard let outline = outlineView else { return }
        let row = outline.row(for: sender)
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode, node.kind == .workspace else { return }
        addSession(toWorkspace: node.id, cwd: actions.resolvedNewSessionCwd())
    }

    @objc private func menuDeleteWorkspace(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        // this sidebar's window-local store, like Close/Flag/Duplicate/Focus: the enabled state came from
        // `store.canRemoveWorkspace`, and the frontmost store would not find the id — a silent no-op.
        actions.deleteWorkspace(node.id, in: store)
    }

    @objc private func menuFocusWorkspace(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        // this sidebar's window-local store, like Close/Flag/Duplicate: the "Focus"/"Unfocus" label was
        // computed from it, and the frontmost store would read one window and write another.
        actions.focusWorkspace(node.id, in: store)
    }

    /// Direction is derived from the same store the item's label was built from — and applied to that
    /// store — so the action always matches what the row's menu reads, in a background window too.
    @objc private func menuToggleFocusMembership(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        actions.setFocusMembership(node.id, member: !store.focusedWorkspaceIDs.contains(node.id), in: store)
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
