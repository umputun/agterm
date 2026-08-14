import agtermCore
import AppKit
import SwiftUI

/// Local-only (within-outline) pasteboard type carrying a dragged session's UUID.
let sessionPasteboardType = NSPasteboard.PasteboardType("com.umputun.agterm.session")

/// Local-only pasteboard type carrying a dragged workspace's UUID.
let workspacePasteboardType = NSPasteboard.PasteboardType("com.umputun.agterm.workspace")

/// AppKit `NSOutlineView` sidebar hosted in SwiftUI via `NSViewRepresentable`, chosen over a SwiftUI
/// `List` so cross-workspace drag-and-drop works natively: a session row dragged onto another workspace
/// moves in the model, preserving the same `Session` instance.
///
/// Two-level tree: workspaces (expandable parents, bold) → sessions (children). Only session rows are
/// selectable detail targets; inline rename via double-click or the "Rename" context menu, and per-row
/// context menus drive the store API.
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
        // .plain (not .sourceList) drops the built-in ~10px top inset above the first row, so the tree runs
        // flush below the titlebar; a custom row height restores the roomy size .plain's .default shrinks
        // to ~17px.
        outline.rowSizeStyle = .custom
        outline.rowHeight = AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.autosaveExpandedItems = false
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.handleSingleClick(_:))
        outline.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        if #available(macOS 11.0, *) { outline.style = .plain }
        // .plain reverts backgroundColor to an OPAQUE controlBackgroundColor (unlike .sourceList's
        // translucent material), painting over the tint wash and the terminal-colored window backing —
        // clear it, matching scroll.drawsBackground = false below.
        outline.backgroundColor = .clear
        // AppKit would paint a gray unemphasized capsule whenever the sidebar isn't first responder (focus
        // lives in the terminal); SidebarRowView draws the themed pill in drawBackground for every state.
        outline.selectionHighlightStyle = .none
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        // native drag-and-drop: session rows reorder within / move across workspaces; workspace rows
        // reorder among themselves; Finder folder drops create sessions rooted at those folders. Without
        // the workspace type registered AppKit never delivers validate/accept for a workspace drag.
        outline.registerForDraggedTypes([sessionPasteboardType, workspacePasteboardType, .fileURL])
        // sidebar rows are app-private move sources with no public representation; the Finder import is
        // independent — Finder owns that external source and supplies `.fileURL`.
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)

        context.coordinator.outlineView = outline
        context.coordinator.renameController.outlineView = outline
        // pin the appearance up front so the disclosure triangle reads on launch.
        context.coordinator.applyThemeAppearance()
        // seed tracked expansion BEFORE the reload, so rebuildAndReload restores each workspace's saved
        // open/collapsed state instead of force-expanding every row.
        context.coordinator.seedExpansionFromModel()
        context.coordinator.rebuildAndReload()
        context.coordinator.syncSelection()
        // on launch AppKit makes the sidebar the window's initial first responder; hand focus to the terminal.
        context.coordinator.focusActiveTerminal()

        let scroll = NSScrollView()
        scroll.identifier = NSUserInterfaceItemIdentifier("agterm-sidebar-scroll")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        // otherwise macOS set to "Show scroll bars: Always" paints a permanent track over a tree that fits.
        scroll.autohidesScrollers = true
        // transparent so the window's backgroundColor (the terminal color, set by WindowAppearance) shows
        // through and the whole column — including the strip behind the titlebar — reads as one surface.
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.installEmptyState(in: scroll)
        // inset the tree to match the terminal's ghostty padding.
        context.coordinator.applySidebarContentInset(scroll)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // touching the observed store properties HERE registers this representable as an observer, so
        // SwiftUI re-invokes updateNSView on any tracked change and reconcile can do a targeted per-row
        // reload; a touch inside viewFor wouldn't register it. The badge-visibility toggle
        // (GhosttyApp.notificationBadgeEnabled) is NOT observable and drives a re-reconcile via
        // .agtermAppearanceChanged, like toolbarMode.
        _ = store.workspaces.map { ($0.id, $0.name, $0.unseenCount, $0.sessions.map { ($0.id, $0.displayName, $0.hasSplit, $0.splitAxis, $0.unseenCount, $0.agentIndicator, $0.flagged) }) }
        _ = store.selectedSessionID
        _ = store.sidebarSelectionIDs
        // sidebarMode flips the whole data source (tree ↔ flat flagged list), so a mode change must rebuild.
        _ = store.sidebarMode
        // the marked set restricts the tree to its members while the filter is on; BOTH fields are read so
        // a membership change or a filter flip takes the rebuild branch.
        _ = store.focusedWorkspaceIDs
        _ = store.focusEnabled
        context.coordinator.reconcile()
        context.coordinator.syncSelection()
    }

    /// Backs the outline as data source and delegate. `@MainActor` so the AppKit delegate callbacks (all
    /// main-thread) satisfy the store's main-actor isolation under strict concurrency.
    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let store: AppStore
        let actions: AppActions
        let renameController: SidebarRenameController
        weak var outlineView: NSOutlineView?

        /// Root workspace nodes in store order, rebuilt from the store on each reload from cached instances.
        private var roots: [SidebarNode] = []
        /// Cache of node instances keyed by id, so identity is stable across reloads.
        private var nodeCache: [UUID: SidebarNode] = [:]
        /// Guards `syncSelection` against re-entering the store via the selection-change callback it fires.
        private var applyingSelection = false
        /// Last session id whose row was revealed (expanded owner + scrolled into view). Gates the intrusive
        /// reveal so unrelated updates (cwd/title/badge) to the already-selected session don't re-expand a
        /// collapsed workspace or yank the scroll position back.
        private var lastRevealedSelection: UUID?
        /// Last-seen `TreeShape`; a change is structural and forces a full rebuild.
        private var lastShape: [TreeShape] = []
        /// Last-seen sidebar mode; a flip forces a full `rebuildAndReload` independent of the shape diff.
        private var lastMode: SidebarMode = .tree
        /// Workspace ids the user has expanded, tracked via the expand/collapse callbacks. The source of
        /// truth for restoring expansion on rebuild: NSOutlineView discards its own expansion state for
        /// items it no longer renders, and the flagged-mode reload drops every workspace node.
        /// Mirrored into the store on every assignment — a suppressed reveal opens a row without touching
        /// `Workspace.isExpanded`, so the persisted flag alone cannot answer "is this row open right now",
        /// which is what Collapse/Expand Workspace has to fold. One `didSet` rather than a push beside each
        /// of the seven mutation sites, because a missed site desynchronizes silently. Deliberately NOT
        /// delta-guarded: a fresh Coordinator starts empty, so seeding an all-collapsed tree assigns empty
        /// over empty and a guard would skip the push, leaving the PREVIOUS mount's ids in the store while
        /// the outline shows every row folded. The store field is `@ObservationIgnored`, so a redundant
        /// push costs one set copy and invalidates nothing.
        private var expandedWorkspaceIDs = Set<UUID>() {
            didSet { store.noteSidebarExpansion(expandedWorkspaceIDs) }
        }
        /// Set true around PROGRAMMATIC `expandItem`/`collapseItem` (the launch/rebuild re-apply, the
        /// `syncSelection` reveal, the focus force-expand): the didExpand/DidCollapse callbacks still update
        /// the visual `expandedWorkspaceIDs` but SKIP the persist write-back, so a view-only reveal never
        /// burns a persisted collapse. `expandAll`/`collapseOthers` set it too and persist once at the end.
        var suppressExpansionPersist = false
        /// Scheduled single-click workspace toggle, deferred by the double-click interval so a rename
        /// double-click can cancel it — else its first click flips the workspace open on the way into edit.
        var pendingRowToggle: DispatchWorkItem?
        /// Scheduled spring-loaded workspace expand while a drag hovers over a collapsed workspace row.
        /// View-only like the selection reveal: opens the target for this drag without persisting expansion.
        var pendingSpringLoadedExpansion: (workspaceID: UUID, workItem: DispatchWorkItem)?
        /// A workspace opened by spring-loading during the current drag. Finder-style spring navigation is
        /// transient: leaving/cancelling collapses this row back to its pre-drag state.
        var springLoadedWorkspaceID: UUID?
        /// Finder file URLs resolved for the current AppKit dragging sequence. Validation runs on every
        /// mouse move, so caching keeps network-volume metadata checks out of the hot path.
        var cachedDirectoryDrop: (sequenceNumber: Int, urls: [URL], exceedsLimit: Bool)?

        /// Stable pseudo-workspace id for the flat flagged group's `TreeShape`, so only a change to the
        /// flagged session list — not a per-call fresh id — triggers a rebuild.
        private static let flaggedShapeID = UUID()

        /// The `userInfo` key AppKit uses for the item in `outlineViewItemDidExpand`/`DidCollapse`
        /// notifications (documented as the literal string `"NSObject"`).
        private static let outlineItemUserInfoKey = "NSObject"

        /// `userInfo` keys for the `.agtermSetWorkspaceExpanded` per-workspace poke: the target workspace
        /// `UUID` and the desired `Bool` state, written by `AppActions.setWorkspaceExpanded(_:expanded:in:)`.
        static let workspaceIDUserInfoKey = "agterm.workspaceID"
        static let expandedUserInfoKey = "agterm.expanded"

        /// Last-seen visible content (label, split icon, badge) per session and workspace id, so a
        /// reconcile reloads only the rows whose content changed. An absent key ≠ any real content.
        private var lastRowContent: [UUID: RowContent] = [:]

        /// The sidebar font size last applied (row height + row fonts). `.agtermAppearanceChanged` fires for
        /// every settings change, so `appearanceChanged` compares against this and rebuilds only on a change.
        private var lastSidebarFontSize: CGFloat = CGFloat(AppSettings.defaultSidebarFontSize)

        /// Centered hint floating over the empty outline in flagged mode; hidden otherwise.
        private weak var emptyStateLabel: NSTextField?

        init(store: AppStore, actions: AppActions) {
            self.store = store
            self.actions = actions
            self.renameController = SidebarRenameController(store: store)
            super.init()
            // seed from the live mirror (SettingsModel applies the persisted size before any sidebar is
            // built) so the first appearanceChanged doesn't rebuild for no change.
            lastSidebarFontSize = GhosttyApp.shared.sidebarFontSize
            renameController.onRenameEnded = { [weak self] in self?.focusActiveTerminal() }
            // the menu/palette can't reach the inline editor directly, so they post a notification. Scoped
            // by `object: store`: the handlers' selected-session guard is NOT a per-window scope, so an
            // `object: nil` pairing starts an inline edit in EVERY window — each leaving an unopened editor
            // plus an unbalanced `suppressAutoFollow` that wedges that window's idle auto-follow off for good.
            NotificationCenter.default.addObserver(self, selector: #selector(beginRenameSessionNotified),
                                                   name: .agtermBeginRenameSession, object: store)
            NotificationCenter.default.addObserver(self, selector: #selector(beginRenameWorkspaceNotified),
                                                   name: .agtermBeginRenameWorkspace, object: store)
            // expand/collapse target ONLY the frontmost window's sidebar: AppActions posts with the
            // frontmost store as the object, so `object: store` delivers to that Coordinator alone.
            NotificationCenter.default.addObserver(self, selector: #selector(expandWorkspacesNotified),
                                                   name: .agtermExpandWorkspaces, object: store)
            NotificationCenter.default.addObserver(self, selector: #selector(collapseWorkspacesNotified),
                                                   name: .agtermCollapseWorkspaces, object: store)
            // the per-workspace collapse/expand poke (workspace.collapse/expand) is store-scoped the same way.
            NotificationCenter.default.addObserver(self, selector: #selector(setWorkspaceExpandedNotified(_:)),
                                                   name: .agtermSetWorkspaceExpanded, object: store)
            // a theme change (new terminal foreground) re-tints the visible rows in place.
            NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
                                                   name: .agtermAppearanceChanged, object: nil)
            // Reduce Motion does not alter row model content, so re-apply visible status glyphs explicitly.
            NotificationCenter.default.addObserver(self, selector: #selector(accessibilityDisplayOptionsChanged),
                                                   name: .agtermAccessibilityDisplayOptionsChanged, object: nil)
        }

        isolated deinit {
            pendingSpringLoadedExpansion?.workItem.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        /// Re-tint the visible rows and redraw the selection pills without a `reloadData` — needed on a
        /// selection change (with `selectionHighlightStyle == .none` AppKit won't) and on a theme change.
        func refreshSelectionAppearance() {
            guard let outline = outlineView else { return }
            for row in 0 ..< outline.numberOfRows {
                let selected = outline.selectedRowIndexes.contains(row)
                (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView)?.setColors(selected: selected)
            }
            outline.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
        }

        /// Pin the outline's appearance to the terminal theme's brightness so AppKit-drawn chrome — the
        /// disclosure triangle — tracks the theme, not the macOS light/dark setting: a light theme under
        /// macOS dark mode otherwise draws a light-gray triangle invisible on it (row text/icons survive
        /// only because they are set explicitly to the theme color).
        func applyThemeAppearance() {
            outlineView?.appearance = NSAppearance(named: GhosttyApp.shared.terminalThemeIsDark ? .darkAqua : .aqua)
        }

        /// Inset the tree to line up with the terminal's DEFAULT ghostty padding
        /// (agterm/Resources/ghostty-defaults.conf; a user window-padding override in ghostty.conf is not
        /// tracked): window-padding-x = 8 is the left margin; the top is a 2px nudge, not the full
        /// window-padding-y = 6, because the row already centers its content in a ~28px row. `.plain` adds
        /// no insets of its own, so we own them (auto-adjust off). Same in every toolbar mode.
        func applySidebarContentInset(_ scroll: NSScrollView?) {
            guard let scroll else { return }
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 2, left: 8, bottom: 0, right: 0)
        }

        @objc private func appearanceChanged() {
            applySidebarFontSizeIfChanged()
            refreshSelectionAppearance()
            applyThemeAppearance()
            // a settings change may have flipped the badge-visibility toggle; reconcile reloads those rows.
            reconcile()
            // agent-status colors are global, so the content diff can't see a color change — re-apply all.
            reapplyStatusGlyphs()
            updateEmptyState()
            // cheap re-assert in case a settings change requires recomputing the inset.
            applySidebarContentInset(outlineView?.enclosingScrollView)
        }

        @objc private func accessibilityDisplayOptionsChanged() {
            reapplyStatusGlyphs()
        }

        /// Re-apply the row height + fonts when the sidebar font-size setting changed. The size is not part
        /// of `reconcile`'s per-row content diff, so it needs an explicit row-height update plus a full
        /// `rebuildAndReload` to re-run the cell builder, guarded on the tracked value.
        private func applySidebarFontSizeIfChanged() {
            let size = GhosttyApp.shared.sidebarFontSize
            guard size != lastSidebarFontSize else { return }
            lastSidebarFontSize = size
            outlineView?.rowHeight = AppSettings.sidebarRowHeight(fontSize: size)
            rebuildAndReload()
        }

        /// Re-apply the status glyph on every visible session row so a global agent-status color change
        /// (from Settings) re-renders it. Appearance changes are rare, so the full sweep is cheap.
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

        /// Expand every workspace in this window's sidebar. Gated on tree mode here so `expandAll`'s
        /// tracked-expansion seeding can't fire in flagged mode, where there are no workspace rows.
        @objc private func expandWorkspacesNotified() {
            guard store.sidebarMode == .tree else { return }
            expandAll()
        }

        /// Collapse every workspace except the active one; `collapseOthers` gates on tree mode itself.
        @objc private func collapseWorkspacesNotified() {
            collapseOthers()
        }

        /// Sync the sidebar to a SINGLE workspace's collapse/expand — `workspace.collapse`/`.expand` and the
        /// GUI's own Collapse/Expand Workspace, which share `AppActions.setWorkspaceExpanded`.
        /// `AppActions.setWorkspaceExpanded` has ALREADY persisted `Workspace.isExpanded` — the source of
        /// truth, independent of this Coordinator — so this handler only keeps the tracked
        /// `expandedWorkspaceIDs` in step (letting the intent survive a flagged-mode or focused-away row and
        /// a focus force-reveal) and drives the live outline row when on screen, suppressing its re-persist.
        @objc private func setWorkspaceExpandedNotified(_ notification: Notification) {
            guard let id = notification.userInfo?[Self.workspaceIDUserInfoKey] as? UUID,
                  let expanded = notification.userInfo?[Self.expandedUserInfoKey] as? Bool else { return }
            if expanded { expandedWorkspaceIDs.insert(id) } else { expandedWorkspaceIDs.remove(id) }
            guard store.sidebarMode == .tree, let outline = outlineView,
                  let node = nodeCache[id], outline.row(forItem: node) >= 0 else { return }
            suppressExpansionPersist = true
            if expanded { outline.expandItem(node) } else { outline.collapseItem(node) }
            suppressExpansionPersist = false
        }

        // MARK: - Model rebuild

        /// The tree SHAPE: a workspace's id and its ordered session ids. Equal shapes mean no
        /// add/remove/move/reorder, so a content change takes a targeted per-row reload. Row TEXT is NOT
        /// here: a cwd-driven `displayName` change must not `reloadData` + re-expand, which jitters labels.
        private struct TreeShape: Equatable {
            let workspaceID: UUID
            let sessionIDs: [UUID]
        }

        /// A row's visible content: label (workspace name or session `displayName`), split-rectangle icon,
        /// the gated unseen-badge count and the agent-status indicator. A delta reloads just that row. Uses
        /// `hasSplit` (not `isSplit`) so the icon persists while a split is hidden.
        private struct RowContent: Equatable {
            let label: String
            let hasSplit: Bool
            let splitAxis: SplitAxis
            let unseen: Int
            let indicator: AgentIndicator
            /// Whether the session is flagged (tree-mode filled-icon variant). A change re-badges just this
            /// row via `reloadItem`. Always false for workspace rows.
            let flagged: Bool
            /// Whether the workspace is in the focus set (the black-weight grid icon). MEMBERSHIP only,
            /// independent of `focusEnabled`, so marking re-renders just that row even while the filter is
            /// off (with it on the shape changes too and the rebuild branch takes over). False for sessions.
            let focusMember: Bool
        }

        /// The session's own agent-status indicator (`.idle` for an unknown id / workspace row). Shown
        /// regardless of selection — `completed --auto-reset` clears itself on `selectSession`, so a
        /// visited session drops its glyph without a render-time gate.
        func effectiveIndicator(forSession id: UUID) -> AgentIndicator {
            store.session(withID: id)?.agentIndicator ?? AgentIndicator()
        }

        /// The unseen count after the badge-visibility gate: 0 when the Settings toggle is off. Render-only
        /// — `unseenCount` keeps tracking, so re-enabling instantly shows current counts. The agent-status
        /// glyph is NOT gated by this.
        func effectiveUnseen(_ count: Int) -> Int {
            GhosttyApp.shared.notificationBadgeEnabled ? count : 0
        }

        /// Decides between a full rebuild (a SHAPE change: add/move/close/reorder) and a targeted per-row
        /// reload (a content change: rename, cwd-driven name, split open/close, badge). A reload during an
        /// in-progress rename is skipped so a tick can't drop the edit.
        func reconcile() {
            // a mode flip swaps the whole data source, so rebuild regardless of the shape diff.
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

        /// The structural shape for the current mode: the workspace tree, or one flat group of the flagged
        /// session ids. A change means an add/remove/move/reorder (or a flag/unflag in flagged mode) and
        /// forces a full rebuild. The tree case derives from `visibleWorkspaces`, so marking a workspace or
        /// flipping the focus filter counts as a shape change too.
        private func currentShape() -> [TreeShape] {
            switch store.sidebarMode {
            case .tree:
                return store.visibleWorkspaces.map { TreeShape(workspaceID: $0.id, sessionIDs: $0.sessions.map(\.id)) }
            case .flagged:
                return [TreeShape(workspaceID: Self.flaggedShapeID, sessionIDs: store.flaggedSessions.map(\.id))]
            }
        }

        /// Reloads only the rows whose visible content changed — the session row and, for a badge roll-up,
        /// its workspace row. A per-row `reloadItem` re-renders at the row's stable frame, so a name/cwd
        /// update never re-lays-out the tree. Skipped mid-rename so it can't drop an in-progress edit.
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

        /// Records every row's current visible content, keyed by id, so the next reconcile can diff it.
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

        /// The visible content of a workspace row. One builder shared by `reloadChangedContentRows` and
        /// `snapshotRowContent` so the snapshot and the diff can't drift.
        private func rowContent(forWorkspace workspace: Workspace) -> RowContent {
            RowContent(label: workspace.name, hasSplit: false, splitAxis: .leftRight,
                       unseen: effectiveUnseen(workspace.unseenCount),
                       indicator: AgentIndicator(), flagged: false,
                       focusMember: store.focusedWorkspaceIDs.contains(workspace.id))
        }

        /// The visible content of a session row. One builder shared by `reloadChangedContentRows` and
        /// `snapshotRowContent` so the snapshot and the diff can't drift. Both callers pass the owning
        /// `workspaceName` in, so the label needs no per-session lookup and the reconcile stays linear.
        private func rowContent(forSession session: Session, workspaceName: String) -> RowContent {
            RowContent(label: rowLabel(for: session, workspaceName: workspaceName), hasSplit: session.hasSplit,
                       splitAxis: session.splitAxis,
                       unseen: effectiveUnseen(session.unseenCount),
                       indicator: effectiveIndicator(forSession: session.id), flagged: session.flagged,
                       focusMember: false)
        }

        /// Rebuilds `roots` from the store, reusing cached node instances by id so NSOutlineView item
        /// identity and expansion state stay stable, then reloads the outline preserving expansion.
        func rebuildAndReload() {
            guard let outline = outlineView else { return }

            // flagged mode: flat, non-expandable session rows; no workspace nodes, so they leave the cache.
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

            // render only the visible workspaces: the marked set when the focus filter is on, else all.
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
            nodeCache = nodeCache.filter { seen.contains($0.key) }
            roots = newRoots

            // keep the tracked set in step with the model: drop ids for workspaces that no longer exist,
            // then pick up any the model reports expanded — a runtime-added workspace defaults
            // `isExpanded == true`, so it renders open, while a user-collapsed one and a reveal's
            // already-present id are undisturbed (formUnion only adds).
            expandedWorkspaceIDs.formIntersection(Set(store.workspaces.map(\.id)))
            expandedWorkspaceIDs.formUnion(store.workspaces.filter(\.isExpanded).map(\.id))

            // restore expansion from the tracked set, not the live outline state, which forgets across a
            // flagged-mode reload. A filter applied to a SINGLE marked workspace also force-expands it — a
            // "zoom in", so its sessions show even from a collapsed row. The force stops at one member on
            // purpose: with a working SET the tree is a list of workspaces, not a zoom, and re-expanding
            // every member on each rebuild (any session add/close/move re-shapes it) would undo the user's
            // collapse while `tree` still reported it `collapsed`. The re-apply is a VIEW restore, so
            // suppress the persist: a marked-but-collapsed workspace keeps its persisted collapse.
            outline.reloadData()
            suppressExpansionPersist = true
            let forceExpanded = store.soleFocusedWorkspaceID
            for node in roots where expandedWorkspaceIDs.contains(node.id) || forceExpanded == node.id {
                outline.expandItem(node)
            }
            suppressExpansionPersist = false
            updateEmptyState()
        }

        /// Adds the flagged-mode empty-state hint below the safe-area inset so it clears the titlebar, as a
        /// non-scrolling sibling of the clip view floating above the document. Hidden until it applies.
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

        /// Shows the hint only in flagged mode with nothing flagged; re-tints it to the dimmed theme color.
        func updateEmptyState() {
            guard let label = emptyStateLabel else { return }
            label.isHidden = !(store.sidebarMode == .flagged && store.flaggedSessions.isEmpty)
            label.textColor = (GhosttyApp.shared.terminalForegroundColor ?? .secondaryLabelColor).withAlphaComponent(0.6)
        }

        /// Seeds the tracked expansion set from the persisted `Workspace.isExpanded`. Sets only the tracked
        /// set — `rebuildAndReload` applies it to the outline. Called once from `makeNSView`.
        func seedExpansionFromModel() {
            expandedWorkspaceIDs = Set(store.workspaces.filter(\.isExpanded).map(\.id))
        }

        /// Expands every workspace row — the "Expand Workspaces" user action. Seeds the tracked expansion
        /// from the live `store.workspaces`, NOT `roots` (only the marked subtrees while the focus filter is
        /// on), so turning the filter off remembers every workspace as expanded. Per-item callbacks are
        /// suppressed; the whole-tree state is persisted once via `setWorkspacesExpanded`.
        func expandAll() {
            guard let outline = outlineView else { return }
            for workspace in store.workspaces { expandedWorkspaceIDs.insert(workspace.id) }
            suppressExpansionPersist = true
            for node in roots where node.kind == .workspace { outline.expandItem(node) }
            suppressExpansionPersist = false
            store.setWorkspacesExpanded(expandedWorkspaceIDs)
        }

        /// Collapses every workspace except the current one (`store.currentWorkspaceID`), keeping that
        /// one expanded and scrolled into view. Tree-mode only — flagged mode has no workspace rows.
        func collapseOthers() {
            guard let outline = outlineView, store.sidebarMode == .tree else { return }
            let keepID = store.currentWorkspaceID
            // this command targets ALL workspaces, not just the visible `roots`: reduce the tracked set to
            // exactly the active workspace, so a focus filter hiding some can't leave them in the set for
            // the batch write below to persist as expanded. The outline only touches on-screen rows.
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
            // a deliberate command, so persist the whole-tree state once, unlike the per-toggle callback.
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
            // persist ONLY a genuine user expand: a programmatic reveal or rebuild re-apply sets
            // suppressExpansionPersist, updating the visual set above without burning the persisted intent.
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

        /// Reflects `store.selectedSessionID` into the outline selection without re-entering the store.
        /// Workspace rows are never auto-selected.
        func syncSelection() {
            guard let outline = outlineView else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            guard let selectedID = store.selectedSessionID, let node = nodeCache[selectedID], node.kind == .session else {
                outline.deselectAll(nil)
                lastRevealedSelection = nil
                return
            }
            // the row-selection sync runs every call, but the intrusive reveal — expanding a collapsed owner
            // and scrolling into view — only fires on a real selection change, so unrelated cwd/title/badge
            // updates leave a user-collapsed workspace and a user-moved scroll position alone.
            let selectionChanged = selectedID != lastRevealedSelection
            // a session selected by keyboard nav may live in a collapsed workspace, whose row is -1 until
            // expanded; expand its owner first so the row resolves. A VIEW action, so suppress the persist:
            // navigating into a deliberately collapsed workspace shows the session without un-collapsing it
            // on disk.
            if selectionChanged, let owner = ownerWorkspaceNode(ofSession: selectedID), !outline.isItemExpanded(owner) {
                suppressExpansionPersist = true
                outline.expandItem(owner)
                suppressExpansionPersist = false
            }
            var rows = IndexSet()
            let selectedIDs = store.sidebarSelectionIDs.isEmpty ? [selectedID] : store.sidebarSelectionIDs
            for id in selectedIDs {
                guard let selectedNode = nodeCache[id], selectedNode.kind == .session else { continue }
                let selectedRow = outline.row(forItem: selectedNode)
                if selectedRow >= 0 { rows.insert(selectedRow) }
            }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            if rows.isEmpty { rows.insert(row) }
            if outline.selectedRowIndexes != rows {
                outline.selectRowIndexes(rows, byExtendingSelection: false)
            }
            if selectionChanged {
                outline.scrollRowToVisible(row)
            }
            lastRevealedSelection = selectedID
        }

        /// The workspace node whose `children` hold `sessionID` — used to expand a collapsed owner first.
        private func ownerWorkspaceNode(ofSession sessionID: UUID) -> SidebarNode? {
            roots.first { $0.children.contains { $0.id == sessionID } }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            // repaint the selection pill + row text — with the .none highlight style AppKit won't redraw.
            refreshSelectionAppearance()
            guard !applyingSelection, let outline = outlineView else { return }
            let selectedIDs = outline.selectedRowIndexes.compactMap { row -> UUID? in
                guard let node = outline.item(atRow: row) as? SidebarNode, node.kind == .session else { return nil }
                return node.id
            }
            let clickedRow = outline.clickedRow
            let clickedID = (clickedRow >= 0 ? outline.item(atRow: clickedRow) as? SidebarNode : nil).flatMap { node -> UUID? in
                node.kind == .session ? node.id : nil
            }
            let activeID = clickedID.flatMap { id in
                clickedRow >= 0 && outline.selectedRowIndexes.contains(clickedRow) ? id : nil
            } ?? store.selectedSessionID.flatMap { id in selectedIDs.contains(id) ? id : nil }
                ?? selectedIDs.last
            guard let activeID else {
                store.setSidebarSelection(selectedIDs)
                return
            }
            // a genuine user row click (the applyingSelection guard skips programmatic sync, so auto-follow's
            // own jump never reaches here) counts as activity, buying the full idle grace before it pulls back.
            store.noteUserActivity()
            let indicator = store.selectSession(activeID, sidebarSelection: selectedIDs)
            // land on the selected session's blocked pane when it carries a pane-tagged block (else a
            // no-op), async so it runs after the selection + the sidebar's focus-restore settle.
            DispatchQueue.main.async { [weak self] in
                self?.actions.revealActiveBlockedPane(captured: indicator)
            }
        }

        /// Returns keyboard focus to the active session's terminal after a sidebar interaction, mirroring
        /// macterm's `FocusRestoration`: the target surface may not be attached to the window yet (a
        /// just-selected session's view is still materializing), so retry on the run loop with a bounded
        /// cap. Skipped while a rename field is first responder or an edit is in progress.
        ///
        /// Targets `topmostSurface` (overlay, else scratch, else the active pane), not the main `surface`: a
        /// cover owns the keyboard and hides the pane, so focusing a pane would starve the overlay/scratch
        /// program of input and send keystrokes to a surface the user can't see.
        func focusActiveTerminal(attempt: Int = 0) {
            if renameController.isEditing { return }
            let window = outlineView?.window
            if let window, window.firstResponder is NSText { return }
            if let window, let surface = store.activeSession?.topmostSurface as? GhosttySurfaceView, surface.window === window {
                window.makeFirstResponder(surface)
                return
            }
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

        /// Leading row icons as monochrome template symbols. A flagged SESSION swaps to its base glyph's
        /// `.fill` variant (the solid-interior idiom the scratch-active toolbar glyph uses); a workspace in
        /// the focus SET keeps the same `square.grid.2x2` outline at `.black` weight, so the two markers
        /// stay distinct (fill = flagged session, black = marked workspace). Never a composited corner
        /// badge, so each stays a single template `setColors` tints; the weight variant renders 1pt larger
        /// (16x15 vs 15x14) but the icon view is pinned to 16x16, so neither swap moves the row. Cached.
        lazy var workspaceIcon = Self.rowIcon("square.grid.2x2")
        lazy var focusedWorkspaceIcon = Self.rowIcon("square.grid.2x2", weight: .black)
        lazy var splitSessionIcon = Self.rowIcon("rectangle.split.2x1")
        lazy var horizontalSplitSessionIcon = Self.rowIcon("rectangle.split.1x2")
        lazy var sessionIcon = Self.rowIcon("terminal")
        lazy var flaggedSessionIcon = Self.rowIcon("terminal.fill")
        lazy var flaggedSplitSessionIcon = Self.rowIcon("rectangle.split.2x1.fill")
        lazy var flaggedHorizontalSplitSessionIcon = Self.rowIcon("rectangle.split.1x2.fill")

        private static func rowIcon(_ symbolName: String, weight: NSFont.Weight = .regular) -> NSImage? {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: weight)
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            return image
        }

        /// The row label from an already-resolved session + its owning workspace name, with no store lookup.
        func rowLabel(for session: Session, workspaceName: String) -> String {
            guard store.sidebarMode == .flagged else { return session.displayName }
            return "\(session.displayName) : \(workspaceName)"
        }

        func workspaceNode(forID id: UUID) -> SidebarNode? {
            roots.first(where: { $0.id == id })
        }
    }
}

/// `NSOutlineView` subclass routing the per-row context menu and double-click rename to the coordinator.
final class SidebarOutlineView: NSOutlineView {
    // never become first responder: focus lives in the terminal, and a mouse click still selects the row
    // (selection is independent of first responder). Otherwise the responder bounce (terminal → outline →
    // terminal, via mouseDown's focusActiveTerminal) makes AppKit re-set `isEmphasized` on the rows — an
    // extra repaint that flicks the selection pill on every click. Programmatic selection never bounces.
    override var acceptsFirstResponder: Bool { false }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        (delegate as? WorkspaceSidebar.Coordinator)?.finishDraggingSequence()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // standard Mac list behavior: keep a multi-selection when right-clicking one of its selected rows,
        // narrow to the clicked session when right-clicking outside it.
        if row >= 0, let node = item(atRow: row) as? SidebarNode, node.kind == .session,
           !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return (delegate as? WorkspaceSidebar.Coordinator)?.menu(forRow: row)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // after the click is handled, hand keyboard focus back to the terminal; row selection persists
        // (model state), only first responder moves. Skipped mid-rename by the coordinator.
        (delegate as? WorkspaceSidebar.Coordinator)?.focusActiveTerminal()
    }
}

extension Notification.Name {
    /// Posted by the menu/palette to start an inline rename of the active session or its workspace.
    static let agtermBeginRenameSession = Notification.Name("agterm.beginRenameSession")
    static let agtermBeginRenameWorkspace = Notification.Name("agterm.beginRenameWorkspace")
    /// Posted by the menu/palette/control channel to expand every workspace, or collapse all but the active
    /// one, with the frontmost window's `AppStore` as the object so only that window's sidebar reacts.
    static let agtermExpandWorkspaces = Notification.Name("agterm.expandWorkspaces")
    static let agtermCollapseWorkspaces = Notification.Name("agterm.collapseWorkspaces")
    /// Posted for a SINGLE workspace by the `workspace.collapse`/`workspace.expand` control arm and by the
    /// GUI's Collapse/Expand Workspace, with the target window's `AppStore` as the object and the workspace
    /// id + desired state in `userInfo`.
    static let agtermSetWorkspaceExpanded = Notification.Name("agterm.setWorkspaceExpanded")
    /// Posted by the `session.resize` control arm after storing a new split-divider fraction, with the
    /// target `Session` as the object so only that session's `SplitProbeView` (in `ContentView`) moves its
    /// live divider to `Session.splitRatio`.
    static let agtermApplySplitRatio = Notification.Name("agterm.applySplitRatio")
}
