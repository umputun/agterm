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

/// PendingAsk holds one dialog awaiting an answer in its owning window.
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
    /// cancelID identifies the button returned on user dismissal.
    public let cancelID: String?
    /// destructiveID identifies the button styled as destructive.
    public let destructiveID: String?
    /// anchor is absent for a dialog centered in the window.
    public let anchor: AskAnchor?

    public init(id: String, title: String, message: String? = nil, buttons: [ControlAskButton],
                defaultID: String? = nil, cancelID: String? = nil, destructiveID: String? = nil,
                anchor: AskAnchor? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.buttons = buttons
        self.defaultID = defaultID
        self.cancelID = cancelID
        self.destructiveID = destructiveID
        self.anchor = anchor
    }
}

/// AskNavigation tracks keyboard selection in caller button order.
public struct AskNavigation: Sendable {
    /// highlighted is absent until a default or navigation selects a button.
    public private(set) var highlighted: Int?
    private let buttons: [ControlAskButton]

    public init(buttons: [ControlAskButton], defaultID: String? = nil) {
        self.buttons = buttons
        highlighted = defaultID.flatMap { id in buttons.firstIndex { $0.id == id } }
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

    /// activate returns the highlighted button's index, or nil before selection.
    public func activate() -> Int? {
        highlighted
    }

    /// hotkey returns a matching button's index without requiring a highlight.
    public func hotkey(_ letter: String) -> Int? {
        let key = letter.lowercased()
        return buttons.firstIndex { $0.hotkey?.lowercased() == key }
    }
}
