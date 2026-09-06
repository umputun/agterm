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
    /// anchor is absent for a dialog centered over the window's terminal area.
    public let anchor: AskAnchor?

    public init(id: String, title: String, message: String? = nil, buttons: [ControlAskButton],
                defaultID: String? = nil, destructiveID: String? = nil, style: ControlAskStyle = .terminal, align: ControlAskAlignment = .right,
                width: Int? = nil, anchor: AskAnchor? = nil) {
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
}
