import Foundation

/// AgentStatus is the per-session agent state driven over the control channel (`session.status`).
/// `idle` means nothing is shown; the other cases each render a tinted sidebar glyph.
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle, active, completed, blocked

    /// True for the states that need user attention (a `blocked` prompt or a `completed` run) — the set
    /// the attention navigation (⌃⌥↑/↓, `session.go next-attention|prev-attention`) steps through,
    /// excluding `idle` (no glyph) and `active` (the agent is still working).
    public var needsAttention: Bool { self == .blocked || self == .completed }

    /// Whether a keystroke in the session's terminal should clear this glyph back to idle. `blocked` and
    /// `completed` clear on ANY key (you've engaged with the prompt / the finished result); `active`
    /// clears ONLY on an interrupt keystroke (Escape or Ctrl-C) — so ordinary typing while the agent works
    /// does NOT wipe the "working" glyph, but cancelling a prompt the agent is showing does. Both keys
    /// interrupt: Claude Code (like most TUIs) treats Ctrl-C as Esc for dismissing a pending prompt. This
    /// covers the quick-cancel case: a pending question can still read `active` when you cancel it (Claude
    /// Code's `blocked` notification lands seconds later), and the interrupt itself fires no hook, so this
    /// keystroke clear is the only signal that drops the stale `active`. `idle` has no glyph to clear.
    func clearedByKeystroke(isInterrupt: Bool) -> Bool {
        switch self {
        case .blocked, .completed: return true
        case .active: return isInterrupt
        case .idle: return false
        }
    }

    /// Sort priority for the attention list: lower comes first. `blocked` (0) is most urgent, then
    /// `active` (1), then `completed` (2). `idle` (3) is never sorted — idle sessions are filtered out
    /// before the list is built — but it ranks last so any accidental inclusion sorts after the rest.
    public var attentionRank: Int {
        switch self {
        case .blocked: return 0
        case .active: return 1
        case .completed: return 2
        case .idle: return 3
        }
    }

    /// The sound to play for a `session.status` call, or nil for none. An explicit per-call sound
    /// (`session.status --sound`) always wins; otherwise the caller-configured `blockedDefault` plays, but
    /// ONLY for the `blocked` state (the Settings "Blocked sound"). Empty strings count as unset. The app
    /// resolves the returned name with `NSSound(named:)`; this is just the host-free precedence decision.
    public func effectiveSound(perCall: String?, blockedDefault: String?) -> String? {
        if let perCall, !perCall.isEmpty { return perCall }
        if self == .blocked, let blockedDefault, !blockedDefault.isEmpty { return blockedDefault }
        return nil
    }

    /// SF Symbol name for the status glyph, shared by the AppKit sidebar and the SwiftUI attention list.
    /// `idle` returns the empty string — idle never renders a glyph, so it is filtered out before any
    /// glyph is built and this value is never used.
    public var symbolName: String {
        switch self {
        case .active: return "ellipsis.circle.fill"
        case .blocked: return "exclamationmark.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .idle: return ""
        }
    }

    /// Tooltip for a visible status glyph. Idle renders no glyph and therefore has no tooltip.
    public var tooltipText: String? {
        self == .idle ? nil : "Agent status: \(rawValue.capitalized)"
    }
}

/// StatusPane records which pane of a session set the current agent status, using the same
/// `left|right|scratch` vocabulary as the `--pane` control argument (`left`=main, `right`=split).
/// It rides on `AgentIndicator` so pane-scoped keystroke-clear and pane-aware navigation know which
/// surface blocked. Raw values serialize to JSON as `"left"|"right"|"scratch"`.
public enum StatusPane: String, Codable, Sendable, CaseIterable {
    case left, right, scratch
}

/// AgentIndicator is the per-session agent status value: the state plus an optional blink flag (pulse
/// the glyph for attention), an optional autoReset flag (clear back to idle once the session is
/// visited), an optional per-call color override for the glyph tint, and the pane that set the status.
/// It is ephemeral (never persisted) and set only via the control API.
public struct AgentIndicator: Equatable, Sendable {
    /// status is the current agent state; `.idle` renders no glyph.
    public var status: AgentStatus = .idle
    /// blink makes the visible glyph pulse for attention.
    public var blink: Bool = false
    /// autoReset, when true, the indicator resets to idle once the session is visited (selected) — a
    /// caller-set, status-agnostic flag, like blink.
    public var autoReset: Bool = false
    /// color, when set, is a `#rrggbb` hex that overrides the Settings-configured glyph tint for this
    /// glyph only — a caller-set, per-call value that rides the ephemeral indicator, so the next
    /// `session.status` call without a color naturally discards it. nil renders the default status color.
    public var color: String?
    /// statusPane records which pane set this status; nil means unspecified and is treated as `.left`
    /// (main) by the clear logic.
    public var statusPane: StatusPane?

    public init(status: AgentStatus = .idle, blink: Bool = false, autoReset: Bool = false,
                color: String? = nil, statusPane: StatusPane? = nil) {
        self.status = status
        self.blink = blink
        self.autoReset = autoReset
        self.color = color
        self.statusPane = statusPane
    }

    /// clearedBy reports whether a keystroke from `pane` should clear this indicator back to idle. It
    /// clears only when the keystroke's own pane owns the current status (a nil `statusPane` is treated
    /// as `.left`) AND the status itself is clearable by that keystroke (`AgentStatus.clearedByKeystroke`).
    /// This keeps foreground typing from wiping a status set by a background pane.
    public func clearedBy(pane: StatusPane, isInterrupt: Bool) -> Bool {
        (statusPane ?? .left) == pane && status.clearedByKeystroke(isInterrupt: isInterrupt)
    }
}
