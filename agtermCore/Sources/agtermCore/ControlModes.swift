import Foundation

/// Host-facing `events.read` options after dispatcher validation and normalization.
public struct ControlEventReadOptions: Equatable, Sendable {
    public let cursor: ControlEventCursor?
    public let kinds: Set<ControlEventKind>?
    public let limit: Int

    public init(cursor: ControlEventCursor?, kinds: Set<ControlEventKind>?, limit: Int) {
        self.cursor = cursor
        self.kinds = kinds
        self.limit = limit
    }
}

/// Parsed binary control mode with the shared default/toggle semantics used by mode-bearing commands.
public enum ControlToggleMode: Equatable, Sendable {
    case on
    case off
    case toggle

    /// Parse a mode string (nil = `toggle`); `onToken`/`offToken` keep each command's own wire spellings.
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

/// The four modes `workspace.focus` accepts; raw values are the wire tokens and `helpSummary` states each
/// one's effect. `add` leaves the filter flag alone so a set is built member by member with the whole tree on
/// screen — an add that enabled the filter would hide the rows the next add needs. There is no
/// membership-TOGGLE mode: the row menu's membership item computes its own direction from what it just read
/// and maps to `add` or `off`.
public enum ControlWorkspaceFocusMode: String, CaseIterable, Equatable, Sendable {
    case on, off, toggle, add

    /// Pipe-joined (`on|off|toggle|add`) for the dispatcher's rejection message; derived from `allCases`.
    public static var validNamesList: String { validNames.joined(separator: "|") }

    /// Comma-joined (`on, off, toggle, add`) for the `agtermctl workspace focus` local rejection message.
    public static var validNamesPhrase: String { validNames.joined(separator: ", ") }

    /// One clause per mode for the `agtermctl workspace focus` argument help (the
    /// `StatusShape.validNamesPhrase` precedent), so that help cannot go stale when a case is added. Every
    /// clause names the filter effect, else `add`'s "leaves the flag alone" reads as the exception.
    public var helpSummary: String {
        switch self {
        case .on: return "on (mark it alone and apply the filter)"
        case .off: return "off (unmark it; the filter switches off as the set empties)"
        case .toggle: return "toggle (replace-toggle and apply the filter, the default; clears when it is the only marked one AND the filter is applied)"
        case .add: return "add (mark it alongside the others, leaving the filter flag alone)"
        }
    }

    /// Every mode's `helpSummary`, comma-joined — the whole `--help` sentence, derived from `allCases`.
    public static var helpPhrase: String { allCases.map(\.helpSummary).joined(separator: ", ") }

    private static var validNames: [String] { allCases.map(\.rawValue) }
}

/// The mutually exclusive move forms accepted by `session.move`.
public enum ControlSessionMove: Equatable, Sendable {
    case reorder(ReorderDirection)
    case workspace(String)
    /// Relocate relative to an anchor session (id / prefix / `active`); `after == false` places before it.
    /// The anchor carries its own workspace, so this form never reads the workspace parameter.
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
    /// Hold the surface after `--command` exits; the dispatcher rejects `--wait` without a `--command`.
    public let wait: Bool?
    public let name: String?
    /// Anchor to place the new session right AFTER (id / prefix / `active`); it carries its own workspace,
    /// so this bypasses `workspace`/`workspaceName`. Mutually exclusive with `before`.
    public let after: String?
    /// Anchor session to place the new session right BEFORE, the mirror of `after`.
    public let before: String?
    /// Create in the background (`--no-select`): skip select+focus, leaving the current selection untouched.
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

/// Parsed `session.status` payload. Sound validation and playback stay host-side; the dispatcher
/// hex-validates the per-call `#rrggbb` `color`, and both overrides thread onto the ephemeral
/// `AgentIndicator`.
public struct ControlSessionStatusUpdate: Equatable, Sendable {
    public let status: AgentStatus
    public let blink: Bool?
    public let autoReset: Bool?
    public let sound: String?
    public let color: String?
    /// Per-call glyph silhouette; nil falls back to the Settings shape / the built-in plain circle. The
    /// dispatcher rejects an unknown raw value before any mutation.
    public let shape: StatusShape?
    /// Which pane set the status (`left`=main, `right`=split, `scratch`), nil when unspecified. Stamped onto
    /// the indicator so pane-scoped keystroke-clear and pane-aware navigation know which surface blocked.
    public let pane: StatusPane?
    /// The surface's STABLE spawn token (the shell's baked `AGTERM_PANE_ID`, forwarded as `--pane-id`),
    /// carried through only: the dispatcher has no session, so `Session.paneRole(forToken:)` resolves it
    /// app-side. A resolved token OVERRIDES the stale role `pane` (a promoted-then-re-split pane, #199);
    /// nil/empty/unknown falls back to `pane`.
    public let paneID: String?

    public init(status: AgentStatus, blink: Bool?, autoReset: Bool?, sound: String?,
                color: String? = nil, shape: StatusShape? = nil,
                pane: StatusPane? = nil, paneID: String? = nil) {
        self.status = status
        self.blink = blink
        self.autoReset = autoReset
        self.sound = sound
        self.color = color
        self.shape = shape
        self.pane = pane
        self.paneID = paneID
    }
}

/// The three forms of the `session.restore` per-pane restore-command override, from the wire tokens
/// `set` / `none` / `clear`. `pinNone` is not spelled `none`: a bare `case none` makes the compiler warn
/// "assuming you mean Optional<T>.none" in an Optional context, which the dispatcher's parse step is.
public enum ControlRestoreOverride: Equatable, Sendable {
    /// wire `set` — pin this shell line, run verbatim on the next launch.
    case pin(String)
    /// wire `none` — pin the pane to nothing, so it restores a plain shell.
    case pinNone
    /// wire `clear` — drop the pin, back to the captured-foreground auto-restore.
    case unpin

    /// Storage bound in UTF-8 BYTES, not graphemes: the pin persists in `windows/<id>.json`, so the cap
    /// guards the snapshot, not the display width.
    public static let maxCommandBytes = 1024
}

/// Parsed `session.restore` payload. `paneID` is carried opaquely and resolved app-side against the LIVE
/// surfaces (`Session.paneRole(forToken:)`), falling back to the baked role `pane` — but unlike
/// `session.status`, an unresolvable token with no explicit `pane` errors instead of defaulting to main.
public struct ControlSessionRestoreUpdate: Equatable, Sendable {
    public let pin: ControlRestoreOverride
    /// Which pane to pin (`left`=main, `right`=split, nil=main); `scratch` is rejected app-side, never restored.
    public let pane: StatusPane?
    /// The surface's STABLE spawn token (the shell's baked `AGTERM_PANE_ID`), forwarded as `--pane-id`.
    public let paneID: String?

    public init(pin: ControlRestoreOverride, pane: StatusPane? = nil, paneID: String? = nil) {
        self.pin = pin
        self.pane = pane
        self.paneID = paneID
    }
}
