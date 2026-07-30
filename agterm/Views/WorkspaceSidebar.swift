import agtermCore
import AppKit
import SwiftUI

/// Local-only (within-outline) pasteboard type carrying a dragged session's UUID, identifying the
/// session being moved.
let sessionPasteboardType = NSPasteboard.PasteboardType("com.umputun.agterm.session")

/// Local-only pasteboard type carrying a dragged workspace's UUID, identifying the workspace being
/// reordered.
let workspacePasteboardType = NSPasteboard.PasteboardType("com.umputun.agterm.workspace")

/// AppKit `NSOutlineView` sidebar (`.plain` style + a custom row height and top/left content insets that
/// match the terminal's ghostty padding) hosted in SwiftUI via `NSViewRepresentable`. Replaces the
/// SwiftUI `List` sidebar so cross-workspace drag-and-drop works natively: a session row dragged onto
/// another workspace moves in the model, preserving the same `Session` instance.
///
/// Two-level tree: workspaces (expandable parents, bold) → sessions (children). Only session rows are
/// selectable detail targets. Inline rename via double-click or the "Rename" context menu; per-row
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
        // flush below the titlebar in every toolbar mode; a custom row height restores the roomy
        // source-list-like size .plain's .default would shrink to ~17px.
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
        // translucent material), painting over the sidebar tint wash and the terminal-colored/translucent
        // window backing — clear it, matching scroll.drawsBackground = false below.
        outline.backgroundColor = .clear
        // AppKit's own selection drawing would paint a gray unemphasized capsule whenever the sidebar isn't
        // first responder (focus normally lives in the terminal); SidebarRowView draws the themed selection
        // pill in drawBackground for every state.
        outline.selectionHighlightStyle = .none
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        // native drag-and-drop: session rows reorder within / move across workspaces; workspace rows
        // reorder among themselves; Finder folder drops create sessions rooted at those folders. Both
        // private types are load-bearing — without the workspace type AppKit never delivers
        // validate/accept for a workspace drag.
        outline.registerForDraggedTypes([sessionPasteboardType, workspacePasteboardType, .fileURL])
        // sidebar rows are app-private move sources exporting no public representation; Finder folder
        // import is independent — Finder owns that external source and supplies `.fileURL`.
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)

        context.coordinator.outlineView = outline
        context.coordinator.renameController.outlineView = outline
        // pin the appearance to the theme brightness up front so the disclosure triangle reads on launch (a
        // light theme under macOS dark mode would draw an invisible light triangle).
        context.coordinator.applyThemeAppearance()
        // seed tracked expansion from the persisted per-workspace state BEFORE the reload, so
        // rebuildAndReload restores each workspace's saved open/collapsed state (a collapsed workspace stays
        // collapsed across relaunch) instead of force-expanding every row.
        context.coordinator.seedExpansionFromModel()
        context.coordinator.rebuildAndReload()
        context.coordinator.syncSelection()
        // on launch AppKit makes the sidebar the window's initial first responder; hand focus to the
        // terminal once the window + surface are attached (retries internally).
        context.coordinator.focusActiveTerminal()

        let scroll = NSScrollView()
        scroll.identifier = NSUserInterfaceItemIdentifier("agterm-sidebar-scroll")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        // hide the scroller when the tree fits (the common case): otherwise macOS set to "Show scroll bars:
        // Always" paints a permanent track over the short, non-overflowing tree.
        scroll.autohidesScrollers = true
        // transparent so the window's backgroundColor (the terminal color, set by WindowAppearance) shows
        // through the sidebar's translucent material and the whole column — including the strip behind the
        // titlebar — reads as one dark surface.
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.installEmptyState(in: scroll)
        // inset the tree to match the terminal's ghostty padding so they line up in every toolbar mode.
        context.coordinator.applySidebarContentInset(scroll)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // touching the observed store properties HERE registers this representable as an observer, so
        // SwiftUI re-invokes updateNSView on a change to the tree shape, selection, any session's
        // name/displayName, split state, unseen count or agent status — which is what lets reconcile do a
        // targeted per-row reload for a content change; a touch inside viewFor wouldn't register it.
        // agentIndicator feeds the status-icon reconcile (it renders on every session). The
        // badge-visibility toggle (GhosttyApp.notificationBadgeEnabled) is NOT observable, so it drives a
        // re-reconcile via .agtermAppearanceChanged (appearanceChanged), like toolbarMode.
        _ = store.workspaces.map { ($0.id, $0.name, $0.unseenCount, $0.sessions.map { ($0.id, $0.displayName, $0.hasSplit, $0.unseenCount, $0.agentIndicator, $0.flagged) }) }
        _ = store.selectedSessionID
        _ = store.sidebarSelectionIDs
        // sidebarMode flips the whole data source between the tree and the flat flagged list, so reading it
        // makes a mode change re-invoke updateNSView and reconcile rebuild.
        _ = store.sidebarMode
        // the marked set restricts the tree to its members (via visibleWorkspaces) while the filter is on;
        // BOTH fields are read so either a membership change or a filter flip re-invokes updateNSView and
        // reconcile takes the rebuild branch.
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

        /// Root workspace nodes in store order, rebuilt in place from the store on each reload, reusing
        /// cached node instances.
        private var roots: [SidebarNode] = []
        /// Cache of node instances keyed by id, so identity is stable across reloads.
        private var nodeCache: [UUID: SidebarNode] = [:]
        /// Guards `syncSelection` against the selection-change delegate callback it itself triggers, which
        /// would re-enter the store.
        private var applyingSelection = false
        /// Last session id whose row was revealed (expanded owner + scrolled into view). Gates the intrusive
        /// reveal so unrelated observable updates (cwd/title/badge) to the already-selected session don't
        /// re-expand a collapsed workspace or yank the scroll position back.
        private var lastRevealedSelection: UUID?
        /// Last-seen `TreeShape`; a change is structural and forces a full rebuild.
        private var lastShape: [TreeShape] = []
        /// Last-seen sidebar mode. A flip (tree ↔ flagged) swaps which data source the outline renders, so
        /// it forces a full `rebuildAndReload` independent of the shape diff.
        private var lastMode: SidebarMode = .tree
        /// Workspace ids the user has expanded, tracked via the expand/collapse delegate callbacks. The
        /// source of truth for restoring expansion on rebuild, because it survives the flagged-mode reload:
        /// that reload drops the workspace nodes from the data source and NSOutlineView discards its own
        /// expansion state for items it no longer renders, so this set is the only surviving record.
        private var expandedWorkspaceIDs = Set<UUID>()
        /// Set true around PROGRAMMATIC `expandItem`/`collapseItem` (the launch/rebuild re-apply, the
        /// `syncSelection` reveal, the focus force-expand): the didExpand/DidCollapse callbacks still update
        /// the visual `expandedWorkspaceIDs` but SKIP the persist write-back, so a view-only reveal or focus
        /// zoom-in never burns a deliberately-persisted collapse. Only a genuine user toggle (row click /
        /// disclosure triangle), which fires the callback with this false, persists; `expandAll`/
        /// `collapseOthers` set it too and persist once explicitly at the end.
        var suppressExpansionPersist = false
        /// Scheduled single-click workspace expand/collapse, deferred by the double-click interval so a
        /// double-click (rename) can cancel it — else the first click of a rename double-click flips the
        /// workspace open/closed on its way into edit mode. See `handleSingleClick`.
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

        /// Stable pseudo-workspace id for the flat flagged group's `TreeShape`, so within flagged mode only
        /// a change to the flagged session list (not a per-call fresh id) triggers a rebuild.
        private static let flaggedShapeID = UUID()

        /// The `userInfo` key AppKit uses for the item in `outlineViewItemDidExpand`/`DidCollapse`
        /// notifications (documented as the literal string `"NSObject"`).
        private static let outlineItemUserInfoKey = "NSObject"

        /// `userInfo` keys for the `.agtermSetWorkspaceExpanded` per-workspace poke (the
        /// `workspace.collapse`/`workspace.expand` control path): the target workspace `UUID` and the
        /// desired `Bool` expansion state. Read by `setWorkspaceExpandedNotified`, written by
        /// `AppActions.setWorkspaceExpanded(_:expanded:in:)`.
        static let workspaceIDUserInfoKey = "agterm.workspaceID"
        static let expandedUserInfoKey = "agterm.expanded"

        /// Last-seen visible content (label, split icon, badge) per session and workspace id, so a
        /// reconcile reloads only the rows whose content changed. An absent key ≠ any real content.
        private var lastRowContent: [UUID: RowContent] = [:]

        /// The sidebar font size last applied (row height + row fonts). `.agtermAppearanceChanged` fires for
        /// every settings change (theme, colors, toggles) and the font size is not part of the per-row
        /// content diff, so `appearanceChanged` compares against this and rebuilds only on a real change.
        private var lastSidebarFontSize: CGFloat = CGFloat(AppSettings.defaultSidebarFontSize)

        /// Centered hint shown over the empty outline in flagged mode when nothing is flagged. Floats in the
        /// scroll view above the document, hidden otherwise.
        private weak var emptyStateLabel: NSTextField?

        init(store: AppStore, actions: AppActions) {
            self.store = store
            self.actions = actions
            self.renameController = SidebarRenameController(store: store)
            super.init()
            // seed from the live mirror (SettingsModel applied the persisted size at launch, before any
            // window's sidebar is built) so the first appearanceChanged doesn't rebuild for no change.
            lastSidebarFontSize = GhosttyApp.shared.sidebarFontSize
            renameController.onRenameEnded = { [weak self] in self?.focusActiveTerminal() }
            // the menu/palette can't reach the inline editor directly, so they post a notification and this
            // coordinator starts the edit on the selected row. Scoped by `object: store` like
            // expand/collapse below: the handlers' selected-session guard is NOT a per-window scope (every
            // open window has one), so an `object: nil` pairing starts an inline edit in EVERY window — each
            // leaving an unopened editor plus an unbalanced `suppressAutoFollow` that wedges that window's
            // idle auto-follow off for good.
            NotificationCenter.default.addObserver(self, selector: #selector(beginRenameSessionNotified),
                                                   name: .agtermBeginRenameSession, object: store)
            NotificationCenter.default.addObserver(self, selector: #selector(beginRenameWorkspaceNotified),
                                                   name: .agtermBeginRenameWorkspace, object: store)
            // expand/collapse target ONLY the frontmost window's sidebar: AppActions posts them with the
            // frontmost store as the object, and `object: store` makes NotificationCenter deliver only to
            // the Coordinator whose store matches, leaving other windows' sidebars put.
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

        /// Re-tint the visible rows' text/icon for the current selection and redraw the selection pills
        /// without a `reloadData` — needed on a selection change (AppKit doesn't redraw by itself with
        /// `selectionHighlightStyle == .none`) and on a live theme change.
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
        /// macOS dark mode otherwise draws a light-gray triangle invisible on the light sidebar (row
        /// text/icons survive only because they are set explicitly to the theme color).
        func applyThemeAppearance() {
            outlineView?.appearance = NSAppearance(named: GhosttyApp.shared.terminalThemeIsDark ? .darkAqua : .aqua)
        }

        /// Inset the tree to line up with the terminal's DEFAULT ghostty padding
        /// (agterm/Resources/ghostty-defaults.conf; a user window-padding override in ghostty.conf is not
        /// tracked): window-padding-x = 8 matches the left margin, plus a 2px top nudge putting the first
        /// row's text on the terminal's first line — most of the ~window-padding-y = 6 gap already comes from
        /// the row centering its content (`centerYAnchor`) in a ~28px row, so a full 6px would double it.
        /// `.plain` adds no insets of its own, so we own them (auto-adjust off). Same in every toolbar mode.
        func applySidebarContentInset(_ scroll: NSScrollView?) {
            guard let scroll else { return }
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 2, left: 8, bottom: 0, right: 0)
        }

        @objc private func appearanceChanged() {
            applySidebarFontSizeIfChanged()
            refreshSelectionAppearance()
            applyThemeAppearance()
            // a settings change may have flipped the badge-visibility toggle; reconcile so the gated unseen
            // count (0 when off, the real count when on) reloads the affected badge rows.
            reconcile()
            // agent-status colors are global, not per-row, so reconcile's content diff can't see a color
            // change — re-apply every visible glyph so a Settings color edit takes effect live.
            reapplyStatusGlyphs()
            updateEmptyState()
            // cheap re-assert in case a settings change requires recomputing the inset; it is
            // mode-independent, so this is not a per-mode recalculation.
            applySidebarContentInset(outlineView?.enclosingScrollView)
        }

        @objc private func accessibilityDisplayOptionsChanged() {
            reapplyStatusGlyphs()
        }

        /// Re-apply the row height + fonts when the sidebar font-size setting changed. The font size is not
        /// part of `reconcile`'s per-row content diff, so a change needs an explicit row-height update and a
        /// full `rebuildAndReload` (which re-runs the cell builder, re-setting each row's font). Guarded on
        /// the tracked value so an unrelated appearance change (theme/color/toggle) doesn't force a reload.
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

        /// Collapse every workspace except the active one in this window's sidebar. `collapseOthers` gates
        /// on tree mode itself, so flagged mode is a clean no-op.
        @objc private func collapseWorkspacesNotified() {
            collapseOthers()
        }

        /// Sync the sidebar to a SINGLE workspace's collapse/expand (the
        /// `workspace.collapse`/`workspace.expand` control path). `AppActions.setWorkspaceExpanded` has
        /// ALREADY persisted `Workspace.isExpanded` — the source of truth, independent of this Coordinator
        /// being alive — so this handler only keeps the tracked `expandedWorkspaceIDs` in step (letting the
        /// intent survive a collapsed flagged-mode / focused-away row and a transient focus force-reveal)
        /// and drives the live outline row when it is on screen (tree mode, row resolved), suppressing the
        /// callback's re-persist.
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
        /// add/remove/move/reorder, so a content change (name/icon/badge) takes a targeted per-row reload
        /// instead of a full rebuild. Row TEXT is deliberately NOT here: a cwd-driven `displayName` change
        /// must not trigger a `reloadData` + re-expand, which re-lays-out every row and jitters the labels.
        private struct TreeShape: Equatable {
            let workspaceID: UUID
            let sessionIDs: [UUID]
        }

        /// A row's visible content: its label (workspace name or session `displayName`), whether the session
        /// has a split (the split-rectangle icon), the unseen-badge count, and the GATED agent-status
        /// indicator (after the frontmost-selected hide). A delta reloads just that row. Uses `hasSplit`
        /// (not `isSplit`) so the icon persists while a split is hidden.
        private struct RowContent: Equatable {
            let label: String
            let hasSplit: Bool
            let unseen: Int
            let indicator: AgentIndicator
            /// Whether the session is flagged (tree-mode filled-icon variant). A change re-badges just this
            /// row via `reloadItem`. Always false for workspace rows.
            let flagged: Bool
            /// Whether the workspace is a member of the focus set (the black-weight grid icon). MEMBERSHIP
            /// only, independent of `focusEnabled`, so marking re-renders just that row via `reloadItem`
            /// even while the filter is off (with it on, the shape changes too and the rebuild branch takes
            /// over). Always false for session rows.
            let focusMember: Bool
        }

        /// The session's own agent-status indicator (or `.idle` for an unknown id / workspace row). Shown on
        /// every session regardless of selection — `completed --auto-reset` clears itself on `selectSession`,
        /// so a visited session drops its glyph without a render-time gate.
        func effectiveIndicator(forSession id: UUID) -> AgentIndicator {
            store.session(withID: id)?.agentIndicator ?? AgentIndicator()
        }

        /// The unseen count after the badge-visibility gate: 0 when the Settings badge toggle is off, else
        /// the raw count. Render-only — `unseenCount` keeps tracking, so re-enabling instantly shows current
        /// counts. The agent-status glyph is NOT gated by this.
        func effectiveUnseen(_ count: Int) -> Int {
            GhosttyApp.shared.notificationBadgeEnabled ? count : 0
        }

        /// Decides between a full rebuild (a SHAPE change: add/move/close/reorder) and a targeted per-row
        /// reload (a content change: rename, cwd-driven name, split open/close, badge). Content changes
        /// never rebuild — a `reloadData` + re-expand re-lays-out every row and jitters the labels. A reload
        /// during an in-progress rename is skipped so a tick can't drop the edit.
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
        /// ids) in `.tree`, or one flat group of the flagged session ids in `.flagged`. A change means an
        /// add/remove/move/reorder (or a flag/unflag in flagged mode) and forces a full rebuild. The tree
        /// case derives from `visibleWorkspaces` (the marked set with the focus filter on, else all), so
        /// marking a workspace or flipping the filter — both of which change the rendered root set —
        /// registers as a shape change.
        private func currentShape() -> [TreeShape] {
            switch store.sidebarMode {
            case .tree:
                return store.visibleWorkspaces.map { TreeShape(workspaceID: $0.id, sessionIDs: $0.sessions.map(\.id)) }
            case .flagged:
                return [TreeShape(workspaceID: Self.flaggedShapeID, sessionIDs: store.flaggedSessions.map(\.id))]
            }
        }

        /// Reloads only the rows whose visible content (label, split icon, badge) changed — the session row
        /// and, for a badge roll-up, its workspace row. A per-row `reloadItem` re-renders at the row's
        /// stable frame, so a name/cwd update never re-lays-out the tree. Skipped mid-rename so it can't
        /// drop an in-progress edit.
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

        /// Records every row's current visible content (label, split icon, badge), keyed by id, so the next
        /// reconcile can detect a per-row delta.
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
            RowContent(label: workspace.name, hasSplit: false, unseen: effectiveUnseen(workspace.unseenCount),
                       indicator: AgentIndicator(), flagged: false,
                       focusMember: store.focusedWorkspaceIDs.contains(workspace.id))
        }

        /// The visible content of a session row. One builder shared by `reloadChangedContentRows` and
        /// `snapshotRowContent` so the snapshot and the diff can't drift. Both callers iterate the
        /// `workspace … session` tree and pass the owning `workspaceName` in, so the label needs no
        /// `session(withID:)`/`workspace(forSession:)` lookup and the reconcile stays linear.
        private func rowContent(forSession session: Session, workspaceName: String) -> RowContent {
            RowContent(label: rowLabel(for: session, workspaceName: workspaceName), hasSplit: session.hasSplit,
                       unseen: effectiveUnseen(session.unseenCount),
                       indicator: effectiveIndicator(forSession: session.id), flagged: session.flagged,
                       focusMember: false)
        }

        /// Rebuilds `roots` from the store, reusing cached node instances by id so NSOutlineView item
        /// identity and expansion state stay stable, then reloads the outline preserving expansion.
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

            // render only the visible workspaces: the marked set's subtrees when the focus filter is on,
            // else the full tree.
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
            // then pick up any the model reports expanded but that aren't tracked yet — a workspace added
            // at runtime defaults `isExpanded == true`, so this renders it open. A user-collapsed workspace
            // has `isExpanded == false` (excluded) and a programmatic reveal keeps its already-present id
            // (formUnion only adds), so neither is disturbed.
            expandedWorkspaceIDs.formIntersection(Set(store.workspaces.map(\.id)))
            expandedWorkspaceIDs.formUnion(store.workspaces.filter(\.isExpanded).map(\.id))

            // restore expansion from the tracked set, not the live outline state: a flagged-mode reload
            // drops the workspace nodes so the outline forgets they were expanded, while the tracked set
            // remembers across the interlude. A filter applied to a SINGLE marked workspace also
            // force-expands it — a "zoom in", so its sessions must show even from a collapsed row. The force
            // stops at one member on purpose: with a working SET the tree is a list of workspaces, not a
            // zoom, and re-expanding every member on each rebuild (any session add/close/move re-shapes the
            // tree) would repeatedly undo the user's collapse while `tree` still reported it `collapsed` — a
            // visible read-back divergence. The re-apply is a VIEW restore, not a user action, so suppress
            // the persist: a marked-but-collapsed workspace keeps its persisted collapse.
            outline.reloadData()
            suppressExpansionPersist = true
            let forceExpanded = store.soleFocusedWorkspaceID
            for node in roots where expandedWorkspaceIDs.contains(node.id) || forceExpanded == node.id {
                outline.expandItem(node)
            }
            suppressExpansionPersist = false
            updateEmptyState()
        }

        /// Adds the flagged-mode empty-state hint near the top of the scroll view, below the safe-area inset
        /// so it clears the titlebar, as a non-scrolling overlay — a sibling of the clip view, so it floats
        /// above the document and stays put. Hidden until the flagged view is empty.
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

        /// Seeds the tracked expansion set from the persisted `Workspace.isExpanded`, so the launch reload
        /// restores each workspace's saved open/collapsed state. Sets only the tracked set —
        /// `rebuildAndReload` applies it to the outline. Called once from `makeNSView`.
        func seedExpansionFromModel() {
            expandedWorkspaceIDs = Set(store.workspaces.filter(\.isExpanded).map(\.id))
        }

        /// Expands every workspace row — the "Expand Workspaces" user action. Seeds the tracked expansion
        /// from the live `store.workspaces`, NOT the current `roots` (only the marked set's subtrees while
        /// the focus filter is on), so turning the filter off remembers every workspace as expanded.
        /// Per-item callbacks are suppressed; being a deliberate all-workspace command, the whole-tree state
        /// is persisted once via `setWorkspacesExpanded`.
        func expandAll() {
            guard let outline = outlineView else { return }
            for workspace in store.workspaces { expandedWorkspaceIDs.insert(workspace.id) }
            suppressExpansionPersist = true
            for node in roots where node.kind == .workspace { outline.expandItem(node) }
            suppressExpansionPersist = false
            store.setWorkspacesExpanded(expandedWorkspaceIDs)
        }

        /// Collapses every workspace except the active session's (`store.currentWorkspaceID`), keeping that
        /// one expanded and scrolled into view. Tree-mode only — flagged mode has no workspace rows, so it
        /// is a graceful no-op there.
        func collapseOthers() {
            guard let outline = outlineView, store.sidebarMode == .tree else { return }
            let keepID = store.currentWorkspaceID
            // this command targets ALL workspaces, not just the visible `roots`: reduce the tracked set to
            // exactly the active workspace so a focus filter hiding some workspaces can't leave them in the
            // set and have the batch write below persist them expanded. The outline expand/collapse only
            // touches the rows currently on screen.
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
            // a deliberate command, so persist the whole-tree state once — every workspace, only the active
            // one expanded — unlike the per-toggle callback path.
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
            // persist ONLY a genuine user expand (row click / disclosure triangle): a programmatic reveal or
            // rebuild re-apply sets suppressExpansionPersist, updating the visual set above without burning
            // the persisted collapse intent.
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
            // the row-selection sync runs every call (keeps the highlight correct), but the intrusive reveal
            // — expanding a collapsed owner and scrolling into view — only fires on a real selection change,
            // so unrelated cwd/title/badge updates to the already-selected session leave a user-collapsed
            // workspace and a user-moved scroll position alone.
            let selectionChanged = selectedID != lastRevealedSelection
            // a session selected by keyboard nav may live in a collapsed workspace, whose row is -1 until
            // expanded; expand its owner first so the row resolves. A VIEW action, not a user expand, so
            // suppress the persist: navigating into (or launching with the selection inside) a deliberately
            // collapsed workspace shows the session without un-collapsing it on disk.
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

        /// The workspace node whose `children` hold `sessionID`, or nil — used to expand a collapsed owner
        /// before resolving a keyboard-navigated session's row.
        private func ownerWorkspaceNode(ofSession sessionID: UUID) -> SidebarNode? {
            roots.first { $0.children.contains { $0.id == sessionID } }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            // repaint the selection pill + row text colors for the new selection — with the .none highlight
            // style AppKit won't redraw rows itself.
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
            // a genuine user row click (the applyingSelection guard above skips programmatic sync, so
            // auto-follow's own jump never reaches here) counts as activity, buying the full idle grace
            // before auto-follow can pull the selection back.
            store.noteUserActivity()
            let indicator = store.selectSession(activeID, sidebarSelection: selectedIDs)
            // land on the selected session's blocked pane when it carries a pane-tagged block (else a
            // no-op), async so it runs after the selection + the sidebar's own focus-restore settle.
            DispatchQueue.main.async { [weak self] in
                self?.actions.revealActiveBlockedPane(captured: indicator)
            }
        }

        /// Returns keyboard focus to the active session's terminal after a sidebar interaction, so the
        /// sidebar never keeps focus. Mirrors macterm's `FocusRestoration`: the target surface may not be
        /// attached to the window yet (a just-selected session's view is still materializing), so retry on
        /// the run loop until it is, with a bounded cap. Skipped while a rename field is first responder or
        /// an edit is in progress.
        ///
        /// Targets `topmostSurface` (overlay, else scratch, else the active pane), not the main `surface`:
        /// a cover owns the keyboard, so focusing a pane would starve the overlay/scratch program of input —
        /// and a full overlay or scratch hides the pane, sending keystrokes to a surface the user can't see.
        func focusActiveTerminal(attempt: Int = 0) {
            if renameController.isEditing { return }
            let window = outlineView?.window
            if let window, window.firstResponder is NSText { return }
            if let window, let surface = store.activeSession?.topmostSurface as? GhosttySurfaceView, surface.window === window {
                window.makeFirstResponder(surface)
                return
            }
            // not attached yet — at launch, or a just-selected session still materializing.
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

        /// Leading row icons as monochrome template symbols: a 2x2 grid for a workspace, an outlined
        /// terminal for a single session, a split-rectangle for a split one. A flagged SESSION swaps to its
        /// base glyph's `.fill` variant (`terminal.fill` / `rectangle.split.2x1.fill` — the solid-interior
        /// idiom the scratch-active toolbar glyph uses). A workspace in the focus SET keeps the same
        /// `square.grid.2x2` outline at `.black` weight, so a workspace row holds one identity and
        /// membership costs stroke weight alone, keeping the two markers distinct (fill = flagged session,
        /// black = marked workspace) instead of both reading as "filled". Never a composited corner badge,
        /// so each stays a single template `setColors` tints; the weight variant renders 1pt larger (16x15
        /// vs 15x14) but the icon view is pinned to a fixed 16x16 box, so neither swap moves the row.
        /// Cached because few distinct symbols exist and every row reuses them.
        lazy var workspaceIcon = Self.rowIcon("square.grid.2x2")
        lazy var focusedWorkspaceIcon = Self.rowIcon("square.grid.2x2", weight: .black)
        lazy var splitSessionIcon = Self.rowIcon("rectangle.split.2x1")
        lazy var sessionIcon = Self.rowIcon("terminal")
        lazy var flaggedSessionIcon = Self.rowIcon("terminal.fill")
        lazy var flaggedSplitSessionIcon = Self.rowIcon("rectangle.split.2x1.fill")

        private static func rowIcon(_ symbolName: String, weight: NSFont.Weight = .regular) -> NSImage? {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: weight)
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            return image
        }

        /// The row label from an already-resolved session + its owning workspace name, with no store lookup —
        /// the form the reconcile loops use, since they iterate the `workspace … session` tree.
        func rowLabel(for session: Session, workspaceName: String) -> String {
            guard store.sidebarMode == .flagged else { return session.displayName }
            return "\(session.displayName) : \(workspaceName)"
        }

        func workspaceNode(forID id: UUID) -> SidebarNode? {
            roots.first(where: { $0.id == id })
        }
    }
}

/// An `NSOutlineView` subclass serving a per-row context menu and starting inline rename on double-click,
/// both routed to the coordinator.
final class SidebarOutlineView: NSOutlineView {
    // never become first responder: focus lives in the terminal. A mouse click still selects the row
    // (selection is independent of first responder); otherwise the click steals first responder and the
    // responder bounce (terminal → outline → terminal, via mouseDown's focusActiveTerminal) makes AppKit
    // re-set `isEmphasized` on the rows — an extra repaint that flicks the selection pill on every click.
    // Programmatic selection (palette/Ctrl-Tab) never bounces, so it is already smooth.
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
        // after the click is handled (selection, expand/collapse, drag), hand keyboard focus back to the
        // terminal so the sidebar never keeps it. row selection persists (model state); only first responder
        // moves. skipped mid-rename by the coordinator.
        (delegate as? WorkspaceSidebar.Coordinator)?.focusActiveTerminal()
    }
}

extension Notification.Name {
    /// Posted by the menu/palette to start an inline rename of the active session or its workspace;
    /// `WorkspaceSidebar.Coordinator` observes these and begins editing the row.
    static let agtermBeginRenameSession = Notification.Name("agterm.beginRenameSession")
    static let agtermBeginRenameWorkspace = Notification.Name("agterm.beginRenameWorkspace")
    /// Posted by the menu/palette/control channel to expand every workspace, or collapse every workspace
    /// except the active one, with the frontmost window's `AppStore` as the object so
    /// `WorkspaceSidebar.Coordinator` observes them scoped to that one window's sidebar.
    static let agtermExpandWorkspaces = Notification.Name("agterm.expandWorkspaces")
    static let agtermCollapseWorkspaces = Notification.Name("agterm.collapseWorkspaces")
    /// Posted by the `workspace.collapse`/`workspace.expand` control arm for a SINGLE workspace, with the
    /// target window's `AppStore` as the object and the workspace id + desired state in `userInfo`.
    /// Object-scoped like the all-workspace pokes, so only the matching window's sidebar reacts.
    static let agtermSetWorkspaceExpanded = Notification.Name("agterm.setWorkspaceExpanded")
    /// Posted by the `session.resize` control arm after storing a new split-divider fraction, with the
    /// target `Session` as the object so the matching `SplitProbeView` (in `ContentView`) moves the live
    /// divider to `Session.splitRatio`. Object-scoped, so only that one session's pane view reacts.
    static let agtermApplySplitRatio = Notification.Name("agterm.applySplitRatio")
}
