import agtermCore
import AppKit

/// Owns the sidebar's inline-rename interaction: it is the `NSTextFieldDelegate` for the outline's
/// editable name fields and holds the rename reentrancy flags. The `WorkspaceSidebar.Coordinator`
/// creates one, points it at the outline, and starts an edit via `beginEditing(node:)`; it reads
/// `isEditing`/`isCommitting` to gate its own row reloads and focus hand-back, and supplies
/// `onRenameEnded` to return keyboard focus to the terminal once an edit finishes.
@MainActor
final class SidebarRenameController: NSObject, NSTextFieldDelegate {
    private let store: AppStore
    weak var outlineView: NSOutlineView?

    /// Called after an inline rename ends (commit or cancel), so the Coordinator can hand keyboard
    /// focus back to the active terminal. Invoked asynchronously from `controlTextDidEndEditing` so the
    /// field editor's resign settles first.
    var onRenameEnded: (() -> Void)?

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

    /// Whether a rename field is currently being edited (first responder between `beginEditing` and
    /// `restore`). Read by the Coordinator to skip row reloads and focus hand-back mid-edit.
    var isEditing: Bool { editing }
    /// Whether an end-editing notification is currently being processed. Read by the Coordinator to
    /// skip a row reload during the commit instant.
    var isCommitting: Bool { committing }

    init(store: AppStore) {
        self.store = store
        super.init()
    }

    /// Puts the row's text field into editing mode and focuses it. Called from
    /// the "Rename" menu item and from double-click.
    func beginEditing(node: SidebarNode) {
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
        // pause auto-follow while the rename field owns first responder: an armed idle jump would move the
        // outline selection off this row and yank focus into the followed terminal, silently committing the
        // rename mid-edit. balanced by the resume in `restore` when editing ends.
        store.suppressAutoFollow()
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
        DispatchQueue.main.async { [weak self] in self?.onRenameEnded?() }
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
        // rename ended (commit or cancel) — lift the suppression `beginEditing` took so auto-follow resumes.
        store.resumeAutoFollow()
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.setAccessibilityIdentifier(kind == .workspace ? "workspace-row" : "session-row")
        // beginEditing painted the field with the theme fg-on-bg for the edit box; restore the row's
        // selection-aware themed color so a commit that didn't change the name (no reload) doesn't
        // leave the edit color stuck on the row. read the hosting row view's live isSelected (the
        // state the selection pill draws from) rather than recomputing via row(for:), which can miss
        // if the row was reloaded during the edit — a stale tint here is invisible text on themes
        // where foreground == selection-background.
        if let cell = field.superview as? SidebarCellView {
            cell.setColors(selected: (cell.superview as? NSTableRowView)?.isSelected ?? false)
        }
    }
}
