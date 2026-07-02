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
    case workspaceFocus = "workspace.focus"
    case sessionType = "session.type"
    case sessionStatus = "session.status"
    case sessionFlag = "session.flag"
    case sessionBackground = "session.background"
    case sessionSplit = "session.split"
    case sessionScratch = "session.scratch"
    case sessionFocus = "session.focus"
    case sessionResize = "session.resize"
    case sessionCopy = "session.copy"
    case sessionText = "session.text"
    case sessionSearch = "session.search"
    case sessionOverlayOpen = "session.overlay.open"
    case sessionOverlayClose = "session.overlay.close"
    case sessionOverlayResult = "session.overlay.result"
    case quick
    case sidebar
    case sidebarMode = "sidebar.mode"
    case sidebarExpand = "sidebar.expand"
    case sidebarCollapse = "sidebar.collapse"
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
    case windowZoom = "window.zoom"
    case keymapReload = "keymap.reload"
    case configReload = "config.reload"
    case themeSet = "theme.set"
    case themeList = "theme.list"
    case restoreClear = "restore.clear"
}

/// A bag of optional command parameters. Each command reads only the fields it needs; the rest stay
/// nil and are omitted from the JSON, keeping the wire form compact.
public struct ControlArgs: Codable, Sendable, Equatable {
    /// New name for `workspace.new`, `workspace.rename`, `session.rename`; the initial session name
    /// for `session.new` (optional; blank/omitted leaves the auto basename); the theme name for
    /// `theme.set` (omitted/empty selects ghostty's built-in colors / "default ghostty", NOT the
    /// seeded `agterm` app default).
    public var name: String?
    /// Working directory for `session.new`.
    public var cwd: String?
    /// Target workspace for `session.new` (the workspace to add to) and `session.move` (the destination).
    /// Resolved by id / unique prefix / `active`, never by name — use `workspaceName` for name targeting.
    public var workspace: String?
    /// Target workspace BY NAME for `session.new` (mutually exclusive with `workspace`). Reuses the first
    /// workspace with this exact name; an absent name is an error unless `createWorkspace` is set.
    public var workspaceName: String?
    /// For `session.new` with `workspaceName`: create the named workspace when none exists (idempotent
    /// reuse-or-create). An error without `workspaceName` — there is nothing to create by id.
    public var createWorkspace: Bool?
    /// Text to inject for `session.type`; the search needle for `session.search`.
    public var text: String?
    /// Whether `session.type` may select a never-shown session to realize its surface.
    public var select: Bool?
    /// Mode for `session.split` / `quick` (`on|off|toggle`, `show|hide|toggle` for quick),
    /// `session.flag` (`on|off|toggle|clear`), `sidebar.mode` (`tree|flagged|toggle`),
    /// `workspace.focus` (`on|off|toggle`), and `session.background` (`image|text|color|clear`).
    public var mode: String?
    /// The image file path for `session.background` mode `image` (PNG or JPEG).
    public var path: String?
    /// The color (`#rrggbb`) for `session.background`: the text tint for mode `text` (nil = the terminal
    /// foreground), or the solid background color for mode `color` (required). Mode `color` takes no
    /// opacity — it honors the Settings window translucency. Also the optional solid background color for
    /// `session.overlay.open` (the overlay pane's own color, independent of the session's); nil = the
    /// default theme background, honoring the same window translucency.
    public var color: String?
    /// The `background-image-opacity` for `session.background` (image + text), 0...1; nil = ghostty's 1.0.
    public var opacity: Double?
    /// The `background-image-fit` for `session.background` (`contain|cover|stretch|none`); nil = `contain`.
    public var fit: String?
    /// The `background-image-position` for `session.background` (`center` + 8 anchors); nil = `center`.
    public var position: String?
    /// The `background-image-repeat` flag for `session.background`; nil = false.
    public var repeats: Bool?
    /// Which split pane to focus for `session.focus` (`left`|`right`|`other`; `other` toggles); also
    /// which pane to read for `session.text` (`left`|`right`; omitted = the focused pane, no `other`).
    public var pane: String?
    /// Absolute left-pane split fraction (0...1) for `session.resize`, clamped server-side to
    /// `AppStore.splitRatioMin...splitRatioMax`. Mutually exclusive with `ratioDelta`.
    public var ratio: Double?
    /// Signed relative split-divider nudge for `session.resize`: a positive fraction grows the LEFT
    /// pane, negative grows the right (the CLI's `--grow-left`/`--grow-right`). Applied to the session's
    /// current fraction (0.5 when never moved). Mutually exclusive with `ratio`.
    public var ratioDelta: Double?
    /// For `session.text`: read the full screen + scrollback instead of just the visible screen.
    public var all: Bool?
    /// For `session.text`: keep only the last N lines of the full buffer.
    public var lines: Int?
    /// Direction for `session.go` (`next`|`prev`|`previous`|`first`|`last`), for the reorder form of
    /// `session.move` / `workspace.move` (`up`|`down`|`top`|`bottom`), and for `session.search`
    /// (`next`|`prev`|`close`).
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
    /// One-shot sound to play when `session.status` is set (caller-driven, not stored on the indicator):
    /// `default`/`beep` is the system alert sound, any other value is a named system sound
    /// (`NSSound(named:)`, e.g. `Glass`, also resolving custom sounds in `~/Library/Sounds`). nil/empty means
    /// no per-call sound — the app may still play the Settings "Blocked sound" default on a `blocked` status.
    public var sound: String?

    public init(name: String? = nil, cwd: String? = nil, workspace: String? = nil, workspaceName: String? = nil,
                createWorkspace: Bool? = nil, text: String? = nil, select: Bool? = nil, mode: String? = nil,
                command: String? = nil, wait: Bool? = nil, sizePercent: Int? = nil, window: String? = nil,
                pane: String? = nil, to: String? = nil, title: String? = nil, body: String? = nil,
                width: Int? = nil, height: Int? = nil, x: Int? = nil, y: Int? = nil, display: Int? = nil,
                status: String? = nil, blink: Bool? = nil, autoReset: Bool? = nil, sound: String? = nil,
                ratio: Double? = nil, ratioDelta: Double? = nil,
                path: String? = nil, color: String? = nil, opacity: Double? = nil, fit: String? = nil,
                position: String? = nil, repeats: Bool? = nil, all: Bool? = nil, lines: Int? = nil) {
        self.name = name
        self.cwd = cwd
        self.workspace = workspace
        self.workspaceName = workspaceName
        self.createWorkspace = createWorkspace
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
        self.sound = sound
        self.ratio = ratio
        self.ratioDelta = ratioDelta
        self.path = path
        self.color = color
        self.opacity = opacity
        self.fit = fit
        self.position = position
        self.repeats = repeats
        self.all = all
        self.lines = lines
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
    /// The raw terminal title from the latest OSC 0/1/2 (a remote host over SSH, a shell
    /// `PROMPT_COMMAND`); nil when none has been reported (omitted from the JSON). This is the
    /// unprocessed `Session.oscTitle`, distinct from `name` (the derived sidebar label, which uses the
    /// title as one fallback) — useful to a script because a remote session's local `cwd` goes stale.
    public let title: String?
    public let active: Bool
    public let split: Bool
    public let overlay: Bool
    public let scratch: Bool
    public let flagged: Bool
    /// The LIVE foreground process command (full argv) in the main pane, or nil when the pane is at its
    /// shell prompt (omitted from the JSON). The same capture the restore-running-command feature uses,
    /// surfaced for introspection ("what is each pane running").
    public let foreground: [String]?
    /// The split (right) pane's live foreground command (full argv), the split analogue of `foreground`.
    public let splitForeground: [String]?
    /// The session's agent status (`active`/`completed`/`blocked`) as the `AgentStatus` raw value, or nil
    /// when the session is idle (omitted from the JSON). The read side of `session.status`.
    public let status: String?
    /// The session's background watermark spec, or nil when none is set (omitted from the JSON). The read
    /// side of `session.background` — set/clear/query symmetry, so a script can inspect the current watermark.
    public let background: BackgroundWatermark?

    public init(id: String, name: String, cwd: String, title: String? = nil, active: Bool, split: Bool,
                overlay: Bool = false, scratch: Bool = false, flagged: Bool = false,
                foreground: [String]? = nil, splitForeground: [String]? = nil, status: String? = nil,
                background: BackgroundWatermark? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.title = title
        self.active = active
        self.split = split
        self.overlay = overlay
        self.scratch = scratch
        self.flagged = flagged
        self.foreground = foreground
        self.splitForeground = splitForeground
        self.status = status
        self.background = background
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
    /// `keymap.reload`, the ghostty config-diagnostic count for `config.reload` (counted across ALL config
    /// sources, not just the agterm-scoped `ghostty.conf` — libghostty diagnostics carry no source-file
    /// attribution), and the total match count for `session.search` (whose "N of M" display string rides
    /// in `text`).
    public var count: Int?
    /// The current/affected theme name for `theme.set` (echo) and `theme.list` (current); nil =
    /// ghostty's built-in colors ("default ghostty"), distinct from the seeded `agterm` app default.
    public var theme: String?
    /// The available bundled theme names for `theme.list`.
    public var themes: [String]?
    /// The applied (clamped) left-pane split fraction echoed by `session.resize`, so a script can see
    /// where the divider landed after clamping / a relative nudge.
    public var ratio: Double?

    public init(id: String? = nil, tree: ControlTree? = nil, text: String? = nil,
                windows: [ControlWindowNode]? = nil, exitCode: Int? = nil, count: Int? = nil,
                theme: String? = nil, themes: [String]? = nil, ratio: Double? = nil) {
        self.id = id
        self.tree = tree
        self.text = text
        self.windows = windows
        self.exitCode = exitCode
        self.count = count
        self.theme = theme
        self.themes = themes
        self.ratio = ratio
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
