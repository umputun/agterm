import Foundation

/// A control command name, the `cmd` field of a `ControlRequest`. Raw values are the wire strings
/// the CLI and the socket server agree on; an unknown string fails to decode, which the server
/// turns into an "unknown command" error rather than a crash.
public enum Command: String, Codable, Sendable {
    case tree
    case workspaceNew = "workspace.new"
    case workspaceRename = "workspace.rename"
    case workspaceDelete = "workspace.delete"
    case workspaceSelect = "workspace.select"
    case sessionNew = "session.new"
    case sessionClose = "session.close"
    case sessionSelect = "session.select"
    case sessionGo = "session.go"
    case sessionRename = "session.rename"
    case sessionMove = "session.move"
    case workspaceMove = "workspace.move"
    case sessionType = "session.type"
    case sessionStatus = "session.status"
    case sessionSplit = "session.split"
    case sessionScratch = "session.scratch"
    case sessionFocus = "session.focus"
    case sessionCopy = "session.copy"
    case sessionOverlayOpen = "session.overlay.open"
    case sessionOverlayClose = "session.overlay.close"
    case sessionOverlayResult = "session.overlay.result"
    case quick
    case notify
    case fontInc = "font.inc"
    case fontDec = "font.dec"
    case fontReset = "font.reset"
    case windowNew = "window.new"
    case windowList = "window.list"
    case windowSelect = "window.select"
    case windowClose = "window.close"
    case windowRename = "window.rename"
    case windowDelete = "window.delete"
    case windowResize = "window.resize"
    case windowMove = "window.move"
    case keymapReload = "keymap.reload"
}

/// A bag of optional command parameters. Each command reads only the fields it needs; the rest stay
/// nil and are omitted from the JSON, keeping the wire form compact.
public struct ControlArgs: Codable, Sendable, Equatable {
    /// New name for `workspace.new`, `workspace.rename`, `session.rename`.
    public var name: String?
    /// Working directory for `session.new`.
    public var cwd: String?
    /// Target workspace for `session.new` (the workspace to add to) and `session.move` (the destination).
    public var workspace: String?
    /// Text to inject for `session.type`.
    public var text: String?
    /// Whether `session.type` may select a never-shown session to realize its surface.
    public var select: Bool?
    /// Mode for `session.split` / `quick` (`on|off|toggle`, `show|hide|toggle` for quick).
    public var mode: String?
    /// Which split pane to focus for `session.focus` (`left`|`right`|`other`; `other` toggles).
    public var pane: String?
    /// Direction for `session.go` (`next`|`prev`|`previous`|`first`|`last`) and for the reorder form of
    /// `session.move` / `workspace.move` (`up`|`down`|`top`|`bottom`).
    public var to: String?
    /// The desktop-notification title for `notify` (optional; defaults to the target session's name).
    public var title: String?
    /// The desktop-notification body for `notify` (required).
    public var body: String?
    /// The program the overlay terminal runs for `session.overlay.open` (e.g. `revdiff`).
    public var command: String?
    /// Whether `session.overlay.open` keeps the overlay open after its command exits (showing the
    /// "press any key to close" prompt) instead of closing immediately.
    public var wait: Bool?
    /// For `session.overlay.open`, the percent of the pane (1...100) a *floating* overlay panel
    /// occupies in both dimensions; omitted gives the default full-pane overlay.
    public var sizePercent: Int?
    /// Target window for session/workspace/tree/font commands: id / prefix / `active` (=frontmost).
    /// Selects the window whose tree the command operates on.
    public var window: String?
    /// New window frame width/height in points for `window.resize`.
    public var width: Int?
    public var height: Int?
    /// New window top-left x/y in points for `window.move`, relative to the top-left of the target
    /// display (see `display`); y measured down from the display's top edge.
    public var x: Int?
    public var y: Int?
    /// Target display index (into the screen list) for `window.move`; nil = the window's current display.
    public var display: Int?
    /// Agent state for `session.status` (`idle|active|completed|blocked`).
    public var status: String?
    /// Whether the `session.status` indicator pulses for attention.
    public var blink: Bool?
    /// Whether the `session.status` indicator resets to idle once the session is visited (selected).
    public var autoReset: Bool?

    public init(name: String? = nil, cwd: String? = nil, workspace: String? = nil, text: String? = nil,
                select: Bool? = nil, mode: String? = nil, command: String? = nil, wait: Bool? = nil,
                sizePercent: Int? = nil, window: String? = nil, pane: String? = nil, to: String? = nil,
                title: String? = nil, body: String? = nil, width: Int? = nil, height: Int? = nil,
                x: Int? = nil, y: Int? = nil, display: Int? = nil, status: String? = nil, blink: Bool? = nil,
                autoReset: Bool? = nil) {
        self.name = name
        self.cwd = cwd
        self.workspace = workspace
        self.text = text
        self.select = select
        self.mode = mode
        self.command = command
        self.wait = wait
        self.sizePercent = sizePercent
        self.window = window
        self.pane = pane
        self.to = to
        self.title = title
        self.body = body
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.display = display
        self.status = status
        self.blink = blink
        self.autoReset = autoReset
    }
}

/// One control request: a command, an optional target (session or workspace id / `active` / prefix),
/// and an optional args bag. One request per connection, newline-delimited JSON.
public struct ControlRequest: Codable, Sendable, Equatable {
    public let cmd: Command
    public var target: String?
    public var args: ControlArgs?

    public init(cmd: Command, target: String? = nil, args: ControlArgs? = nil) {
        self.cmd = cmd
        self.target = target
        self.args = args
    }
}

/// A session as projected into the `tree` response.
public struct ControlSessionNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let cwd: String
    public let active: Bool
    public let split: Bool
    public let overlay: Bool
    public let scratch: Bool

    public init(id: String, name: String, cwd: String, active: Bool, split: Bool, overlay: Bool = false,
                scratch: Bool = false) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.active = active
        self.split = split
        self.overlay = overlay
        self.scratch = scratch
    }
}

/// A workspace and its sessions as projected into the `tree` response.
public struct ControlWorkspaceNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let active: Bool
    public let sessions: [ControlSessionNode]

    public init(id: String, name: String, active: Bool, sessions: [ControlSessionNode]) {
        self.id = id
        self.name = name
        self.active = active
        self.sessions = sessions
    }
}

/// The whole workspace tree, the payload of a `tree` response.
public struct ControlTree: Codable, Sendable, Equatable {
    public let workspaces: [ControlWorkspaceNode]

    public init(workspaces: [ControlWorkspaceNode]) {
        self.workspaces = workspaces
    }
}

/// A window as projected into the `window.list` response. `open` is whether its on-screen window is
/// up; `active` is whether it is the frontmost window.
public struct ControlWindowNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let open: Bool
    public let active: Bool

    public init(id: String, name: String, open: Bool, active: Bool) {
        self.id = id
        self.name = name
        self.open = open
        self.active = active
    }
}

/// The successful payload: a new/affected id for mutating commands, a tree for `tree`, the selected text
/// for `session.copy`. All optional.
public struct ControlResult: Codable, Sendable, Equatable {
    public var id: String?
    public var tree: ControlTree?
    public var text: String?
    public var windows: [ControlWindowNode]?
    /// The overlay program's exit status for `session.overlay.result` (nil until the program exits).
    public var exitCode: Int?
    /// A count payload for commands whose result is a number, e.g. the keymap-diagnostic count for
    /// `keymap.reload`.
    public var count: Int?

    public init(id: String? = nil, tree: ControlTree? = nil, text: String? = nil,
                windows: [ControlWindowNode]? = nil, exitCode: Int? = nil, count: Int? = nil) {
        self.id = id
        self.tree = tree
        self.text = text
        self.windows = windows
        self.exitCode = exitCode
        self.count = count
    }
}

/// Error strings for `session.overlay.result`, shared so the `agtermctl --block` poll matches the
/// server's wording exactly (the poll retries while the overlay is still running, by `error` string).
public enum OverlayResultError {
    public static let stillRunning = "overlay still running"
    public static let noResult = "no overlay result"
}

/// The single response written back per connection. `ok` gates `result` (on success) vs `error`.
public struct ControlResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public var result: ControlResult?
    public var error: String?

    public init(ok: Bool, result: ControlResult? = nil, error: String? = nil) {
        self.ok = ok
        self.result = result
        self.error = error
    }
}
