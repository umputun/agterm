/// ControlAskButton is a caller-provided dialog button.
public struct ControlAskButton: Codable, Sendable, Equatable {
    /// maxButtons limits the number of buttons in one dialog.
    public static let maxButtons = 6

    /// id identifies the button in role assignments and answered results.
    public let id: String
    /// label is the button text shown in the dialog.
    public let label: String
    /// hotkey is the optional ASCII letter that activates the button.
    public let hotkey: String?

    public init(id: String, label: String, hotkey: String? = nil) {
        self.id = id
        self.label = label
        self.hotkey = hotkey
    }
}

/// ControlAskChoice is one caller-provided item of an ask choice list.
public struct ControlAskChoice: Codable, Sendable, Equatable {
    /// maxChoices limits the number of items in one list.
    public static let maxChoices = 50

    /// id identifies the item in `checked` and in the answered `selected` list.
    public let id: String
    /// label is the item's one-line text.
    public let label: String
    /// subtitle is an optional description drawn dimmed under the label; it may span lines.
    public let subtitle: String?

    public init(id: String, label: String, subtitle: String? = nil) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
    }
}

/// ControlAskInputMode selects a one-line or multiline ask text field.
public enum ControlAskInputMode: String, Codable, Sendable, CaseIterable {
    /// line is a single-line field where Return answers.
    case line
    /// multiline is an editing area where Return inserts a newline and Command-Return answers.
    case multiline
}

/// ControlAskOutcome is the current or terminal state returned by ask.result.
public enum ControlAskOutcome: String, Codable, Sendable, CaseIterable {
    /// pending means the dialog is awaiting an answer.
    case pending
    /// answered means the dialog resolved to a caller-provided button.
    case answered
    /// escaped means the user dismissed the dialog with Esc or Command-W.
    case escaped
    /// cancelled means the dialog was cancelled administratively.
    case cancelled
}

/// Selects dialog ownership, default placement, and appearance.
public enum ControlAskStyle: String, Codable, Sendable, CaseIterable {
    /// terminal uses monospace text and terminal theme colors.
    case terminal
    /// gui uses the palette appearance and native buttons.
    case gui
}

/// ControlAskAlignment positions the button block within its panel.
public enum ControlAskAlignment: String, Codable, Sendable, CaseIterable {
    /// left aligns the block to the leading edge.
    case left
    /// center centers the block horizontally.
    case center
    /// right aligns the block to the trailing edge.
    case right
}

/// ControlAskResult is the nested wire payload returned by ask.result.
public struct ControlAskResult: Codable, Sendable, Equatable {
    /// result is the current or terminal dialog outcome.
    public let result: ControlAskOutcome
    /// id identifies the answered button, absent without a button answer.
    public let id: String?
    /// label is the answered button's text, absent without a button answer.
    public let label: String?
    /// index is the answered button's zero-based position in caller order.
    public let index: Int?
    /// reason says why a cancelled dialog ended, absent for an ordinary cancel. An older client ignores it.
    public let reason: String?
    /// text is an input ask's field content, or a choice list's selected free-form row text, on an answer,
    /// whitespace and newlines preserved.
    public let text: String?
    /// selected is a choice ask's checked ids in caller order on an answer; radio carries exactly one, or none
    /// when its free-form row answers through `text`.
    public let selected: [String]?

    /// The reason an ask carries when the viewer presenting it was lost and the origin could not show it.
    public static let presentationLost = "presentation-lost"

    public init(result: ControlAskOutcome, id: String? = nil, label: String? = nil, index: Int? = nil,
                reason: String? = nil, text: String? = nil, selected: [String]? = nil) {
        self.result = result
        self.id = id
        self.label = label
        self.index = index
        self.reason = reason
        self.text = text
        self.selected = selected
    }
}

/// ResolvedAsk pairs a retained outcome with the dialog that produced it.
public struct ResolvedAsk: Codable, Sendable, Equatable {
    /// id identifies the dialog request, not the answered button.
    public let id: String
    /// result is the retained terminal outcome.
    public let result: ControlAskResult
    /// sequence orders resolutions across windows for retention.
    public let sequence: Int

    public init(id: String, result: ControlAskResult, sequence: Int = 0) {
        self.id = id
        self.result = result
        self.sequence = sequence
    }
}
