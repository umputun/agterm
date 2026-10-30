import AppKit
import SwiftUI
import agtermCore

/// AskEditorBox holds the dialog's live text editor so its key catcher can hand it first responder, and so
/// keyboard ownership can tell the dialog's own field editor from an unrelated one.
@MainActor
final class AskEditorBox {
    private(set) weak var view: NSView?
    /// Runs when an editor joins a window, so a catcher that took focus before the editor existed hands it on.
    var onAttach: (() -> Void)?

    func attach(_ editor: NSView) {
        view = editor
        onAttach?()
    }

    /// A layout swap attaches the new editor before the old one leaves, so the old one's focus falls back to
    /// the window only now; the handover runs again once AppKit has moved it.
    func detach(_ editor: NSView) {
        guard view !== editor else {
            view = nil
            return
        }
        DispatchQueue.main.async { [weak self] in self?.onAttach?() }
    }

    /// The view that should become first responder: the text view inside a multiline editor's scroll view.
    var focusTarget: NSView? { (view as? NSScrollView)?.documentView ?? view }

    /// Whether `responder` is some ask dialog's editor, for a check that has no box to ask.
    static func isAskEditor(_ responder: NSResponder?) -> Bool {
        if responder is AskTextView { return true }
        return ((responder as? NSTextView)?.delegate as AnyObject?) is AskTextField
    }

    /// Whether `responder` is the editor, a view inside it, or the field editor editing it.
    func owns(_ responder: NSResponder?) -> Bool {
        guard let view, let responder else { return false }
        if responder === view { return true }
        if let editor = responder as? NSTextView, let field = view as? NSTextField,
           (editor.delegate as AnyObject?) === field { return true }
        return (responder as? NSView)?.isDescendant(of: view) == true
    }
}

/// AskTextEditor is an ask's one-line field or multiline editing area, bound to the slot owner's draft.
struct AskTextEditor: NSViewRepresentable {
    let mode: ControlAskInputMode
    let text: String
    let placeholder: String?
    let placeholderColor: NSColor
    let style: ControlAskStyle
    let font: NSFont
    let foreground: NSColor
    let box: AskEditorBox
    let onText: (String) -> Void
    let onKey: (AskKey) -> Void
    /// routesVertical sends Up/Down to the dialog, for the free-form row of a choice list; a standalone field
    /// keeps them as caret movement.
    var routesVertical = false
    /// onFocus runs when the one-line field takes first responder, so a click into it can move the list cursor.
    var onFocus: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A multiline editor asks for its laid-out text height at the offered width, soft wraps included,
    /// between five and fifteen lines, and gives way to a shorter offered height down to two lines.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: NSView, context _: Context) -> CGSize? {
        guard mode == .multiline, let width = proposal.width else { return nil }
        let line = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let bounds = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
            .boundingRect(with: CGSize(width: max(1, width - Self.multilineInset), height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lines = min(max(ceil(bounds.height / line), 5), 15)
        var height = lines * line + 4
        if let offered = proposal.height { height = max(min(height, offered), line * 2 + 4) }
        return CGSize(width: width, height: height)
    }

    /// The text container's line-fragment padding on both sides plus room for the scroller.
    private static let multilineInset: CGFloat = 10 + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)

    func makeNSView(context: Context) -> NSView {
        context.coordinator.update(self)
        let view: NSView
        switch mode {
        case .line:
            let field = AskTextField(box: box)
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            (field.cell as? AskTextFieldCell)?.textInset = style == .gui ? 6 : 0
            // let the gui field grow to its drawn box, so a click anywhere in the box lands on it
            if style == .gui { field.setContentHuggingPriority(.defaultLow, for: .vertical) }
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.cell?.wraps = false
            field.font = font
            field.textColor = foreground
            field.stringValue = text
            if let placeholder {
                field.placeholderAttributedString = NSAttributedString(
                    string: placeholder, attributes: [.font: font, .foregroundColor: placeholderColor])
            }
            field.delegate = context.coordinator
            field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.onFocus?() }
            field.setAccessibilityIdentifier("ask-input")
            view = field
        case .multiline:
            let scroll = AskTextScrollView(box: box)
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.borderType = style == .gui ? .bezelBorder : .noBorder
            let textView = AskTextView(frame: .zero)
            textView.isRichText = false
            textView.allowsUndo = true
            textView.drawsBackground = false
            textView.font = font
            textView.textColor = foreground
            textView.insertionPointColor = foreground
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isVerticallyResizable = true
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.string = text
            textView.delegate = context.coordinator
            textView.onSubmit = { context.coordinator.onKey(.activate) }
            textView.setAccessibilityIdentifier("ask-input")
            scroll.documentView = textView
            view = scroll
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(self)
        if let field = nsView as? NSTextField {
            field.font = font
            field.textColor = foreground
            if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
        } else if let textView = (nsView as? NSScrollView)?.documentView as? AskTextView {
            textView.font = font
            textView.textColor = foreground
            textView.insertionPointColor = foreground
            if textView.string != text, !textView.hasMarkedText() { textView.string = text }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
        private(set) var onText: (String) -> Void = { _ in }
        private(set) var onKey: (AskKey) -> Void = { _ in }
        private(set) var onFocus: (() -> Void)?
        private var mode: ControlAskInputMode = .line
        private var foreground: NSColor = .textColor
        private var routesVertical = false

        func update(_ editor: AskTextEditor) {
            onText = editor.onText
            onKey = editor.onKey
            onFocus = editor.onFocus
            mode = editor.mode
            foreground = editor.foreground
            routesVertical = editor.routesVertical
        }

        func controlTextDidBeginEditing(_ note: Notification) {
            (note.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = foreground
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            onText(field.stringValue)
        }

        func textDidChange(_ note: Notification) {
            guard let textView = note.object as? NSTextView else { return }
            onText(textView.string)
        }

        /// Refuses an edit, composition included, that would pass the text cap or bring in a forbidden control,
        /// so the view never holds more than the draft keeps and nothing already typed is truncated later.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            askEditAllowed(textView, range: range, replacement: text, mode: mode)
        }

        func control(_: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            handle(selector, in: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            handle(selector, in: textView)
        }

        /// Tab, Shift-Tab and Esc drive the dialog in both modes and Return answers a one-line field; every
        /// other command, and every key while a composition is in progress, stays native editing.
        private func handle(_ selector: Selector, in textView: NSTextView) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertTab(_:)): onKey(.forward)
            case #selector(NSResponder.insertBacktab(_:)): onKey(.backward)
            case #selector(NSResponder.cancelOperation(_:)): onKey(.cancel)
            case #selector(NSResponder.insertNewline(_:)) where mode == .line: onKey(.activate)
            case #selector(NSResponder.moveUp(_:)) where routesVertical: onKey(.up)
            case #selector(NSResponder.moveDown(_:)) where routesVertical: onKey(.down)
            default: return false
            }
            return true
        }
    }
}

/// Whether replacing `range` (UTF-16, as AppKit gives it) with `replacement` keeps the editor within the text
/// cap and free of controls the mode forbids; marked text counts, so a composition can never push the field past
/// what the draft keeps. A paste carrying a forbidden control is refused whole.
@MainActor func askEditAllowed(_ textView: NSTextView, range: NSRange, replacement: String?, mode: ControlAskInputMode) -> Bool {
    guard let replacement else { return true }
    guard !AskInputForm.hasForbiddenControls(replacement, mode: mode) else { return false }
    let replaced = (textView.string as NSString).substring(with: range).utf8.count
    return textView.string.utf8.count - replaced + replacement.utf8.count <= AskInputForm.maxTextBytes
}

/// The one-line field's own field editor. A formatter never sees marked text, so the cap is held here, where
/// AppKit asks before every change.
final class AskFieldEditor: NSTextView {
    override func shouldChangeText(in range: NSRange, replacementString text: String?) -> Bool {
        askEditAllowed(self, range: range, replacement: text, mode: .line) && super.shouldChangeText(in: range, replacementString: text)
    }
}

/// Hands the one-line field its own `AskFieldEditor` in place of the window's shared one.
final class AskTextFieldCell: NSTextFieldCell {
    private lazy var editor: AskFieldEditor = {
        let editor = AskFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    override func fieldEditor(for _: NSView) -> NSTextView? { editor }

    var textInset: CGFloat = 0

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        guard textInset > 0 else { return super.drawingRect(forBounds: rect) }
        let line = font.map { ceil(NSLayoutManager().defaultLineHeight(for: $0)) } ?? rect.height
        let height = min(rect.height, line)
        return NSRect(x: rect.minX + textInset, y: rect.minY + (rect.height - height) / 2,
                      width: max(0, rect.width - textInset * 2), height: height)
    }

    // the placeholder is drawn through the title rect, and the field editor is placed from the rect passed to
    // select and edit, so all three take the inset
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        textInset > 0 ? drawingRect(forBounds: rect) : super.titleRect(forBounds: rect)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?,
                         start selStart: Int, length selLength: Int) {
        super.select(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
}

/// The one-line field; it tells its box it is the live editor only while it sits in a window, since a
/// measuring pass of `ViewThatFits` builds copies that are never shown.
final class AskTextField: NSTextField {
    private let box: AskEditorBox
    var onFocus: (() -> Void)?

    override static var cellClass: AnyClass? {
        get { AskTextFieldCell.self }
        set { _ = newValue }
    }

    init(box: AskEditorBox) {
        self.box = box
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { box.attach(self) } else { box.detach(self) }
    }

    /// The window's shared field editor keeps the last field's caret color until told otherwise.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let textColor { (currentEditor() as? NSTextView)?.insertionPointColor = textColor }
        if became { onFocus?() }
        return became
    }
}

/// The multiline editor's scroll view, registering with its box the way `AskTextField` does.
final class AskTextScrollView: NSScrollView {
    private let box: AskEditorBox

    init(box: AskEditorBox) {
        self.box = box
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { box.attach(self) } else { box.detach(self) }
    }
}

/// The multiline text view. Command-Return answers; AppKit binds no command to it, so it is caught here as a
/// key equivalent, only while this view is first responder and no composition is in progress.
final class AskTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !hasMarkedText(), [36, 76].contains(event.keyCode),
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        onSubmit?()
        return true
    }
}

/// AskChoiceList draws an ask's radio or checkbox items with the keyboard cursor and optional subtitles.
struct AskChoiceList: View {
    let form: AskChoiceForm
    let draft: AskDraft
    let style: ControlAskStyle
    let font: NSFont
    let foreground: Color
    let background: Color
    let cell: CGFloat
    /// otherField is the free-form row's one-line editor, present when the form has the row.
    var otherField: AnyView?
    let onToggle: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: cell * 0.6) {
            ForEach(rows) { row in
                self.row(row.choice, index: row.index)
                    .id(row.id)
            }
            if let otherField {
                otherRow(otherField)
                    .id(Self.otherRowID)
            }
        }
        .scrollTargetLayout()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// rowID tags a caller item's id; `scrollPosition` matches the ForEach identity and `scrollTo` the
    /// explicit id, so both use it, and the free-form row's `otherRowID` lacks the prefix every caller row has.
    nonisolated static func rowID(_ id: String) -> String { "ask-choice-\(id)" }
    static let otherRowID = "ask-other"

    private struct Row: Identifiable {
        let index: Int
        let choice: ControlAskChoice
        var id: String { AskChoiceList.rowID(choice.id) }
    }

    private var rows: [Row] { form.choices.enumerated().map { Row(index: $0.offset, choice: $0.element) } }

    /// The free-form row: its marker toggles like any item once the text is non-blank and is dimmed until
    /// then; the field edits without toggling.
    private func otherRow(_ field: AnyView) -> some View {
        let index = form.choices.count
        let current = draft.cursor == index
        return HStack(alignment: .center, spacing: cell) {
            marker(checked: draft.otherSelected, current: current)
                .padding(.horizontal, cell * 0.5)
                .padding(.vertical, cell * 0.15)
                .foregroundStyle(style == .terminal && current ? background : (style == .gui ? Color.primary : foreground))
                .background {
                    if current {
                        if style == .terminal { foreground } else { RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25)) }
                    }
                }
                .opacity(draft.otherEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onTapGesture { onToggle(index) }
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(draft.otherSelected ? "checked" : "")
                .accessibilityIdentifier(Self.otherRowID)
            field
        }
    }

    private func row(_ choice: ControlAskChoice, index: Int) -> some View {
        let checked = draft.checked.contains(choice.id)
        let current = draft.cursor == index
        return VStack(alignment: .leading, spacing: cell * 0.2) {
            HStack(alignment: .firstTextBaseline, spacing: cell) {
                marker(checked: checked, current: current)
                Text(verbatim: choice.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, cell * 0.5)
            .padding(.vertical, cell * 0.15)
            .foregroundStyle(style == .terminal && current ? background : (style == .gui ? Color.primary : foreground))
            .background {
                if current {
                    if style == .terminal { foreground } else { RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25)) }
                }
            }
            if let subtitle = choice.subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .foregroundStyle(style == .gui ? Color.secondary : foreground.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, cell * 0.5 + markerWidth + cell)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle(index) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(checked ? "checked" : "")
        .accessibilityIdentifier(Self.rowID(choice.id))
    }

    private var markerWidth: CGFloat {
        guard style == .terminal else { return 16 }
        return ceil(("[x]" as NSString).size(withAttributes: [.font: font]).width)
    }

    @ViewBuilder
    private func marker(checked: Bool, current: Bool) -> some View {
        if style == .gui {
            Image(systemName: form.multiple ? (checked ? "checkmark.square.fill" : "square")
                                            : (checked ? "largecircle.fill.circle" : "circle"))
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                .frame(width: markerWidth)
        } else {
            Text(verbatim: form.multiple ? (checked ? "[x]" : "[ ]") : (checked ? "(•)" : "( )"))
                .lineLimit(1)
                .fixedSize()
                .frame(width: markerWidth, alignment: .leading)
        }
    }
}
