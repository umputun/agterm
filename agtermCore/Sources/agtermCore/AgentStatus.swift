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
    /// clears ONLY on Escape — the interrupt key — so ordinary typing while the agent works does NOT wipe
    /// the "working" glyph, but cancelling (Esc) a prompt the agent is showing does. This is what covers
    /// the quick-Esc case: a pending question can still read `active` when you cancel it (Claude Code's
    /// `blocked` notification lands seconds later), and the Esc-interrupt itself fires no hook, so this
    /// keystroke clear is the only signal that drops the stale `active`. `idle` has no glyph to clear.
    public func clearedByKeystroke(isEscape: Bool) -> Bool {
        switch self {
        case .blocked, .completed: return true
        case .active: return isEscape
        case .idle: return false
        }
    }
}

/// AgentIndicator is the per-session agent status value: the state plus an optional blink flag (pulse
/// the glyph for attention) and an optional autoReset flag (clear back to idle once the session is
/// visited). It is ephemeral (never persisted) and set only via the control API.
public struct AgentIndicator: Equatable, Sendable {
    /// status is the current agent state; `.idle` renders no glyph.
    public var status: AgentStatus = .idle
    /// blink makes the visible glyph pulse for attention.
    public var blink: Bool = false
    /// autoReset, when true, the indicator resets to idle once the session is visited (selected) — a
    /// caller-set, status-agnostic flag, like blink.
    public var autoReset: Bool = false

    public init(status: AgentStatus = .idle, blink: Bool = false, autoReset: Bool = false) {
        self.status = status
        self.blink = blink
        self.autoReset = autoReset
    }
}
