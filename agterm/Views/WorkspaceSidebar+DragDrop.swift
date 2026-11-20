import agtermCore
import AppKit

/// `WorkspaceSidebar.Coordinator` native drag-and-drop: the pasteboard writer, validate/accept, and the
/// resolve helpers gluing AppKit's proposed drop to the host-free `SidebarDrop` index math. Split out of
/// `WorkspaceSidebar.swift` for its size limit; `workspaceNode(forID:)` stays there (it reads the private
/// `roots` cache) and the pasteboard type constants are file-level.
extension WorkspaceSidebar.Coordinator {
    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarNode else { return nil }
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
            // the flagged tree omits workspaces with nothing flagged, so a workspace drop there has no slot to aim at
            guard store.sidebarMode == .tree else { return nil }
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
            if store.remoteActions != nil, remoteWorkspaceStep(move) == nil { return [] }
            // workspace reorder lives at the top level: highlight a between-rows slot under the root.
            outlineView.setDropItem(nil, dropChildIndex: move.dropChildIndex)
            return .move
        }
        if !draggedSessionIDs(from: info).isEmpty, showsFlatFlaggedList {
            cancelSpringLoadedExpansion()
            return resolveFlaggedReorder(from: info, item: item, childIndex: index) == nil ? [] : .move
        }
        if let reparent = resolveCompanionReparent(from: info, item: item, childIndex: index) {
            cancelSpringLoadedExpansion()
            outlineView.setDropItem(reparent.dropItem, dropChildIndex: reparent.dropChildIndex)
            return .move
        }
        if !draggedSessionIDs(from: info).isEmpty {
            guard store.remoteActions == nil || draggedSessionIDs(from: info).count == 1,
                  let move = resolveSessionMove(from: info, item: item, childIndex: index) else {
                cancelSpringLoadedExpansion()
                return []
            }
            if let onRow = move.onFlaggedTreeRow {
                outlineView.setDropItem(onRow, dropChildIndex: SidebarDrop.onItemIndex)
            } else if let parent = move.dropParent {
                outlineView.setDropItem(parent, dropChildIndex: move.dropChildIndex)
            } else {
                outlineView.setDropItem(workspaceNode(forID: move.workspace), dropChildIndex: move.dropChildIndex)
            }
            scheduleSpringLoadedExpansion(of: move.workspace, in: outlineView)
            return .move
        }
        guard store.remoteActions == nil, let drop = resolveDirectoryDrop(from: info, item: item) else {
            cancelSpringLoadedExpansion()
            return []
        }
        // the root has no row: a drop on one of its sessions keeps that row, which acceptDrop resolves back to it
        outlineView.setDropItem(workspaceNode(forID: drop.workspaceID) ?? item, dropChildIndex: SidebarDrop.onItemIndex)
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
            if store.remoteActions != nil {
                guard let step = remoteWorkspaceStep(move) else { return false }
                actions.performRemote(.moveWorkspace(move.workspaceID, to: step), in: store)
            } else {
                store.moveWorkspace(move.workspaceID, at: move.destination)
            }
            dropSucceeded = true
            return true
        }
        if !draggedSessionIDs(from: info).isEmpty, showsFlatFlaggedList {
            guard let move = resolveFlaggedReorder(from: info, item: item, childIndex: index) else { return false }
            dropSucceeded = store.moveFlagged(move.ids, to: move.placement, of: move.anchor)
            return dropSucceeded
        }
        if let reparent = resolveCompanionReparent(from: info, item: item, childIndex: index) {
            actions.moveCompanion(reparent.companion, under: reparent.parent, at: reparent.slot, in: store)
            dropSucceeded = true
            return true
        }
        if !draggedSessionIDs(from: info).isEmpty {
            guard let move = resolveSessionMove(from: info, item: item, childIndex: index) else { return false }
            if store.remoteActions != nil {
                guard move.sessionIDs.count == 1, let id = move.sessionIDs.first else { return false }
                let sessions = store.workspaces.first { $0.id == move.workspace }?.sessions.map(\.id) ?? []
                let placement = RemoteOperation.dropPlacement(of: id, workspace: move.workspace, sessions: sessions,
                                                              destination: move.destination)
                actions.performRemote(.moveSession(id, to: placement), in: store)
            } else {
                store.moveSessions(move.sessionIDs, toWorkspace: move.workspace, at: move.destination)
            }
            dropSucceeded = true
            return true
        }
        guard store.remoteActions == nil, let drop = resolveDirectoryDrop(from: info, item: item) else { return false }
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

    /// The resolved session drop. `dropChildIndex` is the PRE-removal slot to highlight; `destination`
    /// is the POST-removal index `moveSessions` expects. `onFlaggedTreeRow` keeps a flagged-tree drop ON a
    /// session row targeted at that row: `acceptDrop` receives whatever `validateDrop` set, and retargeting
    /// it to the parent's gap below the row would read back as before the next VISIBLE row, past any hidden
    /// sibling in between.
    private struct SessionMove {
        let sessionIDs: [UUID]
        let workspace: UUID
        let dropChildIndex: Int
        let destination: Int
        var onFlaggedTreeRow: SidebarNode?
        var dropParent: SidebarNode?
    }

    /// Resolves a proposed session drop into the move it would perform, nil when the drop is invalid or a
    /// no-op, so `validateDrop` and `acceptDrop` agree exactly. Reads the pasteboard + store to map dragged
    /// sessions and the drop-target row to indices, then defers the index arithmetic (drop-on-row redirect,
    /// post-removal insertion slot, no-op detection) to the host-free `SidebarDrop.resolveSessions`.
    private func resolveSessionMove(from info: NSDraggingInfo, item: Any?, childIndex index: Int) -> SessionMove? {
        let sessionIDs = draggedSessionIDs(from: info)
        guard !sessionIDs.isEmpty, let (rowID, rowKind) = dropRow(item: item, childIndex: index) else { return nil }
        let flaggedTree = store.sidebarMode == .flagged

        let target: SidebarDrop.SessionDropTarget
        var childIndex = index
        var highlight: Int?
        var dropParent: SidebarNode?
        switch rowKind {
        case .workspace:
            // a nested companion has no workspace-level slot unless its parent moves with it
            let moving = Set(sessionIDs)
            if nestsCompanions,
               sessionIDs.contains(where: { store.session(withID: $0)?.parentID.map { !moving.contains($0) } == true }) {
                return nil
            }
            let count = store.workspaces.first(where: { $0.id == rowID })?.sessions.count ?? 0
            target = .workspaceRow(id: rowID, sessionCount: count)
            // a workspace node's children are its flagged rows in the flagged tree and its top-level rows in
            // the ordinary tree, so the proposed slot counts those, not the flat session list
            let visible = flaggedTree ? flaggedIndices(inWorkspace: rowID) : topLevelIndices(inWorkspace: rowID)
            if index != SidebarDrop.onItemIndex {
                childIndex = SidebarDrop.flaggedTreeChildIndex(visibleIndices: visible, slot: index)
                highlight = index
            }
        case .session where index != SidebarDrop.onItemIndex:
            // a gap among a parent's companions takes only that parent's own companions
            guard let parent = store.sessionLocation(ofSession: rowID),
                  sessionIDs.allSatisfy({ store.session(withID: $0)?.parentID == rowID }) else { return nil }
            target = .workspaceRow(id: parent.workspace, sessionCount: parent.count)
            childIndex = SidebarDrop.companionChildIndex(parentIndex: parent.index, slot: index)
            highlight = index
            dropParent = item as? SidebarNode
        case .session:
            guard let drop = store.sessionLocation(ofSession: rowID) else { return nil }
            target = .sessionRow(workspace: drop.workspace, sessionIndex: drop.index, sessionCount: drop.count)
        }

        let sources = sessionIDs.compactMap { id -> SidebarDrop.SessionSource? in
            guard let source = store.sessionLocation(ofSession: id) else { return nil }
            return SidebarDrop.SessionSource(workspace: source.workspace, index: source.index)
        }
        guard sources.count == sessionIDs.count,
              let move = SidebarDrop.resolveSessions(sources: sources, target: target, childIndex: childIndex)
        else { return nil }
        if flaggedTree, !flaggedTreeView().changesView(moving: sessionIDs, to: move) { return nil }
        guard store.canMoveSessions(sessionIDs, toWorkspace: move.workspace, at: move.destination) else { return nil }
        // the ordinary tree nests companions, so a flat index is no outline slot: re-resolve through the slot
        // validateDrop sets, which is what acceptDrop reads back
        if !flaggedTree, rowKind == .session, index == SidebarDrop.onItemIndex {
            let (parent, slot) = outlineSlot(forFlatIndex: move.dropChildIndex, in: move.workspace, moving: sessionIDs)
            if parent == nil, move.workspace == store.rootWorkspace?.id {
                return resolveSessionMove(from: info, item: nil, childIndex: slot)
            }
            guard let gap = parent ?? workspaceNode(forID: move.workspace) else { return nil }
            return resolveSessionMove(from: info, item: gap, childIndex: slot)
        }
        return SessionMove(sessionIDs: sessionIDs, workspace: move.workspace,
                           dropChildIndex: highlight ?? move.dropChildIndex, destination: move.destination,
                           onFlaggedTreeRow: flaggedTree && rowKind == .session ? item as? SidebarNode : nil,
                           dropParent: dropParent)
    }

    /// dropRow names the row a drop targets: the proposed node, or the root for a gap among the outline's
    /// top-level rows inside the shown root block, whose container has no row of its own.
    private func dropRow(item: Any?, childIndex index: Int) -> (UUID, SidebarNode.Kind)? {
        if let node = item as? SidebarNode { return (node.id, node.kind) }
        guard let root = store.rootWorkspace, let outline = outlineView else { return nil }
        let rootRows = (0..<outline.numberOfChildren(ofItem: nil))
            .filter { (outline.child($0, ofItem: nil) as? SidebarNode)?.kind == .session }.count
        guard SidebarDrop.rootGapSlot(childIndex: index, rootRows: rootRows,
                                      rootShown: workspaceProjection.contains { $0.workspace.id == root.id }) != nil
        else { return nil }
        return (root.id, .workspace)
    }

    // dropItem/dropChildIndex is what validateDrop sets and acceptDrop reads back, so both resolve the same move
    private struct CompanionReparentDrop {
        let companion: UUID
        let parent: UUID
        let slot: Int
        let dropItem: SidebarNode
        let dropChildIndex: Int
    }

    private func resolveCompanionReparent(from info: NSDraggingInfo, item: Any?, childIndex index: Int) -> CompanionReparentDrop? {
        let ids = draggedSessionIDs(from: info)
        guard nestsCompanions, ids.count == 1, let id = ids.first, let rowNode = item as? SidebarNode, rowNode.kind == .session,
              let current = store.session(withID: id)?.parentID, let target = store.session(withID: rowNode.id) else { return nil }
        let row: SidebarDrop.CompanionDropRow
        if let parent = target.parentID {
            guard index == SidebarDrop.onItemIndex,
                  let position = store.companions(of: parent).map(\.id).firstIndex(of: rowNode.id) else { return nil }
            row = .companion(parent: parent, position: position)
        } else {
            row = .parent(rowNode.id)
        }
        guard let move = SidebarDrop.companionReparent(from: current, onto: row, childIndex: index),
              case .success = store.canMoveCompanion(id, under: move.parent) else { return nil }
        let onParentRow = target.parentID == nil && index == SidebarDrop.onItemIndex
        return CompanionReparentDrop(companion: id, parent: move.parent, slot: move.slot,
                                     dropItem: onParentRow ? rowNode : node(for: move.parent, kind: .session),
                                     dropChildIndex: onParentRow ? SidebarDrop.onItemIndex : move.slot)
    }

    private func outlineSlot(forFlatIndex flat: Int, in workspaceID: UUID, moving ids: [UUID]) -> (SidebarNode?, Int) {
        let sessions = store.workspaces.first { $0.id == workspaceID }?.sessions ?? []
        let parentIDs = Set(ids.map { store.session(withID: $0)?.parentID })
        if parentIDs.count == 1, let parentID = parentIDs.first ?? nil,
           let parentIndex = sessions.firstIndex(where: { $0.id == parentID }) {
            return (node(for: parentID, kind: .session), flat - parentIndex - 1)
        }
        return (nil, sessions.prefix(max(0, flat)).filter { $0.parentID == nil }.count)
    }

    private func topLevelIndices(inWorkspace id: UUID) -> [Int] {
        let sessions = store.workspaces.first { $0.id == id }?.sessions ?? []
        return sessions.indices.filter { sessions[$0].parentID == nil }
    }

    // a flat or plain list's rows are sessions only, so a gap drop arrives with no item
    private func resolveFlaggedReorder(from info: NSDraggingInfo, item: Any?,
                                       childIndex index: Int) -> SidebarDrop.FlaggedReorder? {
        let sessionIDs = draggedSessionIDs(from: info)
        guard !sessionIDs.isEmpty else { return nil }
        return SidebarDrop.resolveFlaggedReorder(order: store.orderedFlaggedSessions.map(\.id), dragged: sessionIDs,
                                                 onRow: (item as? SidebarNode)?.id, childIndex: index)
    }

    private var showsFlatFlaggedList: Bool {
        store.sidebarMode == .flagged && !rendersWorkspaceRows
    }

    private func flaggedIndices(inWorkspace id: UUID) -> [Int] {
        let sessions = store.workspaces.first { $0.id == id }?.sessions ?? []
        return sessions.indices.filter { sessions[$0].flagged }
    }

    private func flaggedTreeView() -> SidebarDrop.FlaggedTree {
        SidebarDrop.FlaggedTree(workspaces: store.workspaces.map { ($0.id, $0.sessions.map(\.id)) },
                                flagged: Set(store.flaggedSessions.map(\.id)))
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
        guard rendersWorkspaceRows, let node = workspaceNode(forID: workspaceID) else {
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

    /// remoteWorkspaceStep is a remote window's workspace drop as the one server move step that lands it, nil when none.
    private func remoteWorkspaceStep(_ move: (workspaceID: UUID, dropChildIndex: Int, destination: Int)) -> String? {
        store.workspaceStep(moving: move.workspaceID, to: move.destination)
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
        let named = store.namedWorkspaces
        guard let workspaceID = draggedWorkspaceID(from: info),
              let sourceIndex = named.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let point = outlineView.convert(info.draggingLocation, from: nil)
        var visibleIndices: [Int] = []
        var slot = 0
        for (i, workspace) in named.enumerated() {
            guard let node = workspaceNode(forID: workspace.id) else { continue }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { continue }
            visibleIndices.append(i)
            // the outline is flipped (y increases downward): a cursor below a row's midpoint lands after it.
            if point.y > outlineView.rect(ofRow: row).midY { slot = visibleIndices.count }
        }
        let insertIndex = SidebarDrop.workspaceInsertIndex(visibleIndices: visibleIndices, slot: slot)
        guard let move = SidebarDrop.resolveWorkspace(sourceIndex: sourceIndex, count: named.count,
                                                      childIndex: insertIndex) else { return nil }
        // the highlight is an outline slot among the root block's rows and the rendered workspace rows; the move
        // is an index among named workspaces
        let rootBlock = outlineView.numberOfChildren(ofItem: nil) - visibleIndices.count
        return (workspaceID, rootBlock + slot, move.destination)
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
