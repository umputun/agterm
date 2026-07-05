import agtermCore
import AppKit
import SwiftUI

/// Custom pasteboard type carrying a dragged session's UUID string. Local-only
/// drags (within the outline) use this to identify the session being moved.
let sessionPasteboardType = NSPasteboard.PasteboardType("com.umputun.agterm.session")

/// Custom pasteboard type carrying a dragged workspace's UUID string. Local-only
/// drags (within the outline) use this to identify the workspace being reordered.
let workspacePasteboardType = NSPasteboard.PasteboardType("com.umputun.agterm.workspace")

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
    let actions: AppActions

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, actions: actions)
    }

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
        outline.action = #selector(Coordinator.handleSingleClick(_:))
        outline.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        if #available(macOS 11.0, *) { outline.style = .sourceList }
        // disable AppKit's own selection drawing: it would paint a gray unemphasized capsule whenever
        // the sidebar isn't first responder (focus normally lives in the terminal). SidebarRowView
        // draws the themed selection pill itself in drawBackground for every state.
        outline.selectionHighlightStyle = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        // native drag-and-drop: session rows reorder within / move across workspaces; workspace
        // rows reorder among themselves. Registering BOTH types is load-bearing — without the
        // workspace type AppKit never delivers validate/accept for a workspace drag.
        outline.registerForDraggedTypes([sessionPasteboardType, workspacePasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)

        context.coordinator.outlineView = outline
        context.coordinator.renameController.outlineView = outline
        // seed the tracked expansion from the persisted per-workspace state BEFORE the reload, so
        // rebuildAndReload restores each workspace's saved open/collapsed state (a collapsed workspace
        // stays collapsed across relaunch) instead of force-expanding every row.
        context.coordinator.seedExpansionFromModel()
        context.coordinator.rebuildAndReload()
        context.coordinator.syncSelection()
        // on launch AppKit makes the sidebar the window's initial first responder; hand
        // focus to the terminal once the window + surface are attached (retries internally).
        context.coordinator.focusActiveTerminal()

        let scroll = NSScrollView()
        scroll.identifier = NSUserInterfaceItemIdentifier("agterm-sidebar-scroll")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        // hide the scroller when the tree fits (the common case): without this, macOS set to
        // "Show scroll bars: Always" paints a permanent track over the short, non-overflowing tree.
        scroll.autohidesScrollers = true
        // transparent: the window's backgroundColor (the terminal color, set by
        // WindowAppearance) shows through the sidebar's translucent material so the whole
        // column — including the strip behind the titlebar — reads as one dark surface.
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.installEmptyState(in: scroll)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // touching the observed store properties here registers this representable as an observer, so
        // SwiftUI re-invokes updateNSView when the tree shape, selection, any session's name/displayName,
        // split state, unseen count, or agent status changes. folding all of those into the read is what
        // lets reconcile do a targeted per-row reload for a content change; a touch inside viewFor wouldn't
        // register it. agentIndicator feeds the status-icon reconcile (it renders on every session). the
        // badge-visibility toggle (GhosttyApp.notificationBadgeEnabled) is NOT observable, so it drives a
        // re-reconcile via the .agtermAppearanceChanged notification (appearanceChanged), like compactToolbar.
        _ = store.workspaces.map { ($0.id, $0.name, $0.unseenCount, $0.sessions.map { ($0.id, $0.displayName, $0.hasSplit, $0.unseenCount, $0.agentIndicator, $0.flagged) }) }
        _ = store.selectedSessionID
        // sidebarMode flips the whole data source between the tree and the flat flagged list; reading it
        // here registers the observer so a mode change re-invokes updateNSView and reconcile rebuilds.
        _ = store.sidebarMode
        // focusedWorkspaceID restricts the tree to one root (via visibleWorkspaces); reading it registers
        // the observer so a focus flip re-invokes updateNSView and reconcile takes the rebuild branch.
        _ = store.focusedWorkspaceID
        context.coordinator.reconcile()
        context.coordinator.syncSelection()
    }

    /// Backs the outline as both data source and delegate. `@MainActor` so the
    /// AppKit delegate callbacks (all main-thread) satisfy the store's main-actor
    /// isolation under strict concurrency.
    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let store: AppStore
        let actions: AppActions
        let renameController: SidebarRenameController
        weak var outlineView: NSOutlineView?

        /// Root workspace nodes in store order. Rebuilt (in place, reusing cached
        /// node instances) from the store on each reload.
        private var roots: [SidebarNode] = []
        /// Cache of node instances keyed by id, so identity is stable across reloads.
        private var nodeCache: [UUID: SidebarNode] = [:]
        /// Guards `syncSelection` against the selection-change delegate callback it
        /// itself triggers (which would otherwise re-enter the store).
        private var applyingSelection = false
        /// Last session id whose row was revealed (expanded owner + scrolled into view).
        /// Gates the intrusive reveal so unrelated observable updates (cwd/title/badge) to
        /// the already-selected session don't re-expand a collapsed workspace or yank the
        /// scroll position back — only an actual selection change reveals.
        private var lastRevealedSelection: UUID?
        /// Last-seen tree SHAPE (ordered workspace ids, each with its ordered session ids). A change
        /// here is structural (add/remove/move/reorder) and needs a full rebuild; a row's name/icon/
        /// badge changing is NOT structural — it reloads just that row, so a cwd-driven name change
        /// can't force a full `reloadData` + re-expand that re-lays-out (and jitters) every row.
        private var lastShape: [TreeShape] = []
        /// Last-seen sidebar mode. A flip (tree ↔ flagged) swaps which data source the outline renders, so
        /// it forces a full `rebuildAndReload` independent of the shape diff.
        private var lastMode: SidebarMode = .tree
        /// Workspace ids the user has expanded, tracked via the expand/collapse delegate callbacks. It is
        /// the source of truth for restoring expansion on rebuild because it survives the flagged-mode
        /// reload: that reload drops the workspace nodes from the data source entirely, and NSOutlineView
        /// discards its own expansion state for items it no longer renders, so on the way back to the tree
        /// this set is the only record of which workspaces were open.
        private var expandedWorkspaceIDs = Set<UUID>()
        /// Set true around PROGRAMMATIC `expandItem`/`collapseItem` (the launch/rebuild re-apply, the
        /// `syncSelection` reveal, the focus force-expand). While set, the didExpand/DidCollapse callbacks
        /// still update the visual `expandedWorkspaceIDs` but SKIP the persist write-back, so a view-only
        /// reveal or focus zoom-in never burns a workspace's deliberately-persisted collapse. Only a genuine
        /// user toggle (row click / disclosure triangle) — which fires the callback with this false —
        /// persists. `expandAll`/`collapseOthers` set it too and persist once explicitly at the end.
        private var suppressExpansionPersist = false
        /// Scheduled single-click workspace expand/collapse, deferred by the double-click interval so a
        /// double-click (rename) can cancel it — otherwise the first click of a rename double-click would
        /// flip the workspace open/closed on its way into edit mode. See `handleSingleClick`.
        var pendingRowToggle: DispatchWorkItem?

        /// Stable pseudo-workspace id for the flat flagged group's `TreeShape`, so within flagged mode only
        /// a change to the flagged session list (not a per-call fresh id) triggers a rebuild.
        private static let flaggedShapeID = UUID()

        /// The `userInfo` key AppKit uses for the item in `outlineViewItemDidExpand`/`DidCollapse`
        /// notifications (the documented value is the literal string `"NSObject"`).
        private static let outlineItemUserInfoKey = "NSObject"

        /// Last-seen visible content (label, split icon, badge) per session and workspace id, so a
        /// reconcile reloads only the rows whose content changed. An absent key ≠ any real content.
        private var lastRowContent: [UUID: RowContent] = [:]

        /// Centered hint shown over the (empty) outline in flagged mode when nothing is flagged. Floats in
        /// the scroll view above the document, hidden otherwise.
        private weak var emptyStateLabel: NSTextField?

        init(store: AppStore, actions: AppActions) {
            self.store = store
            self.actions = actions
            self.renameController = SidebarRenameController(store: store)
            super.init()
            renameController.onRenameEnded = { [weak self] in self?.focusActiveTerminal() }
            // the menu/palette can't reach the inline editor directly, so they post a
            // notification and this coordinator starts the edit on the selected row.
            NotificationCenter.default.addObserver(self, selector: #selector(beginRenameSessionNotified),
                                                   name: .agtermBeginRenameSession, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(beginRenameWorkspaceNotified),
                                                   name: .agtermBeginRenameWorkspace, object: nil)
            // expand/collapse target ONLY the frontmost window's sidebar: AppActions posts these with the
            // frontmost store as the object, and registering with `object: store` lets NotificationCenter
            // deliver only to the Coordinator whose store matches — so other windows' sidebars stay put.
            // (The rename observers above are object: nil and self-scope via the selected-session guard;
            // expand/collapse have no such natural per-window guard, so they scope by the store object.)
            NotificationCenter.default.addObserver(self, selector: #selector(expandWorkspacesNotified),
                                                   name: .agtermExpandWorkspaces, object: store)
            NotificationCenter.default.addObserver(self, selector: #selector(collapseWorkspacesNotified),
                                                   name: .agtermCollapseWorkspaces, object: store)
            // a theme change (new terminal foreground) re-tints the visible rows in place.
            NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
                                                   name: .agtermAppearanceChanged, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        /// Re-tint the visible rows' text/icon to the current selection state and redraw the selection
        /// pills, without a reloadData — used both when the selection changes (AppKit doesn't redraw on
        /// its own with selectionHighlightStyle == .none) and on a live theme change.
        func refreshSelectionAppearance() {
            guard let outline = outlineView else { return }
            for row in 0 ..< outline.numberOfRows {
                let selected = outline.selectedRowIndexes.contains(row)
                (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView)?.setColors(selected: selected)
            }
            outline.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
        }

        @objc private func appearanceChanged() {
            refreshSelectionAppearance()
            // a settings change may have flipped the badge-visibility toggle; reconcile so the gated
            // unseen count (0 when off, the real count when on) reloads the affected badge rows.
            reconcile()
            // the agent-status colors are global (not per-row), so reconcile's content diff can't see a
            // color change — re-apply every visible glyph so a Settings color edit takes effect live.
            reapplyStatusGlyphs()
            updateEmptyState()
        }

        /// Re-apply the status glyph on every visible session row so a global agent-status color change
        /// (from Settings) re-renders the existing glyphs. Appearance changes are rare, so the full sweep
        /// is cheap.
        private func reapplyStatusGlyphs() {
            guard let outline = outlineView else { return }
            for row in 0 ..< outline.numberOfRows {
                guard let node = outline.item(atRow: row) as? SidebarNode, node.kind == .session,
                      let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView else { continue }
                cell.statusIcon.apply(effectiveIndicator(forSession: node.id))
            }
        }

        @objc private func beginRenameSessionNotified() {
            guard let id = store.selectedSessionID, let node = nodeCache[id] else { return }
            // async so the edit starts after any palette overlay closes and the row is on screen.
            DispatchQueue.main.async { [weak self] in self?.renameController.beginEditing(node: node) }
        }

        @objc private func beginRenameWorkspaceNotified() {
            guard let id = store.currentWorkspaceID, let node = nodeCache[id] else { return }
            DispatchQueue.main.async { [weak self] in self?.renameController.beginEditing(node: node) }
        }

        /// Expand every workspace in this window's sidebar. A graceful no-op in flagged mode (no workspace
        /// rows), gated here so `expandAll`'s tracked-expansion seeding can't fire in flagged mode.
        @objc private func expandWorkspacesNotified() {
            guard store.sidebarMode == .tree else { return }
            expandAll()
        }

        /// Collapse every workspace except the active one in this window's sidebar. `collapseOthers` gates
        /// on tree mode itself, so flagged mode is a clean no-op.
        @objc private func collapseWorkspacesNotified() {
            collapseOthers()
        }

        // MARK: - Model rebuild

        /// The tree SHAPE: a workspace's id and its ordered session ids. Equal shapes across an update
        /// mean no add/remove/move/reorder, so a row's content change (name/icon/badge) is handled by a
        /// targeted per-row reload instead of a full rebuild. Row TEXT is deliberately NOT here: a
        /// cwd-driven `displayName` change must not trigger a full `reloadData` + re-expand (which
        /// re-lays-out every source-list row and jitters their labels horizontally).
        private struct TreeShape: Equatable {
            let workspaceID: UUID
            let sessionIDs: [UUID]
        }

        /// A row's visible content: its label (workspace name or session `displayName`), whether the
        /// session has a split (the split-rectangle icon), the unseen-badge count, and the GATED
        /// agent-status indicator (after the frontmost-selected hide). A delta reloads just that one row.
        /// Uses `hasSplit` (not `isSplit`) so the icon persists while a split is hidden.
        private struct RowContent: Equatable {
            let label: String
            let hasSplit: Bool
            let unseen: Int
            let indicator: AgentIndicator
            /// Whether the session is flagged (tree-mode filled-icon variant). A change re-badges
            /// just this row via `reloadItem`. Always false for workspace rows.
            let flagged: Bool
        }

        /// The session's own agent-status indicator (or `.idle` for an unknown id / workspace row). Shown
        /// on every session regardless of selection — `completed --auto-reset` clears itself on
        /// `selectSession`, so a visited session drops its glyph without a render-time gate.
        func effectiveIndicator(forSession id: UUID) -> AgentIndicator {
            store.session(withID: id)?.agentIndicator ?? AgentIndicator()
        }

        /// The unseen-count after the badge-visibility gate: 0 (hidden) when the Settings badge toggle
        /// is off, else the raw count. Render-only — `unseenCount` keeps tracking, so re-enabling the
        /// toggle instantly shows the current counts. The agent-status glyph is NOT gated by this.
        func effectiveUnseen(_ count: Int) -> Int {
            GhosttyApp.shared.notificationBadgeEnabled ? count : 0
        }

        /// Decides between a full rebuild (a SHAPE change: add/move/close/reorder) and a targeted
        /// per-row reload (a content change: rename, cwd-driven name, split open/close, badge). Content
        /// changes never rebuild — that full `reloadData` + re-expand re-lays-out every row and jitters
        /// their labels. A reload during an in-progress rename is skipped so a tick can't drop the edit.
        func reconcile() {
            // a mode flip swaps the whole data source (tree ↔ flat flagged list), so rebuild regardless of
            // the shape diff; otherwise compare the mode-appropriate shape.
            let shape = currentShape()
            if store.sidebarMode != lastMode || shape != lastShape {
                lastMode = store.sidebarMode
                lastShape = shape
                rebuildAndReload()
                snapshotRowContent()
                return
            }
            reloadChangedContentRows()
        }

        /// The structural shape for the current mode: the workspace tree (workspace id + ordered session
        /// ids) in `.tree`, or a single flat group of the flagged session ids in `.flagged`. A change here
        /// means an add/remove/move/reorder (or a flag/unflag in flagged mode) and forces a full rebuild.
        /// The tree case derives from `visibleWorkspaces` (the focused workspace alone when focused, else
        /// all), so a focus on/off — which changes the rendered root set — registers as a shape change.
        private func currentShape() -> [TreeShape] {
            switch store.sidebarMode {
            case .tree:
                return store.visibleWorkspaces.map { TreeShape(workspaceID: $0.id, sessionIDs: $0.sessions.map(\.id)) }
            case .flagged:
                return [TreeShape(workspaceID: Self.flaggedShapeID, sessionIDs: store.flaggedSessions.map(\.id))]
            }
        }

        /// Reloads only the rows whose visible content (label, split icon, or badge) changed — the
        /// session row and, for a badge roll-up, its workspace row. A per-row `reloadItem` re-renders
        /// just that row at its stable frame, so a name/cwd update never re-lays-out the whole tree.
        /// Skipped mid-rename so it can't drop an in-progress edit.
        private func reloadChangedContentRows() {
            guard let outline = outlineView, !renameController.isCommitting, !renameController.isEditing else { return }
            func reloadIfChanged(_ id: UUID, _ content: RowContent) {
                guard content != lastRowContent[id] else { return }
                lastRowContent[id] = content
                if let node = nodeCache[id] { outline.reloadItem(node) }
            }
            for workspace in store.workspaces {
                reloadIfChanged(workspace.id, rowContent(forWorkspace: workspace))
                for session in workspace.sessions {
                    reloadIfChanged(session.id, rowContent(forSession: session, workspaceName: workspace.name))
                }
            }
        }

        /// Records the current visible content (label, split icon, badge) of every row (keyed by their
        /// distinct ids) so the next reconcile can detect a per-row content delta.
        private func snapshotRowContent() {
            var snapshot: [UUID: RowContent] = [:]
            for workspace in store.workspaces {
                snapshot[workspace.id] = rowContent(forWorkspace: workspace)
                for session in workspace.sessions {
                    snapshot[session.id] = rowContent(forSession: session, workspaceName: workspace.name)
                }
            }
            lastRowContent = snapshot
        }

        /// The visible content of a workspace row. The single builder shared by `reloadChangedContentRows`
        /// and `snapshotRowContent` so the change-detection snapshot and the diff can't drift.
        private func rowContent(forWorkspace workspace: Workspace) -> RowContent {
            RowContent(label: workspace.name, hasSplit: false, unseen: effectiveUnseen(workspace.unseenCount),
                       indicator: AgentIndicator(), flagged: false)
        }

        /// The visible content of a session row. The single builder shared by `reloadChangedContentRows`
        /// and `snapshotRowContent` so the change-detection snapshot and the diff can't drift. Both callers
        /// iterate the `workspace … session` tree, so they pass the owning `workspaceName` in — the label
        /// then needs no `session(withID:)`/`workspace(forSession:)` lookup, keeping the reconcile linear.
        private func rowContent(forSession session: Session, workspaceName: String) -> RowContent {
            RowContent(label: rowLabel(for: session, workspaceName: workspaceName), hasSplit: session.hasSplit,
                       unseen: effectiveUnseen(session.unseenCount),
                       indicator: effectiveIndicator(forSession: session.id), flagged: session.flagged)
        }

        /// Rebuilds `roots` from the store, reusing cached node instances by id so
        /// NSOutlineView item identity and expansion state stay stable, then reloads
        /// the outline preserving expansion.
        func rebuildAndReload() {
            guard let outline = outlineView else { return }

            // flagged mode: the root's children are the flagged sessions as flat, non-expandable rows; no
            // workspace nodes participate, so they fall out of the cache below.
            if store.sidebarMode == .flagged {
                var seen = Set<UUID>()
                roots = store.flaggedSessions.map { session in
                    seen.insert(session.id)
                    return node(for: session.id, kind: .session)
                }
                nodeCache = nodeCache.filter { seen.contains($0.key) }
                outline.reloadData()
                updateEmptyState()
                return
            }

            // render only the visible workspaces: the focused workspace's subtree alone when focus is set
            // (and that workspace still exists), else the full tree.
            var seen = Set<UUID>()
            var newRoots: [SidebarNode] = []
            for workspace in store.visibleWorkspaces {
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

            // keep the tracked set in step with the model: drop ids for workspaces that no longer exist,
            // then pick up any the model reports expanded but that aren't tracked yet — a workspace added
            // at runtime defaults `isExpanded == true`, so this renders it open rather than collapsed. A
            // user-collapsed workspace has `isExpanded == false` (so it's excluded) and a programmatic
            // reveal keeps its already-present id (formUnion only adds), so neither is disturbed.
            expandedWorkspaceIDs.formIntersection(Set(store.workspaces.map(\.id)))
            expandedWorkspaceIDs.formUnion(store.workspaces.filter(\.isExpanded).map(\.id))

            // restore expansion from the tracked set rather than the live outline state: a flagged-mode
            // reload drops the workspace nodes, so the outline forgets they were expanded, but the tracked
            // set remembers across the interlude. A freshly-focused workspace is expanded unconditionally —
            // focus is a "zoom in", so its sessions must show even if the workspace was collapsed. This
            // re-apply is a VIEW restore, not a user action, so suppress the persist: a focused-but-collapsed
            // workspace must keep its persisted collapse (the zoom-in shows it, but doesn't un-collapse it).
            outline.reloadData()
            suppressExpansionPersist = true
            for node in roots where expandedWorkspaceIDs.contains(node.id) || node.id == store.focusedWorkspaceID {
                outline.expandItem(node)
            }
            suppressExpansionPersist = false
            updateEmptyState()
        }

        /// Adds the flagged-mode empty-state hint near the top of the scroll view (below the safe-area
        /// inset, so it clears the titlebar) as a non-scrolling overlay (a sibling of the clip view, so it
        /// floats above the document and stays put). Hidden until the flagged view is empty.
        func installEmptyState(in scroll: NSScrollView) {
            let label = NSTextField(wrappingLabelWithString: "No flagged sessions.\nRight-click a session → Flag.")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = .center
            label.isEditable = false
            label.isSelectable = false
            label.drawsBackground = false
            label.isBordered = false
            label.font = .preferredFont(forTextStyle: .body)
            label.isHidden = true
            scroll.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                label.topAnchor.constraint(equalTo: scroll.safeAreaLayoutGuide.topAnchor, constant: 40),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -16),
            ])
            emptyStateLabel = label
            updateEmptyState()
        }

        /// Shows the empty-state hint only in flagged mode with no flagged sessions; re-tints it to the
        /// current theme foreground (dimmed, like a placeholder).
        func updateEmptyState() {
            guard let label = emptyStateLabel else { return }
            label.isHidden = !(store.sidebarMode == .flagged && store.flaggedSessions.isEmpty)
            label.textColor = (GhosttyApp.shared.terminalForegroundColor ?? .secondaryLabelColor).withAlphaComponent(0.6)
        }

        /// Seeds the tracked expansion set from the persisted per-workspace state (`Workspace.isExpanded`),
        /// so the launch reload restores each workspace's saved open/collapsed state. Sets only the tracked
        /// set — `rebuildAndReload` applies it to the outline. Called once from `makeNSView`.
        func seedExpansionFromModel() {
            expandedWorkspaceIDs = Set(store.workspaces.filter(\.isExpanded).map(\.id))
        }

        /// Expands every workspace row — the "Expand Workspaces" user action. Seeds the tracked expansion
        /// from the live `store.workspaces`, NOT the current `roots` (a single subtree when a workspace is
        /// focused), so unfocusing back to the full tree remembers every workspace as expanded. The
        /// per-item callbacks are suppressed; the whole-tree state is persisted once via
        /// `setWorkspacesExpanded` since this is a deliberate all-workspace command.
        func expandAll() {
            guard let outline = outlineView else { return }
            for workspace in store.workspaces { expandedWorkspaceIDs.insert(workspace.id) }
            suppressExpansionPersist = true
            for node in roots where node.kind == .workspace { outline.expandItem(node) }
            suppressExpansionPersist = false
            store.setWorkspacesExpanded(expandedWorkspaceIDs)
        }

        /// Collapses every workspace except the active one (the workspace of the active session,
        /// `store.currentWorkspaceID`), keeping that one expanded and scrolling its row into view so it
        /// stays visible. Tree-mode only — no workspace rows exist in flagged mode, so it is a graceful
        /// no-op there.
        func collapseOthers() {
            guard let outline = outlineView, store.sidebarMode == .tree else { return }
            let keepID = store.currentWorkspaceID
            // this command targets ALL workspaces, not just the visible `roots`: reduce the tracked set to
            // exactly the active workspace so a focus filter that hides some workspaces can't leave them in
            // the set and get them persisted expanded by the batch write below. The outline expand/collapse
            // only touches the rows currently on screen.
            if let keepID { expandedWorkspaceIDs = [keepID] } else { expandedWorkspaceIDs = [] }
            suppressExpansionPersist = true
            for node in roots where node.kind == .workspace {
                if node.id == keepID {
                    if !outline.isItemExpanded(node) { outline.expandItem(node) }
                } else if outline.isItemExpanded(node) {
                    outline.collapseItem(node)
                }
            }
            suppressExpansionPersist = false
            // persist the whole-tree collapse state once — this is a deliberate command, so it writes every
            // workspace (only the active one expanded), unlike the per-toggle callback path.
            store.setWorkspacesExpanded(expandedWorkspaceIDs)
            // keep the active workspace's row on screen (mirrors syncSelection's scroll-into-view).
            guard let keepID, let node = nodeCache[keepID] else { return }
            let row = outline.row(forItem: node)
            if row >= 0 { outline.scrollRowToVisible(row) }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?[Self.outlineItemUserInfoKey] as? SidebarNode,
                  node.kind == .workspace else { return }
            expandedWorkspaceIDs.insert(node.id)
            // persist ONLY a genuine user expand (row click / disclosure triangle). A programmatic reveal or
            // rebuild re-apply sets suppressExpansionPersist, so it updates the visual set above without
            // burning the persisted collapse intent.
            if !suppressExpansionPersist { store.setWorkspaceExpanded(node.id, expanded: true) }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?[Self.outlineItemUserInfoKey] as? SidebarNode,
                  node.kind == .workspace else { return }
            expandedWorkspaceIDs.remove(node.id)
            // persist only a genuine user collapse; programmatic collapses are suppressed (see didExpand).
            if !suppressExpansionPersist { store.setWorkspaceExpanded(node.id, expanded: false) }
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
                lastRevealedSelection = nil
                return
            }
            // the row-selection sync runs every call (keeps the highlight correct), but the intrusive
            // reveal — expanding a collapsed owner and scrolling into view — only fires when the
            // selection actually changed, so unrelated cwd/title/badge updates to the already-selected
            // session leave a user-collapsed workspace and a user-moved scroll position alone.
            let selectionChanged = selectedID != lastRevealedSelection
            // a session selected by keyboard nav may live in a collapsed workspace, whose row is -1
            // until expanded; expand its owner first so the row resolves. This reveal is a VIEW action,
            // not a user expand, so suppress the persist: navigating into (or launching with the selection
            // inside) a deliberately-collapsed workspace shows the session without un-collapsing it on disk.
            if selectionChanged, let owner = ownerWorkspaceNode(ofSession: selectedID), !outline.isItemExpanded(owner) {
                suppressExpansionPersist = true
                outline.expandItem(owner)
                suppressExpansionPersist = false
            }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            if outline.selectedRow != row {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            if selectionChanged {
                outline.scrollRowToVisible(row)
            }
            lastRevealedSelection = selectedID
        }

        /// The workspace node containing `sessionID` (its `children`), or nil if not found — used to
        /// expand a collapsed owner before resolving a keyboard-navigated session's row.
        private func ownerWorkspaceNode(ofSession sessionID: UUID) -> SidebarNode? {
            roots.first { $0.children.contains { $0.id == sessionID } }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            // repaint the selection pill + row text colors for the new selection (with .none highlight
            // style AppKit won't redraw rows on its own).
            refreshSelectionAppearance()
            guard !applyingSelection, let outline = outlineView else { return }
            let row = outline.selectedRow
            guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode, node.kind == .session else {
                return
            }
            // a genuine user row click (the applyingSelection guard above skips programmatic sync, so
            // auto-follow's own jump never reaches here) counts as activity: it buys the full idle grace
            // before auto-follow can pull the selection back.
            store.noteUserActivity()
            store.selectSession(node.id)
            // land on the selected session's blocked pane when it carries a pane-tagged block (a no-op
            // otherwise), async so it runs after the selection + the sidebar's own focus-restore settle.
            DispatchQueue.main.async { [weak self] in self?.actions.revealActiveBlockedPane() }
        }

        /// Returns keyboard focus to the active session's terminal after a sidebar
        /// interaction, so the sidebar never keeps focus (typing always reaches the
        /// terminal). Mirrors macterm's `FocusRestoration`: the target surface may not be
        /// attached to the window yet (a just-selected session's view is still
        /// materializing), so retry on the run loop until it is, with a bounded cap.
        /// Skipped while a rename field is the first responder or an edit is in progress.
        func focusActiveTerminal(attempt: Int = 0) {
            // never steal focus from an in-progress rename.
            if renameController.isEditing { return }
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

        /// Leading row icons: a 2x2 grid glyph for a workspace, an outlined terminal for a single
        /// session, and a split-rectangle for a split session, rendered as monochrome template symbols.
        /// The two `flagged*` variants swap to the `.fill` SF Symbol (a solid interior — the same
        /// "small filled area" idiom the scratch-active toolbar glyph uses): `terminal.fill` for a
        /// single session, `rectangle.split.2x1.fill` for a split. A pure symbol swap, not a composited
        /// corner badge, so it stays a single template `setColors` tints and reserves no extra space.
        /// Cached because only a few distinct symbols exist and every row reuses them.
        lazy var workspaceIcon = Self.rowIcon("square.grid.2x2")
        lazy var splitSessionIcon = Self.rowIcon("rectangle.split.2x1")
        lazy var sessionIcon = Self.rowIcon("terminal")
        lazy var flaggedSessionIcon = Self.rowIcon("terminal.fill")
        lazy var flaggedSplitSessionIcon = Self.rowIcon("rectangle.split.2x1.fill")

        private static func rowIcon(_ symbolName: String) -> NSImage? {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            return image
        }

        /// The row label from an already-resolved session + its owning workspace name, with no store lookup —
        /// the form the reconcile loops use (they iterate the `workspace … session` tree).
        func rowLabel(for session: Session, workspaceName: String) -> String {
            guard store.sidebarMode == .flagged else { return session.displayName }
            return "\(session.displayName) : \(workspaceName)"
        }

        func workspaceNode(forID id: UUID) -> SidebarNode? {
            roots.first(where: { $0.id == id })
        }
    }
}

/// An `NSOutlineView` subclass that serves a per-row context menu and starts
/// inline rename on double-click, both routed to the coordinator.
final class SidebarOutlineView: NSOutlineView {
    // never become first responder: focus lives in the terminal. A mouse click still selects the row
    // (selection is independent of first responder), but without this the click steals first responder,
    // and the responder bounce (terminal → outline → terminal, via mouseDown's focusActiveTerminal) makes
    // AppKit re-set `isEmphasized` on the rows — an extra repaint that flicks the selection pill on every
    // click. Programmatic selection (palette/Ctrl-Tab) never bounces, so it's already smooth.
    override var acceptsFirstResponder: Bool { false }

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

extension Notification.Name {
    /// Posted by the menu/palette to start an inline rename of the active session or its
    /// workspace; `WorkspaceSidebar.Coordinator` observes these and begins editing the row.
    static let agtermBeginRenameSession = Notification.Name("agterm.beginRenameSession")
    static let agtermBeginRenameWorkspace = Notification.Name("agterm.beginRenameWorkspace")
    /// Posted by the menu/palette/control channel to expand every workspace, or to collapse every
    /// workspace except the active one. Posted with the frontmost window's `AppStore` as the object so
    /// `WorkspaceSidebar.Coordinator` observes them scoped to that one window's sidebar.
    static let agtermExpandWorkspaces = Notification.Name("agterm.expandWorkspaces")
    static let agtermCollapseWorkspaces = Notification.Name("agterm.collapseWorkspaces")
    /// Posted by the `session.resize` control arm after it stores a new split-divider fraction, with the
    /// target `Session` as the object so the matching `SplitProbeView` (in `ContentView`) moves the live
    /// divider to `Session.splitRatio`. Object-scoped like the expand/collapse pokes, so only the one
    /// session's pane view reacts.
    static let agtermApplySplitRatio = Notification.Name("agterm.applySplitRatio")
}
