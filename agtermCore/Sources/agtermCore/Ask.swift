import Foundation

/// AskAnchor identifies the session or pane captured when a dialog opens.
public struct AskAnchor: Equatable, Sendable {
    /// sessionID identifies the session whose area anchors the dialog.
    public let sessionID: UUID
    /// pane is the role resolved at open, absent for a session-wide anchor.
    public let pane: OverlayPane?
    /// paneIdentity follows the pane through swaps and primary promotion.
    public let paneIdentity: UUID?

    public init(sessionID: UUID, pane: OverlayPane? = nil, paneIdentity: UUID? = nil) {
        self.sessionID = sessionID
        self.pane = pane
        self.paneIdentity = paneIdentity
    }
}

/// AskInputForm configures an ask's text field.
public struct AskInputForm: Codable, Equatable, Sendable {
    /// maxTextBytes caps the prefill and the field's content in UTF-8 bytes.
    public static let maxTextBytes = 65_536

    public let mode: ControlAskInputMode
    /// value is the field's initial text.
    public let value: String
    /// placeholder is the hint shown while the field is empty.
    public let placeholder: String?

    public init(mode: ControlAskInputMode, value: String = "", placeholder: String? = nil) {
        self.mode = mode
        self.value = value
        self.placeholder = placeholder
    }

    /// hasForbiddenControls reports a C0 control or DEL in `text`, newline and tab excepted in a multiline field.
    /// Remote handover sizes answers on this rule: some refused controls escape to six JSON bytes.
    public static func hasForbiddenControls(_ text: String, mode: ControlAskInputMode) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard scalar.value < 0x20 || scalar.value == 0x7f else { return false }
            return mode == .line || (scalar != "\n" && scalar != "\t")
        }
    }

    /// clamped cuts `text` at a character boundary so it fits `maxTextBytes`.
    public static func clamped(_ text: String) -> String {
        guard text.utf8.count > maxTextBytes else { return text }
        var bytes = 0
        let kept = text.prefix { character in
            bytes += character.utf8.count
            return bytes <= maxTextBytes
        }
        return String(kept)
    }
}

/// AskChoiceForm configures an ask's radio or checkbox list.
public struct AskChoiceForm: Codable, Equatable, Sendable {
    public let choices: [ControlAskChoice]
    /// multiple selects checkboxes; radio buttons otherwise.
    public let multiple: Bool
    /// checked lists the initially selected ids; a radio list holds at most one.
    public let checked: [String]
    /// other is the placeholder of a free-form row after the choices; nil means no such row.
    public let other: String?

    public init(choices: [ControlAskChoice], multiple: Bool = false, checked: [String] = [], other: String? = nil) {
        self.choices = choices
        self.multiple = multiple
        self.checked = checked
        self.other = other
    }

    /// isBlank reports text with no non-whitespace character: the free-form row is disabled and unselected
    /// while its text is blank, and an answer never carries blank text.
    public static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}

/// AskForm is the optional content an ask shows between its message and its buttons.
public enum AskForm: Equatable, Sendable {
    case input(AskInputForm)
    case choices(AskChoiceForm)
}

/// AskDraft is the user's unsubmitted input, kept by the ask's slot owner so hiding the dialog keeps it.
public struct AskDraft: Equatable, Sendable {
    /// text is the input field content, or the free-form row's text in a choice list, held within
    /// `AskInputForm.maxTextBytes`. A choice-list edit selects the row when non-blank and unselects it when blank.
    public var text: String {
        didSet {
            text = AskInputForm.clamped(text)
            guard hasOther else { return }
            if AskChoiceForm.isBlank(text) { unselectOther() } else { selectOther() }
        }
    }
    /// cursor is the index of the list item keyboard actions apply to; the free-form row follows the choices.
    public private(set) var cursor: Int
    public private(set) var checked: Set<String>
    /// otherSelected reports the free-form row as part of the answer.
    public private(set) var otherSelected = false
    private let choiceIDs: [String]
    private let multiple: Bool
    private let hasOther: Bool
    /// previousPick is the radio item the free-form row took over from, restored when its text goes blank.
    private var previousPick: String?

    /// Starts from the form's initial values: the prefill, the checked ids, and a radio list's first item
    /// when nothing is checked. The cursor starts on the first checked item in caller order.
    public init(form: AskForm?) {
        switch form {
        case .input(let input):
            text = AskInputForm.clamped(input.value)
            choiceIDs = []
            multiple = false
            checked = []
            hasOther = false
        case .choices(let list):
            text = ""
            choiceIDs = list.choices.map(\.id)
            multiple = list.multiple
            checked = list.multiple ? Set(list.checked) : Set([list.checked.first ?? choiceIDs.first].compactMap { $0 })
            hasOther = list.other != nil
        case nil:
            text = ""
            choiceIDs = []
            multiple = false
            checked = []
            hasOther = false
        }
        cursor = 0
        cursor = choiceIDs.firstIndex(where: checked.contains) ?? 0
    }

    /// selected lists the checked caller ids in caller order; the free-form row answers through `otherText`.
    public var selected: [String] { choiceIDs.filter(checked.contains) }

    /// otherEnabled reports a free-form row whose text is not blank, so it can be selected.
    public var otherEnabled: Bool { hasOther && !AskChoiceForm.isBlank(text) }

    /// otherText is the free-form row's text as typed while the row is selected, nil otherwise.
    public var otherText: String? { otherSelected && otherEnabled ? text : nil }

    /// cursorOnOther reports the cursor on the free-form row, where the row's own editor takes the keys.
    public var cursorOnOther: Bool { hasOther && cursor == choiceIDs.count }

    /// moveCursor steps the cursor by `offset`, stopping at the list ends; the free-form row is the last stop.
    public mutating func moveCursor(by offset: Int) {
        let rows = choiceIDs.count + (hasOther ? 1 : 0)
        guard rows > 0 else { return }
        cursor = min(max(cursor + offset, 0), rows - 1)
    }

    /// toggle moves the cursor to `index`, then picks a radio item or flips a checkbox. The free-form row
    /// toggles only while enabled, and a picked radio row stays picked.
    public mutating func toggle(at index: Int) {
        if hasOther, index == choiceIDs.count {
            cursor = index
            guard otherEnabled else { return }
            if multiple, otherSelected { otherSelected = false } else { selectOther() }
            return
        }
        guard choiceIDs.indices.contains(index) else { return }
        cursor = index
        let id = choiceIDs[index]
        guard multiple else {
            checked = [id]
            otherSelected = false
            previousPick = nil
            return
        }
        if checked.remove(id) == nil { checked.insert(id) }
    }

    private mutating func selectOther() {
        guard !otherSelected else { return }
        otherSelected = true
        guard !multiple else { return }
        previousPick = checked.first
        checked = []
    }

    private mutating func unselectOther() {
        guard otherSelected else { return }
        otherSelected = false
        guard !multiple else { return }
        checked = Set([previousPick ?? choiceIDs.first].compactMap { $0 })
        previousPick = nil
    }

    /// toggleCursor applies `toggle` to the cursor's item.
    public mutating func toggleCursor() {
        toggle(at: cursor)
    }
}

/// A dialog awaiting an answer in its owning session or window.
public struct PendingAsk: Equatable, Sendable {
    /// id is the globally unique dialog request id.
    public let id: String
    /// title is the dialog headline.
    public let title: String
    /// message is the optional body below the title.
    public let message: String?
    /// buttons preserves the caller's choice order.
    public let buttons: [ControlAskButton]
    /// defaultID identifies the initially highlighted button.
    public let defaultID: String?
    /// Style selects session ownership for terminal asks, window ownership for GUI asks, and default placement.
    public let style: ControlAskStyle
    /// align positions the button block in both row and column layouts.
    public let align: ControlAskAlignment
    /// width is a fixed percentage of the anchor, absent for content sizing.
    public let width: Int?
    /// destructiveID identifies the button styled as destructive.
    public let destructiveID: String?
    /// GUI session/pane anchor; terminal placement belongs to Session.
    public let anchor: AskAnchor?
    /// form is the text field or choice list shown above the buttons, absent for a plain button ask.
    public let form: AskForm?
    /// cancelID identifies the button that resolves `escaped`, as Esc does.
    public let cancelID: String?

    public init(id: String, title: String, message: String? = nil, buttons: [ControlAskButton],
                defaultID: String? = nil, destructiveID: String? = nil, style: ControlAskStyle = .terminal, align: ControlAskAlignment = .right,
                width: Int? = nil, anchor: AskAnchor? = nil, form: AskForm? = nil, cancelID: String? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.buttons = buttons
        self.defaultID = defaultID
        self.style = style
        self.align = align
        self.width = width
        self.destructiveID = destructiveID
        self.anchor = anchor
        self.form = form
        self.cancelID = cancelID
    }

    /// answer is the outcome of pressing the button at `index` with `draft` as the form's input: the cancel
    /// button escapes with no payload, any other answers with the field text, or the selected ids plus the
    /// selected free-form row's text.
    public func answer(buttonAt index: Int, draft: AskDraft?) -> ControlAskResult? {
        guard buttons.indices.contains(index) else { return nil }
        let button = buttons[index]
        if button.id == cancelID { return ControlAskResult(result: .escaped) }
        let input = draft ?? AskDraft(form: form)
        switch form {
        case .input:
            return ControlAskResult(result: .answered, id: button.id, label: button.label, index: index, text: input.text)
        case .choices:
            return ControlAskResult(result: .answered, id: button.id, label: button.label, index: index,
                                    text: input.otherText, selected: input.selected)
        case nil:
            return ControlAskResult(result: .answered, id: button.id, label: button.label, index: index)
        }
    }

    /// validatedAnswer checks an answer that arrived from elsewhere against this ask: a known button, the cancel
    /// role applied here, and a payload matching the form (text within the cap, or known ids in caller order plus
    /// the free-form row's non-blank text, exactly one of them for radio). Text follows its field's
    /// control-character rule. Nil refuses the answer.
    public func validatedAnswer(buttonID: String, text: String?, selected: [String]?) -> ControlAskResult? {
        guard let index = buttons.firstIndex(where: { $0.id == buttonID }) else { return nil }
        if buttonID == cancelID {
            return text == nil && selected == nil ? ControlAskResult(result: .escaped) : nil
        }
        let label = buttons[index].label
        switch form {
        case .input(let input):
            guard let text, selected == nil, text.utf8.count <= AskInputForm.maxTextBytes,
                  !AskInputForm.hasForbiddenControls(text, mode: input.mode) else { return nil }
            return ControlAskResult(result: .answered, id: buttonID, label: label, index: index, text: text)
        case .choices(let list):
            guard let selected else { return nil }
            if let text {
                guard list.other != nil, !AskChoiceForm.isBlank(text), text.utf8.count <= AskInputForm.maxTextBytes,
                      !AskInputForm.hasForbiddenControls(text, mode: .line) else { return nil }
            }
            let chosen = Set(selected)
            let picks = selected.count + (text == nil ? 0 : 1)
            guard list.choices.map(\.id).filter(chosen.contains) == selected, list.multiple || picks == 1 else { return nil }
            return ControlAskResult(result: .answered, id: buttonID, label: label, index: index, text: text, selected: selected)
        case nil:
            guard text == nil, selected == nil else { return nil }
            return ControlAskResult(result: .answered, id: buttonID, label: label, index: index)
        }
    }

    /// The same dialog anchored at `anchor`, everything else kept.
    public func anchored(at anchor: AskAnchor?) -> PendingAsk {
        PendingAsk(id: id, title: title, message: message, buttons: buttons, defaultID: defaultID,
                   destructiveID: destructiveID, style: style, align: align, width: width, anchor: anchor,
                   form: form, cancelID: cancelID)
    }
}

/// Indexes live ask owners and retains finished results after their owners disappear.
@MainActor
public final class AskRegistry {
    public static let shared = AskRegistry()
    static let retainedResultLimit = 32

    /// Identifies the live slot and its owning window for result and cancellation scoping.
    public enum Owner: Equatable, Sendable {
        case window(WindowInfo.ID)
        case session(UUID, window: WindowInfo.ID)

        public var windowID: WindowInfo.ID {
            switch self {
            case .window(let id), .session(_, window: let id): id
            }
        }
    }

    /// Reads the owner's current pending ask without keeping a second copy in the registry.
    public var resolveOwner: (Owner) -> PendingAsk?
    private var owners: [String: Owner] = [:]
    private var finished: [(id: String, result: ControlAskResult, windowID: WindowInfo.ID)] = []

    public init(resolveOwner: @escaping (Owner) -> PendingAsk? = { _ in nil }) {
        self.resolveOwner = resolveOwner
    }

    /// Indexes an opened ask, refusing an id already pending or retained.
    @discardableResult
    public func register(id: String, owner: Owner) -> Bool {
        guard owners[id] == nil, !finished.contains(where: { $0.id == id }) else { return false }
        owners[id] = owner
        return true
    }

    /// Moves a pending ask to another live owner, for one handed back from a viewer into a window slot.
    public func reassign(id: String, to owner: Owner) {
        guard owners[id] != nil else { return }
        owners[id] = owner
    }

    /// Returns the registered live owner; finished and unknown ids have none.
    public func owner(for id: String) -> Owner? {
        owners[id]
    }

    /// Returns a pending or retained result; a registered id not held by its owner is unknown, so openAsk must precede register.
    public func result(for id: String) -> (result: ControlAskResult, windowID: WindowInfo.ID)? {
        if let owner = owners[id] {
            guard resolveOwner(owner)?.id == id else { return nil }
            return (ControlAskResult(result: .pending), owner.windowID)
        }
        guard let resolved = finished.first(where: { $0.id == id }) else { return nil }
        return (resolved.result, resolved.windowID)
    }

    /// The first terminal outcome wins; repeated resolution does not refresh its eviction order.
    @discardableResult
    public func retain(id: String, result: ControlAskResult, window: WindowInfo.ID) -> Bool {
        guard result.result != .pending, owners[id]?.windowID == window else { return false }
        owners[id] = nil
        finished.append((id, result, window))
        if finished.count > Self.retainedResultLimit { finished.removeFirst() }
        return true
    }
}

/// AskNavigation tracks keyboard selection in caller button order.
public struct AskNavigation: Sendable {
    /// highlighted is absent only when the button list is empty.
    public private(set) var highlighted: Int?
    private let buttons: [ControlAskButton]

    public init(buttons: [ControlAskButton], defaultID: String? = nil, destructiveID: String? = nil) {
        self.buttons = buttons
        highlighted = defaultID.flatMap { id in buttons.firstIndex { $0.id == id } }
            ?? buttons.firstIndex { $0.id != destructiveID }
            ?? buttons.indices.first
    }

    /// moveForward enters at the first button and wraps after the last.
    public mutating func moveForward() {
        guard !buttons.isEmpty else { return }
        highlighted = highlighted.map { ($0 + 1) % buttons.count } ?? 0
    }

    /// moveBackward enters at the last button and wraps before the first.
    public mutating func moveBackward() {
        guard !buttons.isEmpty else { return }
        highlighted = highlighted.map { ($0 + buttons.count - 1) % buttons.count } ?? (buttons.count - 1)
    }

    /// activate returns the highlighted button's index, or nil for an empty list.
    public func activate() -> Int? {
        highlighted
    }

    /// hotkey returns a matching button's index without requiring a highlight.
    public func hotkey(_ letter: String) -> Int? {
        let key = letter.lowercased()
        return buttons.firstIndex { $0.hotkey?.lowercased() == key }
    }

    /// resolvedHotkey is the lowercase ASCII letter a key press spells for a hotkey, or nil for any other key.
    /// It resolves as keymap chords do (`chordKey`), so a non-Latin layout answers from the US-layout position.
    public static func resolvedHotkey(forKeyCode keyCode: UInt16, produced: String?, layoutIsASCIICapable: Bool) -> String? {
        guard let key = chordKey(forKeyCode: keyCode, produced: produced, layoutIsASCIICapable: layoutIsASCIICapable),
              key.utf8.count == 1, let ascii = key.utf8.first, (97...122).contains(ascii) else { return nil }
        return key
    }
}
