import agtCore
import AppKit
import SwiftUI

/// Custom pasteboard type carrying a dragged session's UUID string. Local-only
/// drags (within the outline) use this to identify the session being moved.
private let sessionPasteboardType = NSPasteboard.PasteboardType("com.umputun.agt.session")

/// An `NSTableCellView` with a leading icon, the name field, and a trailing badge.
/// The icon is the inherited `cell.imageView` (a filled folder for a workspace, an outlined
/// terminal for a session), so AppKit re-tints it white on a selected row. The name field is `cell.textField`
/// (rename and selection wiring operate on it).
private final class SidebarCellView: NSTableCellView {
    /// Trailing unseen-notification count for the row (a session's `unseenCount`, or a collapsed
    /// workspace's roll-up), drawn as a small accent capsule. Hidden when 0.
    let badge = BadgeView()

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
    private var textAttributes: [NSAttributedString.Key: Any] { [.font: Self.font, .foregroundColor: NSColor.white] }
    private var label: String { count > 99 ? "99+" : String(count) }

    override var intrinsicContentSize: NSSize {
        let height: CGFloat = 16
        let width = (label as NSString).size(withAttributes: textAttributes).width
        return NSSize(width: max(width + 9, height), height: height)
    }

    override func draw(_: NSRect) {
        let radius = bounds.height / 2
        // systemRed (the conventional unread/notification color) reads on both the dark rows and the
        // accent-colored selected row — an accent capsule would blend into a selected row.
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let text = label as NSString
        let size = text.size(withAttributes: textAttributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: textAttributes)
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

    func makeCoordinator() -> Coordinator { Coordinator(store: store, actions: actions) }

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
        scroll.identifier = NSUserInterfaceItemIdentifier("agt-sidebar-scroll")
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
        // or any session's unseen count changes. folding unseenCount into the read is what
        // makes a badge-only change re-invoke updateNSView; a touch inside viewFor
        // would not register the dependency.
        _ = store.workspaces.map { ($0.id, $0.name, $0.sessions.map { ($0.id, $0.unseenCount) }) }
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
        /// Guards `syncSelection` against the selection-change delegate callback it
        /// itself triggers (which would otherwise re-enter the store).
        private var applyingSelection = false
        /// Last-seen tree signature (workspace ids/names + per-session ids and display
        /// names), used to tell a structural change from a badge-only update.
        private var lastTreeSignature: [TreeSignature] = []

        /// Last-seen unseen-notification count per session and workspace id, so a reconcile reloads
        /// only the rows whose badge changed. An absent key reads as nil ≠ any real count.
        private var lastSeenUnseen: [UUID: Int] = [:]

        init(store: AppStore, actions: AppActions) {
            self.store = store
            self.actions = actions
            super.init()
            // the menu/palette can't reach the inline editor directly, so they post a
            // notification and this coordinator starts the edit on the selected row.
            NotificationCenter.default.addObserver(self, selector: #selector(beginRenameSessionNotified),
                                                   name: .agtBeginRenameSession, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(beginRenameWorkspaceNotified),
                                                   name: .agtBeginRenameWorkspace, object: nil)
            // a theme change (new terminal foreground) re-tints the visible rows in place.
            NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
                                                   name: .agtAppearanceChanged, object: nil)
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

        @objc private func appearanceChanged() { refreshSelectionAppearance() }

        @objc private func beginRenameSessionNotified() {
            guard let id = store.selectedSessionID, let node = nodeCache[id] else { return }
            // async so the edit starts after any palette overlay closes and the row is on screen.
            DispatchQueue.main.async { [weak self] in self?.beginEditing(node: node) }
        }

        @objc private func beginRenameWorkspaceNotified() {
            guard let id = store.currentWorkspaceID, let node = nodeCache[id] else { return }
            DispatchQueue.main.async { [weak self] in self?.beginEditing(node: node) }
        }

        // MARK: - Model rebuild

        /// A workspace's structural signature: its id, name, and ordered sessions
        /// (id + display name). Equal signatures across an update mean the tree shape
        /// and every visible name are unchanged, so a badge-only delta can be
        /// reloaded per-row instead of via a full rebuild. Including the display name
        /// means a rename or a cwd-driven basename change forces a full rebuild that
        /// refreshes the label, rather than being mistaken for a badge-only update.
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
        /// a targeted per-row reload (badge-only change). A badge update during an
        /// in-progress rename is skipped so a tick can't drop the edit.
        func reconcile() {
            let signature = store.workspaces.map { workspace in
                TreeSignature(id: workspace.id, name: workspace.name,
                              sessions: workspace.sessions.map { SessionSignature(id: $0.id, displayName: $0.displayName) })
            }
            if signature != lastTreeSignature {
                lastTreeSignature = signature
                rebuildAndReload()
                snapshotBadges()
                return
            }
            reloadChangedBadgeRows()
        }

        /// Reloads only the rows whose unseen-notification count changed — both the session row and
        /// its workspace row (the roll-up). Skipped mid-rename so it can't drop an in-progress edit.
        private func reloadChangedBadgeRows() {
            guard let outline = outlineView, !committing, !editing else { return }
            func reloadIfChanged(_ id: UUID, _ count: Int) {
                guard count != lastSeenUnseen[id] else { return }
                lastSeenUnseen[id] = count
                if let node = nodeCache[id] { outline.reloadItem(node) }
            }
            for workspace in store.workspaces {
                reloadIfChanged(workspace.id, workspace.unseenCount)
                for session in workspace.sessions { reloadIfChanged(session.id, session.unseenCount) }
            }
        }

        /// Records the current unseen count of every session and workspace (keyed by their distinct
        /// ids) so the next reconcile can detect a badge-only delta.
        private func snapshotBadges() {
            var snapshot: [UUID: Int] = [:]
            for workspace in store.workspaces {
                snapshot[workspace.id] = workspace.unseenCount
                for session in workspace.sessions { snapshot[session.id] = session.unseenCount }
            }
            lastSeenUnseen = snapshot
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
            // a recycled cell may carry the prior row's badge; reset before use
            applyBadge(toCell: cell, count: 0)
            switch node.kind {
            case .workspace:
                let workspace = store.workspaces.first(where: { $0.id == node.id })
                field.stringValue = workspace?.name ?? ""
                field.font = .preferredFont(forTextStyle: .headline)
                field.setAccessibilityIdentifier("workspace-row")
                // expose the workspace name so app.staticTexts["workspace 1"] resolves
                field.setAccessibilityLabel(workspace?.name ?? "")
                // roll-up badge so an unseen notification stays visible when the workspace is collapsed
                applyBadge(toCell: cell, count: workspace?.unseenCount ?? 0)
                cell.imageView?.image = workspaceIcon
                cell.imageView?.setAccessibilityIdentifier("workspace-icon")
            case .session:
                field.stringValue = displayName(forSession: node.id)
                field.font = .preferredFont(forTextStyle: .body)
                field.setAccessibilityIdentifier("session-row")
                field.setAccessibilityLabel(nil)
                applyBadge(toCell: cell, count: store.session(withID: node.id)?.unseenCount ?? 0)
                cell.imageView?.image = sessionIcon
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

        /// Leading row icons: a filled folder for a workspace, an outlined terminal for a session,
        /// rendered as monochrome template symbols tinted to `secondaryLabelColor`. The
        /// filled-vs-outline contrast keeps the two readily distinguishable at row size. Cached
        /// because only two distinct symbols exist and every row reuses them.
        private lazy var workspaceIcon = Self.rowIcon("folder.fill")
        private lazy var sessionIcon = Self.rowIcon("terminal")

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
                // chain: name (flex) | badge (trailing). the badge hugs its content, so the name
                // truncates first and the badge stays whole.
                field.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -6),
                badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func displayName(forSession id: UUID) -> String {
            store.session(withID: id)?.displayName ?? ""
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
            // manage enabled state explicitly (the Delete item is disabled at the last workspace)
            // rather than via the responder-chain auto-enabling.
            menu.autoenablesItems = false

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

        @objc private func menuNewSession(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarNode else { return }
            addSession(toWorkspace: node.id, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
        }

        @objc private func menuDeleteWorkspace(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarNode else { return }
            actions.deleteWorkspace(node.id)
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

extension Notification.Name {
    /// Posted by the menu/palette to start an inline rename of the active session or its
    /// workspace; `WorkspaceSidebar.Coordinator` observes these and begins editing the row.
    static let agtBeginRenameSession = Notification.Name("agt.beginRenameSession")
    static let agtBeginRenameWorkspace = Notification.Name("agt.beginRenameWorkspace")
}
