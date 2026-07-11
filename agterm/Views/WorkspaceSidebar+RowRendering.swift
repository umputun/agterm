import agtermCore
import AppKit

/// `WorkspaceSidebar.Coordinator` row rendering — the `NSOutlineViewDelegate` cell/row builders and
/// their helpers (cell construction, badge/icon application, row labels). Split out of
/// `WorkspaceSidebar.swift` to keep that file under the swiftlint size limit. The lazy icon caches and
/// `rowIcon`/`rowLabel(for:workspaceName:)` stay in the main file (lazy stored properties can't live in
/// an extension, and those two are shared with the reconcile path).
extension WorkspaceSidebar.Coordinator {
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
        field.delegate = renameController
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
            field.font = .systemFont(ofSize: GhosttyApp.shared.sidebarFontSize, weight: .medium)
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
            field.font = .systemFont(ofSize: GhosttyApp.shared.sidebarFontSize)
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
        // this build-time tint is a first guess — row(forItem:) can miss (-1) while the row map is in
        // flux during a reload or expand/collapse animation. SidebarRowView.didAddSubview re-asserts
        // the tint from the row's live isSelected when the cell attaches, and its isSelected didSet
        // keeps it in step afterwards; refreshSelectionAppearance re-runs it on theme changes.
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
}
