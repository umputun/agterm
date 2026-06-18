import agtCore
import AppKit
import SwiftUI

/// Custom pasteboard type carrying a dragged session's UUID string. Local-only
/// drags (within the outline) use this to identify the session being moved.
private let sessionPasteboardType = NSPasteboard.PasteboardType("com.umputun.agt.session")

/// An `NSTableCellView` with a trailing token field alongside the name field.
/// The name field is `cell.textField` (rename and selection wiring operate on it);
/// `tokenField` shows the session's `gitStatus?.compact` and stays whole while the
/// name truncates first.
private final class SidebarCellView: NSTableCellView {
    let tokenField = NSTextField(labelWithString: "")
}

/// Row view that always reports itself emphasized. The sidebar never becomes first
/// responder — clicking a session moves keyboard focus straight into the terminal
/// surface — so without this the selected row would permanently draw in the
/// unfocused source-list style (grey fill, dimmed text). Forcing emphasis keeps the
/// active session marked with the accent fill and readable text.
private final class SidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

/// A stable reference-type node fed to `NSOutlineView`. NSOutlineView keys item
/// identity and expansion state by object identity (`===`), so the nodes must be
/// the SAME instances across reloads — never freshly-allocated structs. The
/// coordinator caches one node per workspace/session id and reuses it, rebuilding
/// only the child lists from the store on each reload.
private final class SidebarNode {
    enum Kind { case workspace, session }

    let kind: Kind
    let id: UUID
    /// Workspace child nodes, repopulated from the store on each rebuild. Empty
    /// for session nodes.
    var children: [SidebarNode] = []

    init(kind: Kind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

/// AppKit `NSOutlineView` sidebar (source-list style) hosted in SwiftUI via
/// `NSViewRepresentable`. Replaces the SwiftUI `List` sidebar so cross-workspace
/// drag-and-drop works natively: a session row can be dragged onto a different
/// workspace and the model moves it (same `Session` instance preserved).
///
/// Two-level tree: workspaces (expandable parents, bold) → sessions (children).
/// Only session rows are selectable detail targets. Inline rename via double-click
/// or the "Rename" context menu. Context menus per row drive the store API.
struct WorkspaceSidebar: NSViewRepresentable {
    @Bindable var store: AppStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView()
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.autosaveExpandedItems = false
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        if #available(macOS 11.0, *) { outline.style = .sourceList }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        // native drag-and-drop: session rows are draggable; drops accepted onto a
        // different workspace (the workspace row or among its children).
        outline.registerForDraggedTypes([sessionPasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)

        context.coordinator.outlineView = outline
        context.coordinator.rebuildAndReload()
        context.coordinator.expandAll()
        context.coordinator.syncSelection()
        // on launch AppKit makes the sidebar the window's initial first responder; hand
        // focus to the terminal once the window + surface are attached (retries internally).
        context.coordinator.focusActiveTerminal()

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        // transparent: the window's backgroundColor (the terminal color, set by
        // WindowAppearance) shows through the sidebar's translucent material so the whole
        // column — including the strip behind the titlebar — reads as one dark surface.
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // touching the observed store properties here registers this representable
        // as an observer, so SwiftUI re-invokes updateNSView when the tree, selection,
        // or any session's gitStatus changes. folding gitStatus into the read is what
        // makes a status-only change re-invoke updateNSView; a touch inside viewFor
        // would not register the dependency.
        _ = store.workspaces.map { ($0.id, $0.name, $0.sessions.map { ($0.id, $0.gitStatus) }) }
        _ = store.selectedSessionID
        context.coordinator.reconcile()
        context.coordinator.syncSelection()
    }

    /// Backs the outline as both data source and delegate. `@MainActor` so the
    /// AppKit delegate callbacks (all main-thread) satisfy the store's main-actor
    /// isolation under strict concurrency.
    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        private let store: AppStore
        weak var outlineView: NSOutlineView?

        /// Root workspace nodes in store order. Rebuilt (in place, reusing cached
        /// node instances) from the store on each reload.
        private var roots: [SidebarNode] = []
        /// Cache of node instances keyed by id, so identity is stable across reloads.
        private var nodeCache: [UUID: SidebarNode] = [:]
        /// Set while an end-editing notification is being processed, to ignore the
        /// re-entrant end-editing the cancel/commit path can trigger.
        private var committing = false
        /// Set while a rename field is the active first responder (between
        /// `beginEditing` and `restore`), so a gitStatus tick can't reload the row out
        /// from under the in-progress edit. `committing` covers only the end-editing
        /// instant; this covers the whole typing window.
        private var editing = false
        /// Guards `syncSelection` against the selection-change delegate callback it
        /// itself triggers (which would otherwise re-enter the store).
        private var applyingSelection = false
        /// Last-seen tree signature (workspace ids/names + per-session ids and display
        /// names), used to tell a structural change from a gitStatus-only update.
        private var lastTreeSignature: [TreeSignature] = []
        /// Last-seen gitStatus per session id, used to find which rows changed so a
        /// status-only update reloads just those rows instead of the whole outline.
        /// Only non-nil statuses are stored; an absent key reads as nil via the
        /// subscript, so a never-seen session and one last seen as nil compare equal.
        private var lastSeenGitStatus: [UUID: GitStatus] = [:]

        init(store: AppStore) {
            self.store = store
        }

        // MARK: - Model rebuild

        /// A workspace's structural signature: its id, name, and ordered sessions
        /// (id + display name). Equal signatures across an update mean the tree shape
        /// and every visible name are unchanged, so a gitStatus-only delta can be
        /// reloaded per-row instead of via a full rebuild. Including the display name
        /// means a rename or a cwd-driven basename change forces a full rebuild that
        /// refreshes the label, rather than being mistaken for a gitStatus-only update.
        private struct TreeSignature: Equatable {
            let id: UUID
            let name: String
            let sessions: [SessionSignature]
        }

        /// A session's contribution to a `TreeSignature`: its id and current display
        /// name, so a name change is detected even when the tree shape is unchanged.
        private struct SessionSignature: Equatable {
            let id: UUID
            let displayName: String
        }

        /// Decides between a full rebuild (structural change: add/move/close/rename) and
        /// a targeted per-row reload (gitStatus-only change). A status-only update during
        /// an in-progress rename is skipped so a 3s git tick can't drop the edit.
        func reconcile() {
            let signature = store.workspaces.map { workspace in
                TreeSignature(id: workspace.id, name: workspace.name,
                              sessions: workspace.sessions.map { SessionSignature(id: $0.id, displayName: $0.displayName) })
            }
            if signature != lastTreeSignature {
                lastTreeSignature = signature
                rebuildAndReload()
                snapshotGitStatus()
                return
            }
            reloadChangedGitStatusRows()
        }

        /// Reloads only the session rows whose `gitStatus` changed since the last
        /// snapshot. Skipped while a rename is in progress (field is first responder)
        /// or committing, so it can't reload a row out from under an in-progress edit.
        private func reloadChangedGitStatusRows() {
            guard let outline = outlineView, !committing, !editing else { return }
            for workspace in store.workspaces {
                for session in workspace.sessions {
                    let current = session.gitStatus
                    guard current != lastSeenGitStatus[session.id] else { continue }
                    lastSeenGitStatus[session.id] = current
                    if let node = nodeCache[session.id] { outline.reloadItem(node) }
                }
            }
        }

        /// Records the current gitStatus of every session so the next reconcile can
        /// detect a status-only delta.
        private func snapshotGitStatus() {
            var snapshot: [UUID: GitStatus] = [:]
            for workspace in store.workspaces {
                for session in workspace.sessions { snapshot[session.id] = session.gitStatus }
            }
            lastSeenGitStatus = snapshot
        }

        /// Rebuilds `roots` from the store, reusing cached node instances by id so
        /// NSOutlineView item identity and expansion state stay stable, then reloads
        /// the outline preserving expansion.
        func rebuildAndReload() {
            guard let outline = outlineView else { return }

            var seen = Set<UUID>()
            var newRoots: [SidebarNode] = []
            for workspace in store.workspaces {
                let wsNode = node(for: workspace.id, kind: .workspace)
                seen.insert(workspace.id)
                wsNode.children = workspace.sessions.map { session in
                    seen.insert(session.id)
                    return node(for: session.id, kind: .session)
                }
                newRoots.append(wsNode)
            }
            // drop cached nodes for ids no longer present
            nodeCache = nodeCache.filter { seen.contains($0.key) }
            roots = newRoots

            // preserve which workspaces are expanded across the reload
            let expanded = roots.filter { outline.isItemExpanded($0) }
            outline.reloadData()
            for node in expanded { outline.expandItem(node) }
        }

        /// Expands every workspace row (new workspaces start open).
        func expandAll() {
            guard let outline = outlineView else { return }
            for node in roots { outline.expandItem(node) }
        }

        private func node(for id: UUID, kind: SidebarNode.Kind) -> SidebarNode {
            if let existing = nodeCache[id] { return existing }
            let node = SidebarNode(kind: kind, id: id)
            nodeCache[id] = node
            return node
        }

        // MARK: - Selection

        /// Reflects `store.selectedSessionID` into the outline selection without
        /// re-entering the store. Workspace rows are never auto-selected.
        func syncSelection() {
            guard let outline = outlineView else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            guard let selectedID = store.selectedSessionID, let node = nodeCache[selectedID], node.kind == .session else {
                outline.deselectAll(nil)
                return
            }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            if outline.selectedRow != row {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let outline = outlineView else { return }
            let row = outline.selectedRow
            guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode, node.kind == .session else {
                return
            }
            store.selectSession(node.id)
        }

        /// Returns keyboard focus to the active session's terminal after a sidebar
        /// interaction, so the sidebar never keeps focus (typing always reaches the
        /// terminal). Mirrors macterm's `FocusRestoration`: the target surface may not be
        /// attached to the window yet (a just-selected session's view is still
        /// materializing), so retry on the run loop until it is, with a bounded cap.
        /// Skipped while a rename field is the first responder or an edit is in progress.
        func focusActiveTerminal(attempt: Int = 0) {
            // never steal focus from an in-progress rename.
            if editing { return }
            let window = outlineView?.window
            if let window, window.firstResponder is NSText { return }
            if let window, let surface = store.activeSession?.surface as? GhosttySurfaceView, surface.window === window {
                window.makeFirstResponder(surface)
                return
            }
            // window or surface not attached yet (launch, or a just-selected session still
            // materializing) — retry on the run loop until ready, with a bounded cap.
            guard attempt < 20 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.focusActiveTerminal(attempt: attempt + 1)
            }
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? SidebarNode else { return roots.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? SidebarNode else { return roots[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            return node.kind == .workspace
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            return node.kind == .session
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("sidebar-row")
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarRowView { return reused }
            let view = SidebarRowView()
            view.identifier = identifier
            return view
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier(node.kind == .workspace ? "workspace-cell" : "session-cell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView) ?? makeCell(identifier: identifier)

            let field = cell.textField!
            field.delegate = self
            // a reused cell may carry editing state from a prior rename; reset to label
            field.isEditable = false
            field.isBordered = false
            field.drawsBackground = false
            // a recycled cell may carry the prior session's tokens; reset before use
            applyToken(toCell: cell, status: nil)
            switch node.kind {
            case .workspace:
                let name = store.workspaces.first(where: { $0.id == node.id })?.name ?? ""
                field.stringValue = name
                field.font = .preferredFont(forTextStyle: .headline)
                field.setAccessibilityIdentifier("workspace-row")
                // expose the workspace name so app.staticTexts["workspace 1"] resolves
                field.setAccessibilityLabel(name)
            case .session:
                field.stringValue = displayName(forSession: node.id)
                field.font = .preferredFont(forTextStyle: .body)
                field.setAccessibilityIdentifier("session-row")
                field.setAccessibilityLabel(nil)
                applyToken(toCell: cell, status: gitStatus(forSession: node.id))
            }
            return cell
        }

        /// Renders `status?.compact` into the cell's trailing token field in
        /// `secondaryLabelColor` and exposes the compact string via the `git-compact`
        /// accessibility hook (identifier + value on the token field, plus the cell's
        /// value) so a stretch XCUITest can assert it. An empty/`nil` compact collapses
        /// the token (no width) so the name reclaims the full row and isn't pre-truncated.
        private func applyToken(toCell cell: SidebarCellView, status: GitStatus?) {
            let token = cell.tokenField
            let compact = status?.compact ?? ""
            guard !compact.isEmpty else {
                token.attributedStringValue = NSAttributedString(string: "")
                token.isHidden = true
                token.setAccessibilityIdentifier(nil)
                token.setAccessibilityValue(nil)
                cell.setAccessibilityValue(nil)
                return
            }
            token.isHidden = false
            token.attributedStringValue = NSAttributedString(string: compact, attributes: [
                .font: NSFont.preferredFont(forTextStyle: .caption1),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            token.setAccessibilityIdentifier("git-compact")
            token.setAccessibilityValue(compact)
            cell.setAccessibilityValue(compact)
        }

        /// Builds a view-based outline cell: an `SidebarCellView` with a leading name
        /// `NSTextField` (`cell.textField`, editable on demand by `beginEditing`) and a
        /// trailing token field for the git compact string. The name hugs and resists
        /// compression weakly while the token hugs and resists strongly, so the name
        /// truncates first and the tokens stay whole.
        private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> SidebarCellView {
            let cell = SidebarCellView()
            cell.identifier = identifier

            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.isEditable = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(field)
            cell.textField = field

            let token = cell.tokenField
            token.translatesAutoresizingMaskIntoConstraints = false
            token.lineBreakMode = .byClipping
            token.isEditable = false
            token.isBordered = false
            token.drawsBackground = false
            token.focusRingType = .none
            token.font = .preferredFont(forTextStyle: .caption1)
            token.setContentHuggingPriority(.required, for: .horizontal)
            token.setContentCompressionResistancePriority(.required, for: .horizontal)
            cell.addSubview(token)

            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                token.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
                token.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                token.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func displayName(forSession id: UUID) -> String {
            store.session(withID: id)?.displayName ?? ""
        }

        private func gitStatus(forSession id: UUID) -> GitStatus? {
            store.session(withID: id)?.gitStatus
        }

        // MARK: - Inline rename

        /// Puts the row's text field into editing mode and focuses it. Called from
        /// the "Rename" menu item and from double-click.
        private func beginEditing(node: SidebarNode) {
            guard let outline = outlineView else { return }
            let row = outline.row(forItem: node)
            guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            field.isEditable = true
            field.isBordered = true
            field.drawsBackground = true
            field.setAccessibilityIdentifier("edit-field")
            field.window?.makeFirstResponder(field)
            editing = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !committing, let field = notification.object as? NSTextField, let outline = outlineView else { return }
            committing = true
            defer { committing = false }

            // resolve which node this field belongs to via the row of its cell view
            let row = outline.row(for: field)
            let node = row >= 0 ? outline.item(atRow: row) as? SidebarNode : nil

            // Escape cancels: AppKit reports it via the text-movement key in userInfo.
            let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
            let cancelled = movement == NSTextMovement.cancel.rawValue

            let newValue = field.stringValue
            restore(field: field, kind: node?.kind)
            guard let node, !cancelled else { return }

            switch node.kind {
            case .session: store.renameSession(node.id, to: newValue)
            case .workspace: store.renameWorkspace(node.id, to: newValue)
            }
        }

        /// Returns a renamed/edited field to its non-editable label state and resets
        /// its accessibility identifier to the row identifier for its kind.
        private func restore(field: NSTextField, kind: SidebarNode.Kind?) {
            editing = false
            field.isEditable = false
            field.isBordered = false
            field.drawsBackground = false
            field.setAccessibilityIdentifier(kind == .workspace ? "workspace-row" : "session-row")
        }

        // MARK: - Context menu

        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? SidebarNode else { return }
            beginEditing(node: node)
        }

        /// Builds the per-row context menu. Resolves the clicked row lazily so the
        /// same menu serves every row.
        func menu(forRow row: Int) -> NSMenu? {
            guard let outline = outlineView, row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return nil }
            let menu = NSMenu()

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
            beginEditing(node: node)
        }

        @objc private func menuMove(_ sender: NSMenuItem) {
            guard let request = sender.representedObject as? MoveRequest else { return }
            store.moveSession(request.sessionID, toWorkspace: request.targetID)
        }

        @objc private func menuClose(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarNode else { return }
            store.closeSession(node.id)
        }

        @objc private func menuNewSession(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarNode else { return }
            addSession(toWorkspace: node.id, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
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

        // MARK: - Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? SidebarNode, node.kind == .session else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString(node.id.uuidString, forType: sessionPasteboardType)
            return pbItem
        }

        func outlineView(_ outlineView: NSOutlineView,
                         validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            guard let sessionID = draggedSessionID(from: info), let target = targetWorkspace(forDropOn: item) else {
                return []
            }
            // only a move ONTO a different workspace counts
            guard ownerWorkspaceID(ofSession: sessionID) != target else { return [] }
            // retarget the drop to the whole workspace row (no in-between insertion)
            outlineView.setDropItem(workspaceNode(forID: target), dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView,
                         acceptDrop info: NSDraggingInfo,
                         item: Any?,
                         childIndex index: Int) -> Bool {
            guard let sessionID = draggedSessionID(from: info), let target = targetWorkspace(forDropOn: item) else {
                return false
            }
            guard ownerWorkspaceID(ofSession: sessionID) != target else { return false }
            store.moveSession(sessionID, toWorkspace: target)
            return true
        }

        /// Reads the dragged session id from the pasteboard.
        private func draggedSessionID(from info: NSDraggingInfo) -> UUID? {
            guard let string = info.draggingPasteboard.string(forType: sessionPasteboardType) else { return nil }
            return UUID(uuidString: string)
        }

        /// The destination workspace id for a drop on `item`: a workspace row maps
        /// to itself; a session row maps to its owning workspace; a nil item (drop
        /// in empty space) has no workspace target.
        private func targetWorkspace(forDropOn item: Any?) -> UUID? {
            guard let node = item as? SidebarNode else { return nil }
            switch node.kind {
            case .workspace: return node.id
            case .session: return ownerWorkspaceID(ofSession: node.id)
            }
        }

        private func workspaceNode(forID id: UUID) -> SidebarNode? {
            roots.first(where: { $0.id == id })
        }
    }
}

/// An `NSOutlineView` subclass that serves a per-row context menu and starts
/// inline rename on double-click, both routed to the coordinator.
final class SidebarOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // select the right-clicked row so the menu's context matches
        if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return (delegate as? WorkspaceSidebar.Coordinator)?.menu(forRow: row)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // after the click is handled (selection, expand/collapse, drag), hand keyboard
        // focus back to the terminal so the sidebar never keeps it. row selection persists
        // (model state); only first responder moves. skipped mid-rename by the coordinator.
        (delegate as? WorkspaceSidebar.Coordinator)?.focusActiveTerminal()
    }
}
