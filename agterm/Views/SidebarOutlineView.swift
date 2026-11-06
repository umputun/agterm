import AppKit

/// `NSOutlineView` subclass routing the per-row context menu and double-click rename to the coordinator.
final class SidebarOutlineView: NSOutlineView {
    // never become first responder: focus lives in the terminal, and a mouse click still selects the row
    // (selection is independent of first responder). Otherwise the responder bounce (terminal → outline →
    // terminal, via mouseDown's focusActiveTerminal) makes AppKit re-set `isEmphasized` on the rows — an
    // extra repaint that flicks the selection pill on every click. Programmatic selection never bounces.
    override var acceptsFirstResponder: Bool { false }

    // expansion would widen the column per nesting level and push every row's trailing glyph and badge past the
    // sidebar edge; the column's autoresizing mask already fits it to the sidebar.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesOutlineColumn = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Where a row's content belongs: the level-0 disclosure triangle ends at 14pt, and the cell's own 2pt
    /// icon inset supplies the gap after it.
    private static let contentX: CGFloat = 14

    /// reservesDisclosureColumn is false when no level-0 row draws a triangle: workspace chevrons hidden, or a
    /// flat flagged list.
    var reservesDisclosureColumn = true

    /// macOS 27 reserves a wider leading strip than the triangle occupies — a level-0 cell starts at 26
    /// against a triangle ending at 14 — leaving the row icon stranded mid-gap. Trim the surplus, computed
    /// from the frame rather than fixed so a release that lays out at `contentX` keeps its own geometry,
    /// and gated on the version because the earlier layout is already tight and cannot be tested here.
    /// Without the reserved strip the trim runs on every version, toward `contentMinX`.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        guard !frame.isEmpty, tableColumns.indices.contains(column), tableColumns[column] === outlineTableColumn,
              let target = contentMinX(atRow: row) else { return frame }
        let trim = max(0, frame.minX - target)
        frame.origin.x -= trim
        frame.size.width += trim
        return frame
    }

    /// frameOfOutlineCell hides level-0 triangles with an empty frame. `shouldShowOutlineCellForItem`
    /// would hide them too, but AppKit then refuses to collapse the item.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard !reservesDisclosureColumn, !frame.isEmpty, let target = contentMinX(atRow: row) else { return frame }
        guard level(forRow: row) > 0 else { return .zero }
        frame.origin.x = target - frame.width
        return frame
    }

    /// contentMinX returns nil to keep the native frame. Without the strip the shift stops short of a nested
    /// triangle's width, so a companion parent's still fits at compact's 10pt indent.
    private func contentMinX(atRow row: Int) -> CGFloat? {
        let level = level(forRow: row)
        guard level >= 0 else { return nil }
        let indent = CGFloat(level) * indentationPerLevel
        guard reservesDisclosureColumn else { return max(0, Self.contentX - indentationPerLevel) + indent }
        guard #available(macOS 27.0, *) else { return nil }
        return Self.contentX + indent
    }

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
        // NSTableView treats Control-click as a plain click and ignores a left-button event handed to
        // rightMouseDown, so the secondary-click convention has to open the menu here.
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        } else {
            super.mouseDown(with: event)
        }
        // after the click is handled, hand keyboard focus back to the terminal; row selection persists
        // (model state), only first responder moves. Skipped mid-rename by the coordinator.
        (delegate as? WorkspaceSidebar.Coordinator)?.focusActiveTerminal()
    }
}
