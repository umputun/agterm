import agtermCore
import AppKit

/// Owns the sidebar's inline-rename interaction: the `NSTextFieldDelegate` for the outline's editable name
/// fields, plus the rename reentrancy flags. `WorkspaceSidebar.Coordinator` creates one, points it at the
/// outline, starts an edit via `beginEditing(node:)`, defers its own updates while `isRenameInFlight`, and
/// supplies `onRenameEnded`/`onMouseTrackingEnded` to apply them and return keyboard focus to the terminal.
@MainActor
final class SidebarRenameController: NSObject, NSTextFieldDelegate {
    private let store: AppStore
    weak var outlineView: NSOutlineView?

    /// Called with the edited row after commit or cancel, so the Coordinator can refresh its label and
    /// return focus to the active terminal. Invoked asynchronously after end-editing, so the field editor's
    /// resign settles first, or when `beginEditing` cannot focus the field.
    var onRenameEnded: ((SidebarNode?) -> Void)?
    var onMouseTrackingEnded: (() -> Void)?

    /// Set while an end-editing notification is being processed, to ignore the re-entrant end-editing the
    /// cancel/commit path can trigger.
    private var committing = false
    /// The row whose field is the active first responder (between `beginEditing` and `restore`), so a badge
    /// tick can't reload the row out from under the in-progress edit. `committing` covers only the
    /// end-editing instant; this covers the whole typing window. End-editing commits to this row, not the
    /// field's current row, which a workspace collapse removes mid-edit.
    private var editingNode: SidebarNode?
    /// Set by the Esc handler (`doCommandBy` cancelOperation) so the end-editing that the
    /// manual resign triggers is treated as a cancel — the typed value is discarded.
    private var cancellingRename = false
    /// The row's pre-edit label, captured in `beginEditing` so an Esc-cancel can restore the displayed text
    /// (a manual resign keeps the edited stringValue, and a cancel makes no model change, so no reload
    /// refreshes the row).
    private var renameOriginalValue: String?

    /// Whether a rename field is being edited (first responder between `beginEditing` and `restore`).
    var isEditing: Bool { editingNode != nil }
    private var mouseTrackingDepth = 0
    var isTrackingMouse: Bool { mouseTrackingDepth > 0 }
    /// Editing, committing, or still tracking a mouse-down in the field editor, which can outlive the edit.
    /// The Coordinator holds every rebuild, row reload, selection sync and focus hand-back while this is set.
    var isRenameInFlight: Bool { isEditing || committing || isTrackingMouse }

    func beginMouseTracking() { mouseTrackingDepth += 1 }

    func endMouseTracking() {
        mouseTrackingDepth -= 1
        guard mouseTrackingDepth == 0 else { return }
        DispatchQueue.main.async { [weak self] in self?.onMouseTrackingEnded?() }
    }

    /// remote sends a rename in a remote window to its server, answering whether it did.
    private let remote: (RemoteOperation) -> Bool

    init(store: AppStore, remote: @escaping (RemoteOperation) -> Bool) {
        self.store = store
        self.remote = remote
        super.init()
    }

    /// Puts the row's text field into editing mode and focuses it. Called from the "Rename" menu item and
    /// from double-click. A request for another row commits the open edit first, since its end-editing would
    /// otherwise clear the new edit's state; a repeat for the row being edited keeps that edit.
    func beginEditing(node: SidebarNode) {
        guard !committing, !isTrackingMouse, let outline = outlineView else { return }
        if let editingNode {
            guard editingNode.id != node.id else { return }
            outline.window?.makeFirstResponder(nil)
            guard !isEditing else { return }
        }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        renameOriginalValue = field.stringValue
        // the flagged view shows a decorated `name : workspace` label; seed the field with the bare session
        // name so an edit never bakes the ` : workspace` tail into the custom name. no-op in tree mode.
        if node.kind == .session, let session = store.session(withID: node.id) {
            field.stringValue = session.displayName
        }
        field.isEditable = true
        field.isBordered = true
        field.drawsBackground = true
        // the editable field draws its own background while the label color is the row's (often dark)
        // selection-foreground, so leaving both makes the edit text dark-on-dark on every theme. paint the
        // field with the theme's foreground-on-background; setColors restores the row color on the
        // post-commit reload.
        let theme = GhosttyApp.shared
        field.textColor = theme.terminalForegroundColor ?? .labelColor
        field.backgroundColor = theme.terminalBackgroundColor ?? .textBackgroundColor
        field.setAccessibilityIdentifier("edit-field")
        editingNode = node
        // pause auto-follow while the rename field owns first responder: an armed idle jump would move the
        // outline selection off this row and yank focus into the followed terminal, silently committing the
        // rename mid-edit. balanced by the resume in `restore` when editing ends.
        store.suppressAutoFollow()
        guard let window = field.window, window.makeFirstResponder(field), isEditing, field.currentEditor() != nil else {
            if isEditing {
                restore(field: field, kind: node.kind)
                DispatchQueue.main.async { [weak self] in self?.onRenameEnded?(node) }
            }
            return
        }
    }

    /// Intercepts Esc during an inline rename. The field is focused via `makeFirstResponder`, not the
    /// outline's edit session, so AppKit never delivers the cancel text-movement and `cancelOperation:`
    /// would leave the field stuck in edit mode. Flag the cancel, resign so `controlTextDidEndEditing` fires,
    /// and consume the command so the no-op default handling doesn't run.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard isEditing, commandSelector == #selector(NSResponder.cancelOperation(_:)),
              let field = control as? NSTextField else { return false }
        cancellingRename = true
        field.window?.makeFirstResponder(outlineView)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !committing, let field = notification.object as? NSTextField else { return }
        committing = true
        defer { committing = false }

        let node = editingNode

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
        DispatchQueue.main.async { [weak self] in self?.onRenameEnded?(node) }
        guard let node, !cancelled else { return }

        switch node.kind {
        case .session:
            if remote(.renameSession(node.id, name: newValue)) { return }
            store.renameSession(node.id, to: newValue)
        case .workspace:
            if remote(.renameWorkspace(node.id, name: newValue)) { return }
            store.renameWorkspace(node.id, to: newValue)
        }
    }

    /// Returns a renamed/edited field to its non-editable label state and resets its accessibility
    /// identifier to the row identifier for its kind.
    private func restore(field: NSTextField, kind: SidebarNode.Kind?) {
        editingNode = nil
        // rename ended (commit or cancel) — lift the suppression `beginEditing` took so auto-follow resumes.
        store.resumeAutoFollow()
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.setAccessibilityIdentifier(kind == .workspace ? "workspace-row" : "session-row")
        // restore the row's selection-aware themed color so a commit that didn't change the name (no
        // reload) doesn't leave beginEditing's edit-box color stuck on the row. read the hosting row view's
        // live isSelected — the state the selection pill draws from — rather than recomputing via
        // row(for:), which can miss if the row was reloaded during the edit; a stale tint here is invisible
        // text on themes where foreground == selection-background.
        if let cell = field.superview as? SidebarCellView {
            cell.setColors(selected: (cell.superview as? NSTableRowView)?.isSelected ?? false)
        }
    }
}

final class SidebarNameField: NSTextField {
    override static var cellClass: AnyClass? {
        get { SidebarNameFieldCell.self }
        set { _ = newValue }
    }
}

final class SidebarNameFieldCell: NSTextFieldCell {
    weak var renameController: SidebarRenameController?
    private lazy var editor: SidebarNameFieldEditor = {
        let editor = SidebarNameFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    override func fieldEditor(for _: NSView) -> NSTextView? {
        editor.renameController = renameController
        return editor
    }
}

/// Ignores a mouse-down once detached, where TextKit 2 spins on the main thread. While attached, its tracking
/// loop holds sidebar updates: a reload mid-drag would detach it under the loop.
final class SidebarNameFieldEditor: NSTextView {
    weak var renameController: SidebarRenameController?

    override func mouseDown(with event: NSEvent) {
        guard window != nil, superview != nil, let renameController else { return }
        renameController.beginMouseTracking()
        defer { renameController.endMouseTracking() }
        super.mouseDown(with: event)
    }
}
