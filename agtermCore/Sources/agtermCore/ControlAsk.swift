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

/// ControlAskStyle selects dialog decoration without changing behavior or placement.
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

    public init(result: ControlAskOutcome, id: String? = nil, label: String? = nil, index: Int? = nil) {
        self.result = result
        self.id = id
        self.label = label
        self.index = index
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
