import agtermCore
import AppKit

/// `WorkspaceSidebar.Coordinator` native drag-and-drop: the pasteboard writer, validate/accept, and the
/// resolve helpers gluing AppKit's proposed drop to the host-free `SidebarDrop` index math. Split out of
/// `WorkspaceSidebar.swift` for its size limit; `workspaceNode(forID:)` stays there (it reads the private
/// `roots` cache) and the pasteboard type constants are file-level.
extension WorkspaceSidebar.Coordinator {
    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // the flat flagged view is a derived projection, not a reorderable tree — no drag source there.
        guard store.sidebarMode == .tree, let node = item as? SidebarNode else { return nil }
        let pbItem = NSPasteboardItem()
        switch node.kind {
        case .session:
            let row = outlineView.row(forItem: item)
            let selectedIDs = store.sidebarSelectionIDs
            let draggedIDs = row >= 0 && outlineView.selectedRowIndexes.contains(row) && selectedIDs.contains(node.id)
                ? selectedIDs
                : [node.id]
            pbItem.setString(draggedIDs.map(\.uuidString).joined(separator: "\n"), forType: sessionPasteboardType)
        case .workspace:
            pbItem.setString(node.id.uuidString, forType: workspacePasteboardType)
        }
        return pbItem
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        if draggedWorkspaceID(from: info) != nil {
            cancelSpringLoadedExpansion()
            guard let move = resolveWorkspaceMove(from: info, in: outlineView) else { return [] }
            // workspace reorder lives at the top level: highlight a between-rows slot under the root.
            outlineView.setDropItem(nil, dropChildIndex: move.dropChildIndex)
            return .move
        }
        if !draggedSessionIDs(from: info).isEmpty {
            guard let plan = resolveSessionDrop(from: info, item: item, childIndex: index) else {
                cancelSpringLoadedExpansion()
                return []
            }
            // nest-under-session drops highlight the target session row; top-level drops highlight the
            // workspace row (both fall back to the workspace when the parent node isn't cached).
            let highlight = plan.parentID.flatMap(sessionNode(forID:)) ?? workspaceNode(forID: plan.workspace)
            outlineView.setDropItem(highlight, dropChildIndex: plan.highlightChildIndex)
            scheduleSpringLoadedExpansion(of: plan.workspace, in: outlineView)
            return .move
        }
        guard let drop = resolveDirectoryDrop(from: info, item: item) else {
            cancelSpringLoadedExpansion()
            return []
        }
        outlineView.setDropItem(workspaceNode(forID: drop.workspaceID), dropChildIndex: SidebarDrop.onItemIndex)
        scheduleSpringLoadedExpansion(of: drop.workspaceID, in: outlineView)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        // a SUCCESSFUL drop keeps an already-spring-opened workspace open so the dropped/moved session
        // stays visible; a rejected/no-op drop collapses it back, same as leave/cancel. (A rejected
        // Finder drop can't rely on `draggingSession:endedAt:` to collapse — Finder is the source.)
        var dropSucceeded = false
        defer { finishDraggingSequence(collapseSpringLoaded: !dropSucceeded) }
        if draggedWorkspaceID(from: info) != nil {
            guard let move = resolveWorkspaceMove(from: info, in: outlineView) else { return false }
            store.moveWorkspace(move.workspaceID, at: move.destination)
            dropSucceeded = true
            return true
        }
        if !draggedSessionIDs(from: info).isEmpty {
            guard let plan = resolveSessionDrop(from: info, item: item, childIndex: index) else { return false }
            applySessionDrop(plan)
            dropSucceeded = true
            return true
        }
        guard let drop = resolveDirectoryDrop(from: info, item: item) else { return false }
        guard !drop.exceedsLimit else {
            presentDirectoryDropLimitAlert(in: outlineView)
            return false
        }
        var created = false
        for url in drop.urls {
            created = store.addSession(toWorkspace: drop.workspaceID, cwd: url.path) != nil || created
        }
        guard created else { return false }
        store.noteUserActivity()
        actions.focusActiveSession()
        dropSucceeded = true
        return true
    }

    func outlineView(_ outlineView: NSOutlineView,
                     draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        // a completed drop (operation != []) already ran acceptDrop, which keeps a spring-opened
        // workspace open; only a cancelled drag (dropped nowhere) collapses back to the pre-drag state.
        finishDraggingSequence(collapseSpringLoaded: operation.isEmpty)
    }

    /// A Finder folder drop resolved to the workspace that should receive the new session(s).
    private struct DirectoryDrop {
        let urls: [URL]
        let workspaceID: UUID
        let exceedsLimit: Bool
    }

    /// A resolved session drop. A SAME-workspace drop reparents the dragged roots (nest under `parentID`, or
    /// top-level when nil), carrying each subtree and positioning at `destination` among the new siblings. A
    /// CROSS-workspace drop always lands at the target workspace's top level (a subtree can't straddle
    /// workspaces) at flat index `destination`. `highlightChildIndex` drives `setDropItem`.
    private struct SessionDropPlan {
        let roots: [UUID]
        let workspace: UUID
        let parentID: UUID?
        let destination: Int
        let crossWorkspace: Bool
        let highlightChildIndex: Int
    }

    /// Resolves a proposed session drop into the reparent/move it would perform, nil when invalid or a
    /// no-op, so `validateDrop` and `acceptDrop` agree exactly. The drop target's `item` names the parent:
    /// a workspace row → the workspace top level (parentID nil), a session row → nest under that session.
    /// Same-workspace drops defer the sibling-index arithmetic + cycle guard to `SidebarDrop.resolveReparent`;
    /// cross-workspace drops force top-level placement (no cross-workspace nesting) via `flatChildInsertIndex`.
    private func resolveSessionDrop(from info: NSDraggingInfo, item: Any?, childIndex index: Int) -> SessionDropPlan? {
        let dragged = draggedSessionIDs(from: info)
        guard !dragged.isEmpty, let node = item as? SidebarNode else { return nil }
        // reduce a mixed selection to its topmost roots — a dragged child rides along inside its dragged
        // parent's subtree, so moving it independently would double-handle it.
        let draggedSet = Set(dragged)
        let roots = dragged.filter { store.session(withID: $0)?.parentID.map { !draggedSet.contains($0) } ?? true }
        guard !roots.isEmpty else { return nil }

        let targetWorkspace: UUID
        let parentID: UUID?
        switch node.kind {
        case .workspace:
            targetWorkspace = node.id
            parentID = nil
        case .session:
            guard let workspace = store.workspace(forSession: node.id)?.id else { return nil }
            targetWorkspace = workspace
            parentID = node.id
        }
        let order = store.workspaces.first(where: { $0.id == targetWorkspace })?
            .sessions.map { SessionTree.Node(id: $0.id, parentID: $0.parentID) } ?? []

        let allSameWorkspace = roots.allSatisfy { store.workspace(forSession: $0)?.id == targetWorkspace }
        if allSameWorkspace {
            guard let reparent = SidebarDrop.resolveReparent(order: order, sourceIDs: roots,
                                                             parentID: parentID, childIndex: index) else { return nil }
            return SessionDropPlan(roots: roots, workspace: targetWorkspace, parentID: reparent.parentID,
                                   destination: reparent.destination, crossWorkspace: false, highlightChildIndex: index)
        }
        // cross-workspace: nesting isn't allowed, so land at the target's top level — dropped ON a row appends.
        let topChildIndex = node.kind == .workspace ? index : SidebarDrop.onItemIndex
        let flat = SidebarDrop.flatChildInsertIndex(order: order, parent: nil,
                                                    childDestination: topChildIndex == SidebarDrop.onItemIndex ? nil : topChildIndex)
        return SessionDropPlan(roots: roots, workspace: targetWorkspace, parentID: nil,
                               destination: flat, crossWorkspace: true, highlightChildIndex: topChildIndex)
    }

    /// Applies a resolved drop. A same-workspace single root repositions with its sibling index; a batch
    /// appends each root under the new parent in drag order. A cross-workspace drop moves each root's whole
    /// subtree to the target's top level (`moveSession` nils the root's parentID and carries descendants),
    /// advancing the insert slot past each moved block so drag order is preserved.
    private func applySessionDrop(_ plan: SessionDropPlan) {
        if plan.crossWorkspace {
            var index = plan.destination
            for root in plan.roots {
                let blockSize = store.sessionSubtreeIDs(root).count
                store.moveSession(root, toWorkspace: plan.workspace, at: index)
                index += blockSize
            }
        } else if plan.roots.count == 1 {
            store.reparentSession(plan.roots[0], to: plan.parentID, at: plan.destination)
        } else {
            for root in plan.roots { store.reparentSession(root, to: plan.parentID, at: nil) }
        }
    }

    /// Resolves a Finder drop to existing directory URLs and a destination workspace: a workspace row adds
    /// there, a session row adds to that session's workspace, and empty sidebar space uses the store's
    /// `soleFocusedWorkspaceID` (the workspace the tree is zoomed to), otherwise the current workspace.
    private func resolveDirectoryDrop(from info: NSDraggingInfo, item: Any?) -> DirectoryDrop? {
        let resolved = directoryURLs(from: info)
        guard !resolved.urls.isEmpty,
              let workspaceID = SidebarDrop.resolveDirectoryWorkspace(
                  sidebarMode: store.sidebarMode,
                  rowWorkspaceID: rowWorkspaceID(for: item),
                  fallbackWorkspaceID: store.soleFocusedWorkspaceID,
                  currentWorkspaceID: store.currentWorkspaceID)
        else { return nil }
        return DirectoryDrop(urls: resolved.urls, workspaceID: workspaceID,
                             exceedsLimit: resolved.exceedsLimit)
    }

    private func rowWorkspaceID(for item: Any?) -> UUID? {
        guard let node = item as? SidebarNode else { return nil }
        switch node.kind {
        case .workspace:
            return node.id
        case .session:
            return store.workspace(forSession: node.id)?.id
        }
    }

    /// Reads only real directories from a Finder file-url drag. Plain files are rejected here so the
    /// terminal keeps owning "drop a path as escaped text" while the sidebar owns "drop a folder to open it".
    private func directoryURLs(from info: NSDraggingInfo) -> (urls: [URL], exceedsLimit: Bool) {
        let sequenceNumber = info.draggingSequenceNumber
        if let cachedDirectoryDrop, cachedDirectoryDrop.sequenceNumber == sequenceNumber {
            return (cachedDirectoryDrop.urls, cachedDirectoryDrop.exceedsLimit)
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        var directories: [URL] = []
        var exceedsLimit = false
        for url in urls ?? [] where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            if directories.count == SidebarDrop.maximumDirectoryImportCount {
                exceedsLimit = true
                break
            }
            directories.append(url)
        }
        cachedDirectoryDrop = (sequenceNumber, directories, exceedsLimit)
        return (directories, exceedsLimit)
    }

    private func scheduleSpringLoadedExpansion(of workspaceID: UUID, in outlineView: NSOutlineView) {
        guard store.sidebarMode == .tree, let node = workspaceNode(forID: workspaceID) else {
            cancelSpringLoadedExpansion()
            return
        }
        if springLoadedWorkspaceID == workspaceID, outlineView.isItemExpanded(node) { return }
        guard !outlineView.isItemExpanded(node) else {
            cancelSpringLoadedExpansion()
            return
        }
        if pendingSpringLoadedExpansion?.workspaceID == workspaceID { return }
        cancelSpringLoadedExpansion()
        let workItem = DispatchWorkItem { [weak self, weak outlineView] in
            guard let self, let outlineView, let node = self.workspaceNode(forID: workspaceID),
                  !outlineView.isItemExpanded(node) else { return }
            self.springLoadedWorkspaceID = workspaceID
            self.suppressExpansionPersist = true
            outlineView.expandItem(node)
            self.suppressExpansionPersist = false
            if !outlineView.isItemExpanded(node) { self.springLoadedWorkspaceID = nil }
            if self.pendingSpringLoadedExpansion?.workspaceID == workspaceID {
                self.pendingSpringLoadedExpansion = nil
            }
        }
        pendingSpringLoadedExpansion = (workspaceID, workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: workItem)
    }

    func cancelSpringLoadedExpansion() {
        let workspaceID = springLoadedWorkspaceID
        clearSpringLoadedTracking()
        guard let workspaceID, let outlineView, let node = workspaceNode(forID: workspaceID),
              outlineView.isItemExpanded(node) else { return }
        suppressExpansionPersist = true
        outlineView.collapseItem(node)
        suppressExpansionPersist = false
    }

    /// Drops the pending spring-load work item and the opened-row tracking WITHOUT collapsing, so a workspace
    /// the drag spring-opened stays open on a successful drop: a `moveSessions` accept never changes the
    /// selection, so `syncSelection`'s reveal can't re-expand it and collapsing would hide the moved row.
    private func clearSpringLoadedTracking() {
        pendingSpringLoadedExpansion?.workItem.cancel()
        pendingSpringLoadedExpansion = nil
        springLoadedWorkspaceID = nil
    }

    /// Ends the current AppKit dragging sequence: always drops the per-sequence URL cache, and either
    /// collapses a spring-opened workspace back to its pre-drag state (leave/cancel — Finder's transient
    /// spring-load contract) or keeps it open (a successful drop, so the result stays visible).
    func finishDraggingSequence(collapseSpringLoaded: Bool = true) {
        cachedDirectoryDrop = nil
        if collapseSpringLoaded {
            cancelSpringLoadedExpansion()
        } else {
            clearSpringLoadedTracking()
        }
    }

    private func presentDirectoryDropLimitAlert(in outlineView: NSOutlineView) {
        let alert = NSAlert()
        alert.messageText = "Too Many Folders"
        alert.informativeText = "You can open up to \(SidebarDrop.maximumDirectoryImportCount) folders at once."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = outlineView.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Resolves a workspace drop into the TOP-LEVEL reorder it would perform, nil when it is a no-op, so
    /// `validateDrop` and `acceptDrop` agree exactly. With workspaces expanded their sessions fill the gaps
    /// between workspace rows, so `NSOutlineView` only ever proposes drops INTO a workspace's children
    /// (`item != nil`), never the clean root between-rows slot — the reorder is impossible from the proposed
    /// `item`/`childIndex` alone. The insert slot instead comes from the cursor Y against the workspace ROWS'
    /// midpoints (sessions ignored): the count of RENDERED rows whose midpoint sits above the cursor, so a
    /// row's top half drops before it and its bottom half after. The focus filter can render a non-contiguous
    /// subset, so that is a VISIBLE-row count, not a full-array index; `SidebarDrop.workspaceInsertIndex` maps
    /// it back onto the full array (landing adjacent to the aimed-at row rather than jumping across the hidden
    /// workspaces between them), and the arithmetic (post-removal off-by-one, no-op detection) defers to
    /// `SidebarDrop.resolveWorkspace`.
    private func resolveWorkspaceMove(from info: NSDraggingInfo, in outlineView: NSOutlineView)
        -> (workspaceID: UUID, dropChildIndex: Int, destination: Int)? {
        guard let workspaceID = draggedWorkspaceID(from: info),
              let sourceIndex = store.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let point = outlineView.convert(info.draggingLocation, from: nil)
        var visibleIndices: [Int] = []
        var slot = 0
        for (i, workspace) in store.workspaces.enumerated() {
            guard let node = workspaceNode(forID: workspace.id) else { continue }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { continue }
            visibleIndices.append(i)
            // the outline is flipped (y increases downward): a cursor below a row's midpoint lands after it.
            if point.y > outlineView.rect(ofRow: row).midY { slot = visibleIndices.count }
        }
        let insertIndex = SidebarDrop.workspaceInsertIndex(visibleIndices: visibleIndices, slot: slot)
        guard let move = SidebarDrop.resolveWorkspace(sourceIndex: sourceIndex, count: store.workspaces.count,
                                                      childIndex: insertIndex) else { return nil }
        // the highlight rides the OUTLINE's root children — under the focus filter only the rendered
        // workspaces — so it takes the VISIBLE-space slot, while the store move takes the full-array
        // destination. The two index spaces coincide only on an unfiltered tree.
        return (workspaceID, slot, move.destination)
    }

    /// Reads the dragged workspace id from the pasteboard.
    private func draggedWorkspaceID(from info: NSDraggingInfo) -> UUID? {
        guard let string = info.draggingPasteboard.string(forType: workspacePasteboardType) else { return nil }
        return UUID(uuidString: string)
    }

    /// Reads the dragged session ids from the pasteboard.
    private func draggedSessionIDs(from info: NSDraggingInfo) -> [UUID] {
        var result: [UUID] = []
        var seen = Set<UUID>()
        let strings = info.draggingPasteboard.pasteboardItems?.compactMap {
            $0.string(forType: sessionPasteboardType)
        } ?? info.draggingPasteboard.string(forType: sessionPasteboardType).map { [$0] } ?? []
        for string in strings {
            for token in string.split(whereSeparator: { $0.isNewline }) {
                guard let id = UUID(uuidString: String(token)), seen.insert(id).inserted else { continue }
                result.append(id)
            }
        }
        return result
    }
}
