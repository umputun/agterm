import Foundation

/// Parsed binary control mode with the shared default/toggle semantics used by mode-bearing commands.
public enum ControlToggleMode: Equatable, Sendable {
    case on
    case off
    case toggle

    /// Parse a mode string, defaulting nil to `toggle`. Callers keep their command-specific tokens and
    /// error strings by choosing the true/false spellings they already expose on the wire.
    public static func parse(_ mode: String?, on onToken: String = "on", off offToken: String = "off") -> ControlToggleMode? {
        let value = mode ?? "toggle"
        if value == onToken { return .on }
        if value == offToken { return .off }
        if value == "toggle" { return .toggle }
        return nil
    }

    public func desiredValue(current: Bool) -> Bool {
        switch self {
        case .on: return true
        case .off: return false
        case .toggle: return !current
        }
    }
}

/// Parsed pane selector for `session.focus`, including the default/toggle aliases.
public enum ControlPaneFocusMode: Equatable, Sendable {
    case primary
    case split
    case toggle

    public static func parse(_ pane: String?) -> ControlPaneFocusMode? {
        switch pane ?? "other" {
        case "left", "primary": return .primary
        case "right", "split": return .split
        case "other", "toggle": return .toggle
        default: return nil
        }
    }

    public func wantsSplit(currentSplitFocused: Bool) -> Bool {
        switch self {
        case .primary: return false
        case .split: return true
        case .toggle: return !currentSplitFocused
        }
    }
}
