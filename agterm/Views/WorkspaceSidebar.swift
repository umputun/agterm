import agtermCore
import AppKit
import SwiftUI

/// Custom pasteboard type carrying a dragged session's UUID string. Local-only
/// drags (within the outline) use this to identify the session being moved.
private let sessionPasteboardType = NSPasteboard.PasteboardType("com.umputun.agterm.session")

/// Custom pasteboard type carrying a dragged workspace's UUID string. Local-only
/// drags (within the outline) use this to identify the workspace being reordered.
private let workspacePasteboardType = NSPasteboard.PasteboardType("com.umputun.agterm.workspace")

/// An `NSTableCellView` with a leading icon, the name field, and a trailing badge.
/// The icon is the inherited `cell.imageView` (a 2x2 grid glyph for a workspace, an outlined
/// terminal for a session), so AppKit re-tints it white on a selected row. The name field is `cell.textField`
/// (rename and selection wiring operate on it).
private final class SidebarCellView: NSTableCellView {
    /// Trailing unseen-notification count for the row (a session's `unseenCount`, or a collapsed
    /// workspace's roll-up), drawn as a small accent capsule. Hidden when 0.
    let badge = BadgeView()

    /// Agent-status glyph drawn just left of the count badge, fed from the session's `agentIndicator`.
    /// Hidden on `.idle` (workspace rows always idle for now).
    let statusIcon = StatusIconView()

    /// Color the row text/icon from the terminal theme: a selected row pairs with the selection
    /// foreground (over the selection-background pill the row draws), or white over the soft wash when
    /// the theme exposes no selection color; an unselected row uses the theme foreground, icons dimmed.
    /// Driven by the coordinator from the real selection state (not `backgroundStyle`, which AppKit only
    /// flips while the table is first responder).
    func setColors(selected: Bool) {
        let app = GhosttyApp.shared
        let color = selected
            ? (app.terminalSelectionForegroundColor ?? .white)
            : (app.terminalForegroundColor ?? .labelColor)
        textField?.textColor = color
        imageView?.contentTintColor = color.withAlphaComponent(selected ? 0.85 : 0.6)
    }
}

/// A small filled accent capsule showing an unseen-notification count, custom-drawn (not an
/// `NSTextField`) so the capsule and text center cleanly at row size. A single digit reads as a
/// circle (min width = height). Exposed to accessibility as a `notify-badge` static text.
private final class BadgeView: NSView {
    /// The count to show, capped at `99+`. Drives `intrinsicContentSize` and redraw.
    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            setAccessibilityValue(label)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("notify-badge")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)
    // empty space reserved at the badge's LEADING edge, present only when the badge is shown, so the
    // capsule keeps air from the status glyph to its left — while a count-0 badge collapses fully and
    // lets that glyph sit flush at the trailing margin.
    private static let leadingGap: CGFloat = 4
    private var textAttributes: [NSAttributedString.Key: Any] { [.font: Self.font, .foregroundColor: NSColor.white] }
    private var label: String { count > 99 ? "99+" : String(count) }

    override var intrinsicContentSize: NSSize {
        let height: CGFloat = 16
        // collapse to zero width when there's nothing to show: `isHidden` alone does NOT collapse a
        // view in Auto Layout, so a count-0 badge would otherwise reserve a trailing slot and push the
        // status glyph in from the right edge. zero width lets the name reclaim it and the glyph sit flush.
        guard count > 0 else { return NSSize(width: 0, height: height) }
        let capsule = max((label as NSString).size(withAttributes: textAttributes).width + 9, height)
        return NSSize(width: capsule + Self.leadingGap, height: height)
    }

    override func draw(_: NSRect) {
        // the capsule occupies bounds minus the reserved leading gap; the status glyph to its left keeps air
        let capsule = NSRect(x: Self.leadingGap, y: 0, width: bounds.width - Self.leadingGap, height: bounds.height)
        let radius = capsule.height / 2
        // systemRed (the conventional unread/notification color) reads on both the dark rows and the
        // accent-colored selected row — an accent capsule would blend into a selected row.
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: radius, yRadius: radius).fill()
        let text = label as NSString
        let size = text.size(withAttributes: textAttributes)
        let origin = NSPoint(x: capsule.minX + (capsule.width - size.width) / 2, y: (capsule.height - size.height) / 2)
        text.draw(at: origin, withAttributes: textAttributes)
    }
}

/// A small SF-Symbol agent-status glyph drawn just left of the count badge: `active` is a blue
/// ellipsis, `blocked` an amber exclamation, `completed` a green check (all `.circle.fill` for a
/// consistent silhouette). Hidden on `.idle`. Exposed to accessibility as an `agent-status` static
/// text whose value is the state name (so XCUITest matches `app.staticTexts["agent-status"]`). Blink
/// is a layer `opacity` `CABasicAnimation` (autoreverse/repeat), added only while visible AND blinking.
private final class StatusIconView: NSImageView {
    private static let blinkKey = "agent-status-blink"
    private static let glyphWidth: CGFloat = 16

    /// The view's width, collapsed to 0 on `.idle` so a status-less row reclaims the slot (and its
    /// label truncates full-width); `glyphWidth` when a glyph shows. Activated in init, toggled in `apply`.
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("agent-status")
        widthConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    /// apply renders the indicator's tinted glyph (hiding the view and stopping any blink on `.idle`),
    /// updates the accessibility value to the state name, and starts/stops the blink animation.
    func apply(_ indicator: AgentIndicator) {
        guard indicator.status != .idle else {
            isHidden = true
            image = nil
            widthConstraint.constant = 0 // collapse the slot so the name reads full-width
            setAccessibilityValue(AgentStatus.idle.rawValue)
            stopBlink()
            return
        }
        isHidden = false
        image = Self.icon(for: indicator.status)
        widthConstraint.constant = Self.glyphWidth
        setAccessibilityValue(indicator.status.rawValue)
        if indicator.blink { startBlink() } else { stopBlink() }
    }

    private func startBlink() {
        guard layer?.animation(forKey: Self.blinkKey) == nil else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.2
        blink.duration = 0.5
        blink.autoreverses = true
        blink.repeatCount = .greatestFiniteMagnitude
        layer?.add(blink, forKey: Self.blinkKey)
    }

    private func stopBlink() {
        layer?.removeAnimation(forKey: Self.blinkKey)
    }

    private static func icon(for status: AgentStatus) -> NSImage? {
        guard status != .idle else { return nil } // unreachable: `apply` returns early on `.idle` before drawing
        // symbol + color come from the shared mapping (AgentStatus.symbolName + GhosttyApp.statusColor)
        // so this glyph and the SwiftUI StatusGlyph stay identical.
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [GhosttyApp.shared.statusColor(for: status)]))
        return NSImage(systemSymbolName: status.symbolName, accessibilityDescription: status.rawValue)?
            .withSymbolConfiguration(config)
    }
}

/// Row view that draws its own selection pill in `drawBackground`, so the selection is the terminal's
/// `selection-background` color in every state. The table's `selectionHighlightStyle` is `.none` (set
/// in `makeNSView`), so AppKit draws nothing of its own — otherwise it paints a gray unemphasized fill
/// whenever the sidebar isn't first responder (the normal case, since focus lives in the terminal),
/// which would override a custom `drawSelection`. `isEmphasized` is overridden so the row redraws when
/// the window's key state changes (the brightness dims for a background window).
private final class SidebarRowView: NSTableRowView {
    /// White-wash fallback opacity (themes with no selection color): brighter for the key window,
    /// dimmer for a background one.
    private static let keyAlpha: CGFloat = 0.13
    private static let inactiveAlpha: CGFloat = 0.07

    override var isEmphasized: Bool {
        get { window?.isKeyWindow ?? false }
        // isEmphasized is derived from the window's key state; the setter only triggers a redraw.
        // swiftlint:disable:next unused_setter_value
        set { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isSelected else { return }
        if let selection = GhosttyApp.shared.terminalSelectionBackgroundColor {
            // the terminal's own selection color; dim it for a background (non-key) window.
            selection.withAlphaComponent(isEmphasized ? 1 : 0.55).setFill()
        } else {
            // no theme selection color: a soft white wash, brighter for the key window.
            NSColor(white: 1, alpha: isEmphasized ? Self.keyAlpha : Self.inactiveAlpha).setFill()
        }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1.5), xRadius: 7, yRadius: 7).fill()
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
        context.coordinator.rebuildAndReload()
        context.coordinator.expandAll()
        context.coordinator.syncSelection()
        // on launch AppKit makes the sidebar the window's initial first responder; hand
        // focus to the terminal once the window + surface are attached (retries internally).
        context.coordinator.focusActiveTerminal()

        let scroll = NSScrollView()
        scroll.identifier = NSUserInterfaceItemIdentifier("agterm-sidebar-scroll")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
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
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        private let store: AppStore
        private let actions: AppActions
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
        /// `beginEditing` and `restore`), so a badge tick can't reload the row out
        /// from under the in-progress edit. `committing` covers only the end-editing
        /// instant; this covers the whole typing window.
        private var editing = false
        /// Set by the Esc handler (`doCommandBy` cancelOperation) so the end-editing that the
        /// manual resign triggers is treated as a cancel — the typed value is discarded.
        private var cancellingRename = false
        /// The row's pre-edit label, captured in `beginEditing` so an Esc-cancel can restore the
        /// displayed text (a manual resign keeps the edited stringValue, and a cancel makes no model
        /// change so no reload refreshes the row).
        private var renameOriginalValue: String?
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
            super.init()
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
            DispatchQueue.main.async { [weak self] in self?.beginEditing(node: node) }
        }

        @objc private func beginRenameWorkspaceNotified() {
            guard let id = store.currentWorkspaceID, let node = nodeCache[id] else { return }
            DispatchQueue.main.async { [weak self] in self?.beginEditing(node: node) }
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
        private func effectiveIndicator(forSession id: UUID) -> AgentIndicator {
            store.session(withID: id)?.agentIndicator ?? AgentIndicator()
        }

        /// The unseen-count after the badge-visibility gate: 0 (hidden) when the Settings badge toggle
        /// is off, else the raw count. Render-only — `unseenCount` keeps tracking, so re-enabling the
        /// toggle instantly shows the current counts. The agent-status glyph is NOT gated by this.
        private func effectiveUnseen(_ count: Int) -> Int {
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
            guard let outline = outlineView, !committing, !editing else { return }
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

            // prune expansion tracking for workspaces that no longer exist, so a removed-then-re-added id
            // can't carry stale expansion.
            expandedWorkspaceIDs.formIntersection(Set(store.workspaces.map(\.id)))

            // restore expansion from the tracked set rather than the live outline state: a flagged-mode
            // reload drops the workspace nodes, so the outline forgets they were expanded, but the tracked
            // set remembers across the interlude. A freshly-focused workspace is expanded unconditionally —
            // focus is a "zoom in", so its sessions must show even if the workspace was collapsed.
            outline.reloadData()
            for node in roots where expandedWorkspaceIDs.contains(node.id) || node.id == store.focusedWorkspaceID {
                outline.expandItem(node)
            }
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

        /// Expands every workspace row (new workspaces start open). Seeds the tracked expansion from the
        /// live workspaces — NOT the current `roots`, which are session nodes when launched in flagged mode
        /// or a single subtree when launched focused — so a later switch back to the full tree remembers
        /// every workspace as expanded instead of collapsing them all.
        func expandAll() {
            guard let outline = outlineView else { return }
            for workspace in store.workspaces { expandedWorkspaceIDs.insert(workspace.id) }
            for node in roots where node.kind == .workspace { outline.expandItem(node) }
        }

        /// Collapses every workspace except the active one (the workspace of the active session,
        /// `store.currentWorkspaceID`), keeping that one expanded and scrolling its row into view so it
        /// stays visible. Updates the tracked expansion set to match (the expand/collapse delegate
        /// callbacks also fire, but the explicit update keeps the set correct even if a state is unchanged).
        /// Tree-mode only — no workspace rows exist in flagged mode, so it is a graceful no-op there.
        func collapseOthers() {
            guard let outline = outlineView, store.sidebarMode == .tree else { return }
            let keepID = store.currentWorkspaceID
            for node in roots where node.kind == .workspace {
                if node.id == keepID {
                    if !outline.isItemExpanded(node) { outline.expandItem(node) }
                    expandedWorkspaceIDs.insert(node.id)
                } else {
                    if outline.isItemExpanded(node) { outline.collapseItem(node) }
                    expandedWorkspaceIDs.remove(node.id)
                }
            }
            // keep the active workspace's row on screen (mirrors syncSelection's scroll-into-view).
            guard let keepID, let node = nodeCache[keepID] else { return }
            let row = outline.row(forItem: node)
            if row >= 0 { outline.scrollRowToVisible(row) }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?[Self.outlineItemUserInfoKey] as? SidebarNode,
                  node.kind == .workspace else { return }
            expandedWorkspaceIDs.insert(node.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?[Self.outlineItemUserInfoKey] as? SidebarNode,
                  node.kind == .workspace else { return }
            expandedWorkspaceIDs.remove(node.id)
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
            // until expanded; expand its owner first so the row resolves.
            if selectionChanged, let owner = ownerWorkspaceNode(ofSession: selectedID), !outline.isItemExpanded(owner) {
                outline.expandItem(owner)
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
            // a recycled cell may carry the prior row's badge/status; reset before use
            applyBadge(toCell: cell, count: 0)
            cell.statusIcon.apply(AgentIndicator())
            switch node.kind {
            case .workspace:
                let workspace = store.workspaces.first(where: { $0.id == node.id })
                field.stringValue = workspace?.name ?? ""
                field.font = .preferredFont(forTextStyle: .headline)
                field.setAccessibilityIdentifier("workspace-row")
                // expose the workspace name so app.staticTexts["workspace 1"] resolves
                field.setAccessibilityLabel(workspace?.name ?? "")
                // roll-up badge so an unseen notification stays visible when the workspace is collapsed
                // (gated by the Settings badge toggle, like the session badge below)
                applyBadge(toCell: cell, count: effectiveUnseen(workspace?.unseenCount ?? 0))
                cell.imageView?.image = workspaceIcon
                cell.imageView?.setAccessibilityIdentifier("workspace-icon")
            case .session:
                field.stringValue = rowLabel(forSession: node.id)
                field.font = .preferredFont(forTextStyle: .body)
                field.setAccessibilityIdentifier("session-row")
                field.setAccessibilityLabel(nil)
                let session = store.session(withID: node.id)
                applyBadge(toCell: cell, count: effectiveUnseen(session?.unseenCount ?? 0))
                // gate the agent-status glyph: hidden for the frontmost window's selected session.
                cell.statusIcon.apply(effectiveIndicator(forSession: node.id))
                // a session with a split shows the split-rectangle icon (matching the toolbar split
                // button) in BOTH modes so it stays distinguishable at a glance; `hasSplit` keeps it while
                // merely hidden. only the filled `flagged` variant is tree-mode only — in the flat flagged
                // view every row is flagged, so the fill marker would be noise.
                let showSplitIcon = session?.hasSplit == true
                let flagged = store.sidebarMode == .tree && session?.flagged == true
                cell.imageView?.image = iconForSession(split: showSplitIcon, flagged: flagged)
                cell.imageView?.setAccessibilityIdentifier("session-icon")
            }
            // text/icon colors track the terminal theme; a selected row uses the selection foreground.
            // refreshSelectionAppearance re-runs this for all rows on selection and theme changes.
            let selected = outlineView.selectedRowIndexes.contains(outlineView.row(forItem: item))
            cell.setColors(selected: selected)
            return cell
        }

        /// Shows the unseen-notification `count` capsule on the row (hidden, zero-width when 0, so the
        /// name reclaims the space). The `notify-badge` accessibility hook lives on `BadgeView`.
        private func applyBadge(toCell cell: SidebarCellView, count: Int) {
            cell.badge.isHidden = count == 0
            cell.badge.count = count
        }

        /// Leading row icons: a 2x2 grid glyph for a workspace, an outlined terminal for a single
        /// session, and a split-rectangle for a split session, rendered as monochrome template symbols.
        /// The two `flagged*` variants swap to the `.fill` SF Symbol (a solid interior — the same
        /// "small filled area" idiom the scratch-active toolbar glyph uses): `terminal.fill` for a
        /// single session, `rectangle.split.2x1.fill` for a split. A pure symbol swap, not a composited
        /// corner badge, so it stays a single template `setColors` tints and reserves no extra space.
        /// Cached because only a few distinct symbols exist and every row reuses them.
        private lazy var workspaceIcon = Self.rowIcon("square.grid.2x2")
        private lazy var splitSessionIcon = Self.rowIcon("rectangle.split.2x1")
        private lazy var sessionIcon = Self.rowIcon("terminal")
        private lazy var flaggedSessionIcon = Self.rowIcon("terminal.fill")
        private lazy var flaggedSplitSessionIcon = Self.rowIcon("rectangle.split.2x1.fill")

        /// The leading icon for a session row: the split-rectangle when split, the plain terminal
        /// otherwise, each swapped to its filled variant when `flagged`. The filled variant is
        /// tree-mode only (the caller passes `flagged: false` in the flat flagged view).
        private func iconForSession(split: Bool, flagged: Bool) -> NSImage? {
            switch (split, flagged) {
            case (true, true): return flaggedSplitSessionIcon
            case (true, false): return splitSessionIcon
            case (false, true): return flaggedSessionIcon
            case (false, false): return sessionIcon
            }
        }

        private static func rowIcon(_ symbolName: String) -> NSImage? {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            return image
        }

        /// Builds a view-based outline cell: an `SidebarCellView` with a leading icon
        /// (`cell.imageView`), the name `NSTextField` (`cell.textField`, editable on demand by
        /// `beginEditing`), and a trailing notification badge. The name hugs and resists compression
        /// weakly while the icon and badge hug and resist strongly, so the name truncates first and
        /// the icon and badge stay whole.
        private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> SidebarCellView {
            let cell = SidebarCellView()
            cell.identifier = identifier

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.contentTintColor = .secondaryLabelColor
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            cell.addSubview(icon)
            cell.imageView = icon

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

            let statusIcon = cell.statusIcon
            statusIcon.translatesAutoresizingMaskIntoConstraints = false
            statusIcon.setContentHuggingPriority(.required, for: .horizontal)
            statusIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
            cell.addSubview(statusIcon)

            let badge = cell.badge
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            cell.addSubview(badge)

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                // chain: name (flex) | status icon | badge (trailing). the status icon and badge hug
                // their content, so the name truncates first and both stay whole.
                field.trailingAnchor.constraint(equalTo: statusIcon.leadingAnchor, constant: -6),
                statusIcon.trailingAnchor.constraint(equalTo: badge.leadingAnchor),
                statusIcon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                // width is owned by StatusIconView (0 when idle, glyph-width otherwise) so an idle row
                // reclaims the slot; only the height is pinned here.
                statusIcon.heightAnchor.constraint(equalToConstant: 16),
                badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        /// The row's label: the session `displayName` in tree mode, or `session : workspace` (the session
        /// name then its owning workspace name) in the flat flagged view, so a flagged row from a different
        /// workspace stays distinguishable. The cell path (`cellForRow`) only has the node id, so it resolves
        /// the session by id (and the workspace only in flagged mode, where the name is shown — tree mode
        /// skips that O(n) scan); the reconcile path passes the already-loaded session + name (see
        /// `rowLabel(for:workspaceName:)`) to stay off the O(n) lookups.
        private func rowLabel(forSession id: UUID) -> String {
            guard let session = store.session(withID: id) else { return "" }
            let workspaceName = store.sidebarMode == .flagged ? store.workspace(forSession: id)?.name ?? "" : ""
            return rowLabel(for: session, workspaceName: workspaceName)
        }

        /// The row label from an already-resolved session + its owning workspace name, with no store lookup —
        /// the form the reconcile loops use (they iterate the `workspace … session` tree).
        private func rowLabel(for session: Session, workspaceName: String) -> String {
            guard store.sidebarMode == .flagged else { return session.displayName }
            return "\(session.displayName) : \(workspaceName)"
        }

        // MARK: - Inline rename

        /// Puts the row's text field into editing mode and focuses it. Called from
        /// the "Rename" menu item and from double-click.
        private func beginEditing(node: SidebarNode) {
            guard let outline = outlineView else { return }
            let row = outline.row(forItem: node)
            guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            renameOriginalValue = field.stringValue
            field.isEditable = true
            field.isBordered = true
            field.drawsBackground = true
            // the editable field draws its own background, and the label color was set to the row's
            // (often dark) selection-foreground — leaving those makes the edit text unreadable (dark-on-
            // dark) on every theme. paint the field with the terminal theme's foreground-on-background so
            // it reads everywhere; setColors restores the row's color when it reloads after the commit.
            let theme = GhosttyApp.shared
            field.textColor = theme.terminalForegroundColor ?? .labelColor
            field.backgroundColor = theme.terminalBackgroundColor ?? .textBackgroundColor
            field.setAccessibilityIdentifier("edit-field")
            field.window?.makeFirstResponder(field)
            editing = true
        }

        /// Intercepts Esc during an inline rename. The field is focused via `makeFirstResponder`
        /// (not the outline's edit session), so AppKit never delivers the cancel text-movement for
        /// Esc — `cancelOperation:` would otherwise do nothing and leave the field stuck in edit
        /// mode. Flag the cancel, resign so `controlTextDidEndEditing` fires, and consume the
        /// command so the default (no-op) handling doesn't run.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard editing, commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  let field = control as? NSTextField else { return false }
            cancellingRename = true
            field.window?.makeFirstResponder(outlineView)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !committing, let field = notification.object as? NSTextField, let outline = outlineView else { return }
            committing = true
            defer { committing = false }

            // resolve which node this field belongs to via the row of its cell view
            let row = outline.row(for: field)
            let node = row >= 0 ? outline.item(atRow: row) as? SidebarNode : nil

            // Escape cancels: via AppKit's cancel text-movement, or via our Esc handler's flag (the
            // manual-resign path the rename field needs, since it never gets the cancel movement).
            let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
            let cancelled = movement == NSTextMovement.cancel.rawValue || cancellingRename
            cancellingRename = false

            let newValue = field.stringValue
            // a manual-resign cancel keeps the edited stringValue and makes no model change (no row
            // reload), so restore the pre-edit label before flipping the field back to a plain label.
            if cancelled, let original = renameOriginalValue { field.stringValue = original }
            restore(field: field, kind: node?.kind)
            // a rename ends with focus on the field editor; hand it back to the active terminal so the
            // sidebar never keeps keyboard focus (the design contract). deferred so the editor's resign
            // settles first — focusActiveTerminal bails while an NSText field editor is first responder.
            DispatchQueue.main.async { [weak self] in self?.focusActiveTerminal() }
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
            // beginEditing painted the field with the theme fg-on-bg for the edit box; restore the row's
            // selection-aware themed color so a commit that didn't change the name (no reload) doesn't
            // leave the edit color stuck on the row.
            if let outline = outlineView, let cell = field.superview as? SidebarCellView {
                let row = outline.row(for: field)
                cell.setColors(selected: row >= 0 && outline.selectedRowIndexes.contains(row))
            }
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
            addSession(toWorkspace: node.id, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
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

        // MARK: - Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            // the flat flagged view is a derived projection, not a reorderable tree — no drag source there.
            guard store.sidebarMode == .tree, let node = item as? SidebarNode else { return nil }
            let pbItem = NSPasteboardItem()
            switch node.kind {
            case .session:
                pbItem.setString(node.id.uuidString, forType: sessionPasteboardType)
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
                guard let move = resolveWorkspaceMove(from: info, in: outlineView) else { return [] }
                // workspace reorder lives at the top level: highlight a between-rows slot under the root.
                outlineView.setDropItem(nil, dropChildIndex: move.dropChildIndex)
                return .move
            }
            guard let move = resolveSessionMove(from: info, item: item, childIndex: index) else { return [] }
            // redraw the drop highlight on the target workspace row at the resolved insert slot.
            outlineView.setDropItem(workspaceNode(forID: move.workspace), dropChildIndex: move.dropChildIndex)
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView,
                         acceptDrop info: NSDraggingInfo,
                         item: Any?,
                         childIndex index: Int) -> Bool {
            if draggedWorkspaceID(from: info) != nil {
                guard let move = resolveWorkspaceMove(from: info, in: outlineView) else { return false }
                store.moveWorkspace(move.workspaceID, at: move.destination)
                return true
            }
            guard let move = resolveSessionMove(from: info, item: item, childIndex: index) else { return false }
            store.moveSession(move.sessionID, toWorkspace: move.workspace, at: move.destination)
            return true
        }

        /// The resolved session drop. `dropChildIndex` is the PRE-removal slot to highlight; `destination`
        /// is the POST-removal index `moveSession` expects.
        private struct SessionMove {
            let sessionID: UUID
            let workspace: UUID
            let dropChildIndex: Int
            let destination: Int
        }

        /// Resolves a proposed session drop into the move it would perform, or nil when the drop is
        /// invalid or a no-op (so both `validateDrop` and `acceptDrop` agree exactly). Reads the pasteboard
        /// + store to map the dragged session and drop-target row to indices, then defers the index
        /// arithmetic (drop-on-row redirect, post-removal off-by-one, no-op detection) to the host-free
        /// `SidebarDrop.resolveSession`.
        private func resolveSessionMove(from info: NSDraggingInfo, item: Any?, childIndex index: Int) -> SessionMove? {
            guard let sessionID = draggedSessionID(from: info), let node = item as? SidebarNode,
                  let source = store.sessionLocation(ofSession: sessionID) else { return nil }

            let target: SidebarDrop.SessionDropTarget
            switch node.kind {
            case .workspace:
                let count = store.workspaces.first(where: { $0.id == node.id })?.sessions.count ?? 0
                target = .workspaceRow(id: node.id, sessionCount: count)
            case .session:
                guard let drop = store.sessionLocation(ofSession: node.id) else { return nil }
                target = .sessionRow(workspace: drop.workspace, sessionIndex: drop.index, sessionCount: drop.count)
            }

            guard let move = SidebarDrop.resolveSession(sourceWorkspace: source.workspace, sourceIndex: source.index,
                                                        target: target, childIndex: index) else { return nil }
            return SessionMove(sessionID: sessionID, workspace: move.workspace,
                               dropChildIndex: move.dropChildIndex, destination: move.destination)
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

        /// Reads the dragged session id from the pasteboard.
        private func draggedSessionID(from info: NSDraggingInfo) -> UUID? {
            guard let string = info.draggingPasteboard.string(forType: sessionPasteboardType) else { return nil }
            return UUID(uuidString: string)
        }

        private func workspaceNode(forID id: UUID) -> SidebarNode? {
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
