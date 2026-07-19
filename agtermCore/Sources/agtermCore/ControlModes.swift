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

/// Parsed view mode for `sidebar.mode`.
public enum ControlSidebarViewMode: Equatable, Sendable {
    case tree
    case flagged
    case toggle

    public static func parse(_ mode: String?) -> ControlSidebarViewMode? {
        switch mode ?? "toggle" {
        case "tree": return .tree
        case "flagged": return .flagged
        case "toggle": return .toggle
        default: return nil
        }
    }
}

/// The mutually exclusive move forms accepted by `session.move`.
public enum ControlSessionMove: Equatable, Sendable {
    case reorder(ReorderDirection)
    case workspace(String)
    /// Relocate + position relative to an anchor session (id / prefix / `active`). `after == false`
    /// places before the anchor. The anchor carries its own workspace, so this form self-identifies the
    /// destination and never reads the workspace parameter.
    case place(anchor: String, after: Bool)
}

/// Parsed resize request for `session.resize`.
public enum ControlSplitResize: Equatable, Sendable {
    case ratio(Double)
    case delta(Double)
}

/// Host-facing `session.new` options after dispatcher-level guard validation.
public struct ControlSessionCreateOptions: Equatable, Sendable {
    public let window: String?
    public let cwd: String?
    public let workspace: String?
    public let workspaceName: String?
    public let createWorkspace: Bool?
    public let command: String?
    /// Whether a `--command` session HOLDS its surface after the command exits (`--wait`) instead of
    /// closing immediately. Meaningful only with `command`; the dispatcher rejects `--wait` without a
    /// `--command`.
    public let wait: Bool?
    public let name: String?
    /// Anchor session to place the new session right AFTER (id / prefix / `active`); the anchor carries
    /// its own workspace, so this bypasses `workspace`/`workspaceName`. Mutually exclusive with `before`.
    public let after: String?
    /// Anchor session to place the new session right BEFORE, the mirror of `after`.
    public let before: String?
    /// Create the session in the background: skip selecting and focusing it, leaving the current selection
    /// untouched (the CLI's `--no-select`). Defaults to false — the normal select-and-focus behavior.
    public let noSelect: Bool

    public init(window: String?, cwd: String?, workspace: String?, workspaceName: String?,
                createWorkspace: Bool?, command: String?, wait: Bool? = nil, name: String?,
                after: String? = nil, before: String? = nil, noSelect: Bool = false) {
        self.window = window
        self.cwd = cwd
        self.workspace = workspace
        self.workspaceName = workspaceName
        self.createWorkspace = createWorkspace
        self.command = command
        self.wait = wait
        self.name = name
        self.after = after
        self.before = before
        self.noSelect = noSelect
    }
}

/// Parsed `session.status` payload. Sound validation and playback stay host-side; `color` is the
/// per-call `#rrggbb` glyph-tint override (validated for hex in the dispatcher), threaded onto the
/// ephemeral `AgentIndicator`.
public struct ControlSessionStatusUpdate: Equatable, Sendable {
    public let status: AgentStatus
    public let blink: Bool?
    public let autoReset: Bool?
    public let sound: String?
    public let color: String?
    /// Which pane set the status (`left`=main, `right`=split, `scratch`), or nil when unspecified. Stamped
    /// onto the indicator so pane-scoped keystroke-clear and pane-aware navigation know which surface blocked.
    public let pane: StatusPane?
    /// The surface's STABLE spawn token (the shell's baked `AGTERM_PANE_ID`, forwarded by the hook as
    /// `--pane-id`). Resolved app-side against the session's live surfaces (`Session.paneRole(forToken:)`);
    /// when it resolves it OVERRIDES the stale role `pane`, fixing a status set from a promoted-then-re-split
    /// pane (#199). nil/empty/unknown falls back to `pane`. The resolution stays app-side because the
    /// dispatcher has no session — this only carries the token through.
    public let paneID: String?

    public init(status: AgentStatus, blink: Bool?, autoReset: Bool?, sound: String?,
                color: String? = nil, pane: StatusPane? = nil, paneID: String? = nil) {
        self.status = status
        self.blink = blink
        self.autoReset = autoReset
        self.sound = sound
        self.color = color
        self.pane = pane
        self.paneID = paneID
    }
}
