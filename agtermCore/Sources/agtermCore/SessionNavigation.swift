import Foundation

// The keyboard/control vocabulary for moving the selection. Pure value types with no store
// dependency; `AppStore.navigateSession`/`navigateWorkspace` are what apply them.

/// A step through the flattened session list for keyboard navigation. `next`/`previous` step one
/// and wrap, `first`/`last` jump to a tree end, `nextAttention`/`previousAttention` step (wrapping) through
/// only the sessions needing attention — status `blocked` or `completed`, and `slot` is the absolute
/// browser-style ⌘1…⌘9 jump.
public enum SessionNavigation: Sendable, Equatable {
    case next, previous, first, last, nextAttention, previousAttention
    case slot(Int)
}

extension SessionNavigation {
    /// Maps a control-channel direction string to a case, nil for an unknown one. Both `prev` (the CLI's
    /// spelling) and `previous` are accepted; `1`…`9` are the slots, the same vocabulary the chords carry.
    public init?(wire: String) {
        switch wire {
        case "next": self = .next
        case "prev", "previous": self = .previous
        case "first": self = .first
        case "last": self = .last
        case "next-attention": self = .nextAttention
        case "prev-attention", "previous-attention": self = .previousAttention
        default:
            guard let slot = Int(wire), SessionSlot.range.contains(slot) else { return nil }
            self = .slot(slot)
        }
    }
}

/// The absolute session slots ⌘1…⌘9 select. The nine are a fixed vocabulary shared by
/// `BuiltinAction.selectSession1`…`9` and `session.go --to 1`…`9`, so a chord and a control call mean one
/// thing.
public enum SessionSlot {
    public static let range = 1...9

    /// Which index of the flattened list `slot` names, nil when it names nothing. The LAST slot overflows to
    /// the end of the list — with more sessions than slots there would otherwise be no keystroke reaching the
    /// tail at all — but only then: with nine or fewer it stays the plain ninth, so a slot never means two
    /// rows at one count. An out-of-range slot and one past the end both resolve to nil.
    public static func index(_ slot: Int, count: Int) -> Int? {
        guard range.contains(slot), count > 0 else { return nil }
        if slot == range.upperBound, count > range.upperBound { return count - 1 }
        return slot <= count ? slot - 1 : nil
    }
}

/// A relative step through the visible workspace list. Only `next`/`previous`: a workspace carries no
/// attention state, and wrapping already reaches both ends.
public enum WorkspaceNavigation: Sendable { case next, previous }

/// What one workspace step landed on. The indicator is the selected session's, captured BEFORE an
/// `autoReset` status cleared, which is what lets the GUI route pane reveal exactly as session nav does
/// (`AppActions.revealActiveBlockedPane`); nil for an empty workspace.
public struct WorkspaceStep: Sendable {
    public let workspaceID: UUID
    public let indicator: AgentIndicator?
}

extension WorkspaceNavigation {
    /// Maps a control-channel direction string to a case, nil for unknown. Both spellings of previous.
    public init?(wire: String) {
        switch wire {
        case "next": self = .next
        case "prev", "previous": self = .previous
        default: return nil
        }
    }
}
