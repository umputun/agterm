import agtermCore
import AppKit

/// `WorkspaceSidebar.Coordinator` native drag-and-drop — the pasteboard writer plus validate/accept and
/// the resolve helpers that glue AppKit's proposed drop to the host-free `SidebarDrop` index math. Split
/// out of `WorkspaceSidebar.swift` to keep that file under the swiftlint size limit. `workspaceNode(forID:)`
/// stays in the main file (it reads the private `roots` cache); the pasteboard type constants are file-level.
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
            guard let move = resolveSessionMove(from: info, item: item, childIndex: index) else {
                cancelSpringLoadedExpansion()
                return []
            }
            // redraw the drop highlight on the target workspace row at the resolved insert slot.
            outlineView.setDropItem(workspaceNode(forID: move.workspace), dropChildIndex: move.dropChildIndex)
            scheduleSpringLoadedExpansion(of: move.workspace, in: outlineView)
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
            guard let move = resolveSessionMove(from: info, item: item, childIndex: index) else { return false }
            store.moveSessions(move.sessionIDs, toWorkspace: move.workspace, at: move.destination)
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

    /// The resolved session drop. `dropChildIndex` is the PRE-removal slot to highlight; `destination`
    /// is the POST-removal index `moveSessions` expects.
    private struct SessionMove {
        let sessionIDs: [UUID]
        let workspace: UUID
        let dropChildIndex: Int
        let destination: Int
    }

    /// Resolves a proposed session drop into the move it would perform, or nil when the drop is
    /// invalid or a no-op (so both `validateDrop` and `acceptDrop` agree exactly). Reads the pasteboard
    /// + store to map the dragged sessions and drop-target row to indices, then defers the index
    /// arithmetic (drop-on-row redirect, post-removal insertion slot, no-op detection) to the host-free
    /// `SidebarDrop.resolveSessions`.
    private func resolveSessionMove(from info: NSDraggingInfo, item: Any?, childIndex index: Int) -> SessionMove? {
        let sessionIDs = draggedSessionIDs(from: info)
        guard !sessionIDs.isEmpty, let node = item as? SidebarNode else { return nil }

        let target: SidebarDrop.SessionDropTarget
        switch node.kind {
        case .workspace:
            let count = store.workspaces.first(where: { $0.id == node.id })?.sessions.count ?? 0
            target = .workspaceRow(id: node.id, sessionCount: count)
        case .session:
            guard let drop = store.sessionLocation(ofSession: node.id) else { return nil }
            target = .sessionRow(workspace: drop.workspace, sessionIndex: drop.index, sessionCount: drop.count)
        }

        let sources = sessionIDs.compactMap { id -> SidebarDrop.SessionSource? in
            guard let source = store.sessionLocation(ofSession: id) else { return nil }
            return SidebarDrop.SessionSource(workspace: source.workspace, index: source.index)
        }
        guard sources.count == sessionIDs.count,
              let move = SidebarDrop.resolveSessions(sources: sources, target: target, childIndex: index)
        else { return nil }
        return SessionMove(sessionIDs: sessionIDs, workspace: move.workspace,
                           dropChildIndex: move.dropChildIndex, destination: move.destination)
    }

    /// Resolves a Finder drop to existing directory URLs and a destination workspace. Dropping on a
    /// workspace row adds there; dropping on a session row adds to that session's workspace; dropping into
    /// empty sidebar space uses the focused workspace when set, otherwise the current workspace.
    private func resolveDirectoryDrop(from info: NSDraggingInfo, item: Any?) -> DirectoryDrop? {
        let resolved = directoryURLs(from: info)
        guard !resolved.urls.isEmpty,
              let workspaceID = SidebarDrop.resolveDirectoryWorkspace(
                  sidebarMode: store.sidebarMode,
                  rowWorkspaceID: rowWorkspaceID(for: item),
                  focusedWorkspaceID: store.focusedWorkspaceID,
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

    /// Drops the pending spring-load work item and the opened-row tracking WITHOUT collapsing. Used on a
    /// successful drop so a workspace the drag spring-opened stays open to reveal the dropped/moved
    /// session — a `moveSessions` accept never changes the selection, so `syncSelection`'s reveal can't
    /// re-expand it, and collapsing here would hide the moved row until a manual expand.
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

    /// Resolves a workspace drop into the top-level reorder it would perform, or nil when it is a no-op
    /// (so `validateDrop` and `acceptDrop` agree exactly). A workspace reorder is a TOP-LEVEL move, but
    /// with workspaces expanded their sessions fill the gaps between workspace rows, so `NSOutlineView`
    /// only ever proposes drops INTO a workspace's children (`item != nil`) — never the clean root
    /// between-rows slot — making the reorder impossible from the proposed `item`/`childIndex` alone.
    /// Derive the insert slot from the cursor Y against the workspace ROWS' midpoints instead (sessions
    /// ignored): the slot is the count of workspace rows whose midpoint sits above the cursor, so the
    /// top half of a row drops before it and the bottom half after it. The index arithmetic (post-removal
    /// off-by-one, no-op detection) defers to the host-free `SidebarDrop.resolveWorkspace`.
    private func resolveWorkspaceMove(from info: NSDraggingInfo, in outlineView: NSOutlineView)
        -> (workspaceID: UUID, dropChildIndex: Int, destination: Int)? {
        guard let workspaceID = draggedWorkspaceID(from: info),
              let sourceIndex = store.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let point = outlineView.convert(info.draggingLocation, from: nil)
        var insertIndex = 0
        for (i, workspace) in store.workspaces.enumerated() {
            guard let node = workspaceNode(forID: workspace.id) else { continue }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { continue }
            // the outline is flipped (y increases downward): a cursor below a row's midpoint lands after it.
            if point.y > outlineView.rect(ofRow: row).midY { insertIndex = i + 1 }
        }
        guard let move = SidebarDrop.resolveWorkspace(sourceIndex: sourceIndex, count: store.workspaces.count,
                                                      childIndex: insertIndex) else { return nil }
        return (workspaceID, move.dropChildIndex, move.destination)
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
