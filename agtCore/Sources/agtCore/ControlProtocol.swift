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
    case sessionRename = "session.rename"
    case sessionMove = "session.move"
    case sessionType = "session.type"
    case sessionSplit = "session.split"
    case sessionCopy = "session.copy"
    case sessionOverlayOpen = "session.overlay.open"
    case sessionOverlayClose = "session.overlay.close"
    case quick
    case fontInc = "font.inc"
    case fontDec = "font.dec"
    case fontReset = "font.reset"
    case statusbar
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
    /// Mode for `session.split` / `quick` / `statusbar` (`on|off|toggle`, `show|hide|toggle` for quick).
    public var mode: String?
    /// The program the overlay terminal runs for `session.overlay.open` (e.g. `revdiff`).
    public var command: String?
    /// Whether `session.overlay.open` keeps the overlay open after its command exits (showing the
    /// "press any key to close" prompt) instead of closing immediately.
    public var wait: Bool?

    public init(name: String? = nil, cwd: String? = nil, workspace: String? = nil, text: String? = nil,
                select: Bool? = nil, mode: String? = nil, command: String? = nil, wait: Bool? = nil) {
        self.name = name
        self.cwd = cwd
        self.workspace = workspace
        self.text = text
        self.select = select
        self.mode = mode
        self.command = command
        self.wait = wait
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

    public init(id: String, name: String, cwd: String, active: Bool, split: Bool, overlay: Bool = false) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.active = active
        self.split = split
        self.overlay = overlay
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

/// The successful payload: a new/affected id for mutating commands, a tree for `tree`, the selected text
/// for `session.copy`. All optional.
public struct ControlResult: Codable, Sendable, Equatable {
    public var id: String?
    public var tree: ControlTree?
    public var text: String?

    public init(id: String? = nil, tree: ControlTree? = nil, text: String? = nil) {
        self.id = id
        self.tree = tree
        self.text = text
    }
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
