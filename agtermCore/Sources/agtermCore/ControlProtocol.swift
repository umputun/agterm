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
    case sessionReveal = "session.reveal"
    case sessionMove = "session.move"
    case workspaceMove = "workspace.move"
    case workspaceFocus = "workspace.focus"
    case sessionType = "session.type"
    case sessionStatus = "session.status"
    case sessionFlag = "session.flag"
    case sessionSeen = "session.seen"
    case sessionBackground = "session.background"
    case sessionSplit = "session.split"
    case sessionScratch = "session.scratch"
    case sessionFocus = "session.focus"
    case sessionResize = "session.resize"
    case surfaceZoom = "surface.zoom"
    case dashboard
    case sessionCopy = "session.copy"
    case sessionPaste = "session.paste"
    case sessionSelectAll = "session.selectall"
    case sessionText = "session.text"
    case sessionSearch = "session.search"
    case sessionOverlayOpen = "session.overlay.open"
    case sessionOverlayClose = "session.overlay.close"
    case sessionOverlayResize = "session.overlay.resize"
    case sessionOverlayResult = "session.overlay.result"
    case quick
    case quickType = "quick.type"
    case quickText = "quick.text"
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
    case windowFullscreen = "window.fullscreen"
    case keymapReload = "keymap.reload"
    case configReload = "config.reload"
    case themeSet = "theme.set"
    case themeList = "theme.list"
    case restoreClear = "restore.clear"
    /// UI-TEST-ONLY: force the app-level appearance (`light`|`dark` via `args.name`) so an XCUITest can
    /// simulate a macOS light/dark flip; with NO name it READS the side the last config feed applied,
    /// so a test can assert the flip actually drove the reload. The server refuses it outside an
    /// XCUITest launch; deliberately EXEMPT from the four-point keep-in-sync (no CLI subcommand, absent
    /// from the catalog/skill).
    case debugAppearance = "debug.appearance"
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
    /// Additional session targets for batch-capable commands (`session.close`, `session.move`). When set,
    /// the command uses this ordered list instead of the top-level single `target`.
    public var targets: [String]?
    /// Target workspace for `session.new` (the workspace to add to) and `session.move` (the destination).
    /// Resolved by id / unique prefix / `active`, never by name — use `workspaceName` for name targeting.
    public var workspace: String?
    /// Target workspace BY NAME for `session.new` (mutually exclusive with `workspace`). Reuses the first
    /// workspace with this exact name; an absent name is an error unless `createWorkspace` is set.
    public var workspaceName: String?
    /// For `session.new` with `workspaceName`: create the named workspace when none exists (idempotent
    /// reuse-or-create). An error without `workspaceName` — there is nothing to create by id.
    public var createWorkspace: Bool?
    /// Text to inject for `session.type` / `quick.type`; the search needle for `session.search`.
    public var text: String?
    /// Whether `session.type` may select a never-shown session to realize its surface.
    public var select: Bool?
    /// Mode for `session.split` / `quick` / `surface.zoom` (`on|off|toggle`,
    /// `show|hide|toggle` for quick/surface zoom),
    /// `session.flag` (`on|off|toggle|clear`), `sidebar.mode` (`tree|flagged|toggle`),
    /// `workspace.focus` (`on|off|toggle`), and `session.background` (`image|text|color|clear`).
    public var mode: String?
    /// The image file path for `session.background` mode `image` (PNG or JPEG).
    public var path: String?
    /// The color (`#rrggbb`) for `session.background`: the text tint for mode `text` (nil = the terminal
    /// foreground), or the solid background color for mode `color` (required). Mode `color` takes no
    /// opacity — it honors the Settings window translucency. Also the optional solid background color for
    /// `session.overlay.open` (the overlay pane's own color, independent of the session's); nil = the
    /// default theme background, honoring the same window translucency. And the optional per-call glyph-tint
    /// override for `session.status` (rides the ephemeral indicator, so it lasts only until the next
    /// `session.status` without a color); nil = the Settings-configured status color.
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
    /// which pane to read for `session.text` (`left`|`right`; omitted = the focused pane, no `other`),
    /// which pane `session.type` injects into (`left`|`right`; omitted = the left/main pane, the
    /// pre-pane behavior), and which pane set `session.status` (`left`|`right`|`scratch`; omitted =
    /// `left`/main, parsed to `StatusPane`).
    public var pane: String?
    /// A surface's STABLE spawn token for `session.status --pane-id` (the shell's baked `AGTERM_PANE_ID`,
    /// forwarded by the agent-status hook). When it resolves against the session's live surfaces it
    /// OVERRIDES the stale role `pane`, so a status set from a promoted-then-re-split pane lands on the
    /// pane's CURRENT slot; an empty/unknown token falls back to `pane`. Opaque — validated only by whether
    /// it resolves. See `Session.paneRole(forToken:)` and the #199 fix.
    public var paneID: String?
    /// Absolute left-pane split fraction (0...1) for `session.resize`, clamped server-side to
    /// `AppStore.splitRatioMin...splitRatioMax`. Mutually exclusive with `ratioDelta`.
    public var ratio: Double?
    /// Signed relative split-divider nudge for `session.resize`: a positive fraction grows the LEFT
    /// pane, negative grows the right (the CLI's `--grow-left`/`--grow-right`). Applied to the session's
    /// current fraction (0.5 when never moved). Mutually exclusive with `ratio`.
    public var ratioDelta: Double?
    /// For `session.text` / `quick.text`: read the full screen + scrollback instead of just the visible screen.
    public var all: Bool?
    /// For `session.text` / `quick.text`: keep only the last N lines of the full buffer.
    public var lines: Int?
    /// Direction for `session.go` (`next`|`prev`|`previous`|`first`|`last`), for the reorder form of
    /// `session.move` / `workspace.move` (`up`|`down`|`top`|`bottom`), and for `session.search`
    /// (`next`|`prev`|`close`).
    public var to: String?
    /// Anchor session (id / unique prefix / `active`) to place a session right AFTER, for the placement
    /// form of `session.new` / `session.move`. The anchor carries its own workspace (resolved across the
    /// whole store), so it self-identifies the destination — mutually exclusive with `to`, `before`, and
    /// the workspace parameter.
    public var after: String?
    /// Anchor session to place a session right BEFORE, the mirror of `after` (mutually exclusive with it).
    public var before: String?
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
    /// occupies in both dimensions; omitted gives the default full-pane overlay. Also carries the new
    /// size for `session.overlay.resize` (mutually exclusive with `full`).
    public var sizePercent: Int?
    /// For `session.overlay.resize`, requests the full-pane (translucent, session-hidden) overlay —
    /// the way to switch a floating overlay back to full. Mutually exclusive with `sizePercent`.
    public var full: Bool?
    /// For `session.overlay.open`, whether to select/switch to the target after opening; omitted/false
    /// opens in the background without changing the active session (the default for both full and
    /// floating overlays).
    public var follow: Bool?
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
    /// The per-slot theme names for `theme.set`: `light` is the light/single slot (an alias for the
    /// positional `name`, so passing both is an error); `dark` sets the dark slot — its presence makes
    /// the app track the macOS appearance (the stored value becomes ghostty's dual `light:,dark:`
    /// form), and the reserved value `none` clears it. Names must be bundled themes.
    public var light: String?
    public var dark: String?
    /// Whether `dashboard` CLOSES the open dashboard instead of opening one (the CLI's `--close`). Mutually
    /// exclusive with targets (the ids to open) and with the font flags — closing takes no other argument.
    public var close: Bool?
    /// The absolute cell font size in points for `dashboard` (the CLI's `--font-size`); must be positive.
    /// Mutually exclusive with `autoSize`.
    public var fontSize: Double?
    /// For `dashboard`, size the cells RELATIVE to the Settings default font size, shrinking as the grid
    /// grows so dense grids stay readable (the CLI's `--auto-size`). Mutually exclusive with `fontSize`.
    public var autoSize: Bool?
    /// For `dashboard`, populate the grid from the target window's most-recently-used sessions (up to 9,
    /// fewer if the window has fewer) instead of explicit ids (the CLI's `--mru`). Mutually exclusive with
    /// `targets` and `close`; composes with the font flags. The MRU resolution is app-side (it needs the
    /// store's recency), so this only signals the intent.
    public var mru: Bool?

    public init(name: String? = nil, cwd: String? = nil, targets: [String]? = nil,
                workspace: String? = nil, workspaceName: String? = nil,
                createWorkspace: Bool? = nil, text: String? = nil, select: Bool? = nil, mode: String? = nil,
                command: String? = nil, wait: Bool? = nil, sizePercent: Int? = nil, full: Bool? = nil,
                follow: Bool? = nil, window: String? = nil,
                pane: String? = nil, paneID: String? = nil, to: String? = nil,
                after: String? = nil, before: String? = nil,
                title: String? = nil, body: String? = nil,
                width: Int? = nil, height: Int? = nil, x: Int? = nil, y: Int? = nil, display: Int? = nil,
                status: String? = nil, blink: Bool? = nil, autoReset: Bool? = nil, sound: String? = nil,
                ratio: Double? = nil, ratioDelta: Double? = nil,
                path: String? = nil, color: String? = nil, opacity: Double? = nil, fit: String? = nil,
                position: String? = nil, repeats: Bool? = nil, all: Bool? = nil, lines: Int? = nil,
                light: String? = nil, dark: String? = nil,
                close: Bool? = nil, fontSize: Double? = nil, autoSize: Bool? = nil, mru: Bool? = nil) {
        self.name = name
        self.cwd = cwd
        self.targets = targets
        self.workspace = workspace
        self.workspaceName = workspaceName
        self.createWorkspace = createWorkspace
        self.text = text
        self.select = select
        self.mode = mode
        self.command = command
        self.wait = wait
        self.sizePercent = sizePercent
        self.full = full
        self.follow = follow
        self.window = window
        self.pane = pane
        self.paneID = paneID
        self.to = to
        self.after = after
        self.before = before
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
        self.light = light
        self.dark = dark
        self.close = close
        self.fontSize = fontSize
        self.autoSize = autoSize
        self.mru = mru
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

/// A terminal surface as projected into the `tree` response. `id` is the stable control address to pass
/// to `surface.zoom`; `kind` is the user-facing surface name (`left`, `right`, `scratch`, `overlay`).
/// `active`/`visible` are derived from the session's own flags (overlay/scratch/splitFocused), NOT from
/// terminal zoom — and `visible` reads false for a pane behind a FLOATING overlay even though that pane
/// is visually on screen (the derivation treats any open overlay as covering). Address by `id`/`kind`,
/// not by these flags; read the window's zoom state from the tree's top-level `zoomedSurface`.
public struct ControlSurfaceNode: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let active: Bool
    public let visible: Bool

    public init(id: String, kind: String, active: Bool, visible: Bool) {
        self.id = id
        self.kind = kind
        self.active = active
        self.visible = visible
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
    /// The left-pane fraction (0.05...0.95) of a session that HAS a split pane (shown or hidden), or nil
    /// when the session has no split OR the ratio was never explicitly set (via `session.resize` or a
    /// divider drag), in which case the divider sits at the default 0.5. The read side of `session.resize`
    /// — record it before maximizing a pane so a script can restore the exact divider position (the applied
    /// ratio is otherwise echoed only on the `session.resize` call itself).
    public let splitRatio: Double?
    /// For a session that HAS a split pane (shown or hidden), which pane holds keyboard focus: `true` = the
    /// split (right) pane, `false` = the main (left) pane; nil when the session has no split (omitted from
    /// the JSON). The read side of `session.focus` — record which pane was focused so a script can restore
    /// it via `session.focus --pane left|right`.
    public let splitFocused: Bool?
    public let overlay: Bool
    /// For an OPEN overlay (`overlay == true`), its size: nil/omitted = the FULL-pane overlay, else the
    /// floating panel's percent of the pane (1...100). Absent when no overlay is open. The read side of
    /// `session.overlay.resize` — record the current size before resizing so a script can restore it exactly.
    public let overlaySizePercent: Int?
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
    /// Which pane set the session's agent status (`"left"|"right"|"scratch"`, `left`=main, `right`=split),
    /// or nil when idle or unspecified (omitted from the JSON). The read side of `session.status --pane`.
    public let statusPane: String?
    /// Whether the session's agent status glyph is set to blink (pulse for attention), or nil when idle or
    /// not blinking (omitted from the JSON). The read side of `session.status --blink`.
    public let statusBlink: Bool?
    /// The per-call `#rrggbb` glyph-tint override for the session's agent status, or nil when idle or using
    /// the Settings-configured status color (omitted from the JSON). The read side of `session.status --color`.
    public let statusColor: String?
    /// The session's background watermark spec, or nil when none is set (omitted from the JSON). The read
    /// side of `session.background` — set/clear/query symmetry, so a script can inspect the current watermark.
    public let background: BackgroundWatermark?
    /// The session's unseen-notification badge count, or nil when zero (omitted from the JSON). The read
    /// side of the notification badge: `notify` (and terminal OSC 9/777) raise it, `session.seen` clears it.
    /// Ephemeral like `status` — never persisted, so it resets to nil on restart.
    public let unseen: Int?
    /// The default/left pane's live font size in points, resolved via `addressableSurface`: the main pane,
    /// or the promoted split survivor once the primary has exited (the same pane `font --pane left`, and the
    /// default, writes). Nil when that pane isn't realized (omitted from the JSON). Reflects the live cmd
    /// +/- value; the main pane's size is persisted across relaunch, but a promoted survivor's is live-only.
    public let fontSize: Double?
    /// The split (right) pane's live font size in points, or nil when the session has no realized split pane
    /// (omitted). The read side of `font --pane right` — the split's font is otherwise unobservable, being
    /// live-only (not persisted), so record it here before changing it.
    public let splitFontSize: Double?
    /// The scratch terminal's live font size in points, or nil when no scratch surface is realized (omitted).
    /// The read side of `font --pane scratch` (also live-only).
    public let scratchFontSize: Double?
    /// Addressable terminal surfaces owned by this session, or nil when talking to a server that
    /// predates `surface.zoom` (omitted from the JSON — the optional-field pattern every post-v1 tree
    /// addition uses, keeping Codable synthesized). Hidden-but-alive surfaces are included so control
    /// clients can zoom them without mutating split/scratch visibility first.
    public let surfaces: [ControlSurfaceNode]?

    public init(id: String, name: String, cwd: String, title: String? = nil, active: Bool, split: Bool,
                splitRatio: Double? = nil, splitFocused: Bool? = nil,
                overlay: Bool = false, overlaySizePercent: Int? = nil, scratch: Bool = false, flagged: Bool = false,
                foreground: [String]? = nil, splitForeground: [String]? = nil, status: String? = nil,
                statusPane: String? = nil, statusBlink: Bool? = nil, statusColor: String? = nil,
                background: BackgroundWatermark? = nil, unseen: Int? = nil,
                fontSize: Double? = nil, splitFontSize: Double? = nil, scratchFontSize: Double? = nil,
                surfaces: [ControlSurfaceNode]? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.title = title
        self.active = active
        self.split = split
        self.splitRatio = splitRatio
        self.splitFocused = splitFocused
        self.overlay = overlay
        self.overlaySizePercent = overlaySizePercent
        self.scratch = scratch
        self.flagged = flagged
        self.foreground = foreground
        self.splitForeground = splitForeground
        self.status = status
        self.statusPane = statusPane
        self.statusBlink = statusBlink
        self.statusColor = statusColor
        self.background = background
        self.unseen = unseen
        self.fontSize = fontSize
        self.splitFontSize = splitFontSize
        self.scratchFontSize = scratchFontSize
        self.surfaces = surfaces
    }
}

/// A workspace and its sessions as projected into the `tree` response.
public struct ControlWorkspaceNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let active: Bool
    /// Whether this workspace is the one the sidebar tree is FOCUSED (collapsed) to, or nil when it is not
    /// the focused one / no workspace is focused (omitted from the JSON). Distinct from `active` (the
    /// SELECTED workspace): focus collapses the sidebar to a single workspace. The read side of the
    /// write-only `workspace.focus` — so a script can record which workspace is focused and restore it.
    public let focused: Bool?
    public let sessions: [ControlSessionNode]

    public init(id: String, name: String, active: Bool, focused: Bool? = nil, sessions: [ControlSessionNode]) {
        self.id = id
        self.name = name
        self.active = active
        self.focused = focused
        self.sessions = sessions
    }
}

/// The whole workspace tree, the payload of a `tree` response.
public struct ControlTree: Codable, Sendable, Equatable {
    public let workspaces: [ControlWorkspaceNode]
    /// Milliseconds since the last user input in the projected window, or nil before any activity (omitted
    /// from the JSON). A LIVE, continuously-growing delta — `tree`-only because the tree is built fresh on
    /// the main actor per request; it must NOT ride `window.list` (cache-served, so it would freeze between
    /// commands). The read side of the auto-follow idle metric.
    public let idleMs: Int?
    /// The window's auto-follow-blocked timeout in milliseconds, or nil when the feature is disabled
    /// (omitted from the JSON). The read side of the GUI-only Auto-follow setting.
    public let autoFollowMs: Int?
    /// Whether the projected window's sidebar is currently visible. LIVE — built fresh from the window's
    /// store per request — so a script can read the current state (the read side of the write-only
    /// `sidebar` command; e.g. a tmux-style zoom that must restore the sidebar only when it was visible
    /// before zooming). Always present on a `tree` response (the producer passes a non-optional `Bool`),
    /// so unlike `idleMs`/`autoFollowMs` it never omits; the per-window `window.list` copy is nil/omitted
    /// only for a closed window.
    public let sidebarVisible: Bool?
    /// The projected window's sidebar VIEW mode — `SidebarMode.rawValue` (`tree` = the workspace tree,
    /// `flagged` = the flat flagged working-set list). LIVE and always populated on an app-produced `tree`
    /// response; the type stays optional at the protocol level (like the other `tree` fields) for
    /// forward-compat with version skew. The read side of the write-only `sidebar.mode` command, so a script can record the
    /// mode and restore it. `tree`-only (not on `window.list`), since a GUI-only flagged-view toggle would
    /// leave a cached copy stale — read the live tree copy instead.
    public let sidebarMode: String?
    /// Whether the projected window's quick terminal is currently visible. LIVE — resolved app-side per
    /// request from the window's `QuickTerminalController` — so a script can make the `quick` toggle
    /// idempotent (show only when hidden). The read side of the write-only `quick` command. `tree`-only
    /// (not on `window.list`), since a GUI-only ⌃` toggle bypasses the command path and would leave a
    /// cached copy stale — read the live tree copy instead. nil in a host-produced tree with no app closure.
    public let quickVisible: Bool?
    /// The control id of the surface terminal zoom currently fills the projected window with —
    /// `surface:<session-id>:<kind>` for a session surface, `quick` for the quick terminal — or
    /// nil/omitted when nothing is zoomed. LIVE — resolved app-side per request from the window's
    /// `TerminalZoomController` — the read side of the write-only `surface.zoom` command, so a script
    /// can check "is it already zoomed" and record-then-restore. `tree`-only (not on `window.list`),
    /// like `quickVisible`: the GUI toggle bypasses the command path and would leave a cached copy stale.
    public let zoomedSurface: String?
    /// The pane refs (`<session-uuid>:left` for a primary pane, `<session-uuid>:right` for a split pane, in
    /// grid order) of the cells the open dashboard shows, or nil/omitted when no dashboard is open. Each cell
    /// is a session+pane, so a split session appears as TWO refs (`:left` and `:right`). LIVE — resolved
    /// app-side per request from the projected window's `DashboardController` — the read side of the
    /// write-only `dashboard` command, so a script can see which panes are on the grid. `tree`-only (not on
    /// `window.list`), like `zoomedSurface`: the keyboard-driven dashboard bypasses the command path and
    /// would leave a cached copy stale. nil in a host-produced tree with no app closure.
    public let dashboardMembers: [String]?
    /// The pane ref (`<session-uuid>:left`/`:right`) of the dashboard's currently highlighted cell (the one
    /// Enter jumps into, focusing that exact pane), or nil/omitted when no dashboard is open. LIVE — resolved
    /// app-side per request from the window's `DashboardController` — the read side of the keyboard highlight
    /// nav. `tree`-only, like `dashboardMembers`.
    public let dashboardHighlighted: String?
    /// The absolute font size in points applied to the dashboard cells, or nil/omitted when no dashboard is
    /// open OR the font is untouched (the members keep their own size). LIVE — resolved app-side per request
    /// from the window's `DashboardController` — the read side of `dashboard --font-size`/`--auto-size`.
    /// `tree`-only, like `dashboardMembers`.
    public let dashboardFontSize: Double?
    /// The dashboard's font mode — `auto` (`--auto-size`), `fixed` (`--font-size`), or `untouched` — or
    /// nil/omitted when no dashboard is open. LIVE — resolved app-side per request from the window's
    /// `DashboardController` — the read side of the font flags. `tree`-only, like `dashboardMembers`.
    public let dashboardFontMode: String?

    public init(workspaces: [ControlWorkspaceNode], idleMs: Int? = nil, autoFollowMs: Int? = nil,
                sidebarVisible: Bool? = nil, sidebarMode: String? = nil, quickVisible: Bool? = nil,
                zoomedSurface: String? = nil, dashboardMembers: [String]? = nil,
                dashboardHighlighted: String? = nil, dashboardFontSize: Double? = nil,
                dashboardFontMode: String? = nil) {
        self.workspaces = workspaces
        self.idleMs = idleMs
        self.autoFollowMs = autoFollowMs
        self.sidebarVisible = sidebarVisible
        self.sidebarMode = sidebarMode
        self.quickVisible = quickVisible
        self.zoomedSurface = zoomedSurface
        self.dashboardMembers = dashboardMembers
        self.dashboardHighlighted = dashboardHighlighted
        self.dashboardFontSize = dashboardFontSize
        self.dashboardFontMode = dashboardFontMode
    }
}

/// An open window's on-screen frame, in the SAME coordinate system `window.move`/`window.resize` accept,
/// so a read-then-restore round-trips: `x`/`y` are the top-left relative to `display`'s top-left (y down),
/// `width`/`height` the frame size in points, `display` the index into the screen list. The read side of
/// the write-only `window.move`/`window.resize`.
public struct ControlWindowFrame: Codable, Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let display: Int

    public init(x: Int, y: Int, width: Int, height: Int, display: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.display = display
    }
}

/// A window as projected into the `window.list` response. `open` is whether its on-screen window is
/// up; `active` is whether it is the frontmost window.
public struct ControlWindowNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let open: Bool
    public let active: Bool
    /// The window's auto-follow-blocked timeout in milliseconds, or nil when disabled (omitted from the
    /// JSON), as of the last cache refresh — `window.list` is answered from a nonisolated fast path, so a
    /// just-changed setting may lag until the next command. Acceptable because the config rarely changes;
    /// the live `idleMs` is deliberately kept off `window.list` (tree-only) for exactly this reason.
    public let autoFollowMs: Int?
    /// Whether this window's sidebar is currently visible, or nil for a CLOSED window with no live store
    /// (omitted from the JSON) — read from the open window's store, mirroring `autoFollowMs`. The read side
    /// of the write-only `sidebar` command, per window.
    public let sidebarVisible: Bool?
    /// The window's current on-screen frame (position + size + display), or nil for a CLOSED window with no
    /// live NSWindow (omitted from the JSON). The read side of `window.move`/`window.resize` — record it,
    /// resize/move the window, then restore the exact frame. Read live app-side; it rides the window cache,
    /// which is refreshed on window move/resize/zoom/fullscreen (`ControlServer` observes the NSWindow
    /// notifications), so a hand-drag or GUI toggle is reflected without needing another command.
    public let geometry: ControlWindowFrame?
    /// Whether the window is in native macOS full screen, or nil for a CLOSED window (omitted from the
    /// JSON). The read side of the write-only `window.fullscreen` toggle, so a script can make the toggle
    /// idempotent (only enter/exit when needed). Read live app-side; like `geometry` it rides the cache.
    public let fullscreen: Bool?
    /// Whether the window is zoomed (maximized-to-screen, NOT full screen), or nil for a CLOSED window
    /// (omitted from the JSON). The read side of the write-only `window.zoom` toggle. Read live app-side.
    public let zoomed: Bool?

    public init(id: String, name: String, open: Bool, active: Bool, autoFollowMs: Int? = nil,
                sidebarVisible: Bool? = nil, geometry: ControlWindowFrame? = nil,
                fullscreen: Bool? = nil, zoomed: Bool? = nil) {
        self.id = id
        self.name = name
        self.open = open
        self.active = active
        self.autoFollowMs = autoFollowMs
        self.sidebarVisible = sidebarVisible
        self.geometry = geometry
        self.fullscreen = fullscreen
        self.zoomed = zoomed
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
    /// Number of sessions actually changed by a batch mutation (`session.close` or `session.move`).
    /// Kept separate from `count`, whose CLI rendering is specific to diagnostics/search results.
    public var affected: Int?
    /// The current/affected theme name for `theme.set` (echo) and `theme.list` (current); nil =
    /// ghostty's built-in colors ("default ghostty"), distinct from the seeded `agterm` app default.
    public var theme: String?
    /// The available bundled theme names for `theme.list`.
    public var themes: [String]?
    /// The applied (clamped) left-pane split fraction echoed by `session.resize`, so a script can see
    /// where the divider landed after clamping / a relative nudge.
    public var ratio: Double?
    /// The light/dark theme syncing state for `theme.set`/`theme.list`, derived from the stored theme
    /// value: `sync` = whether it is ghostty's dual `light:,dark:` form (the terminal tracks the macOS
    /// appearance), `light`/`dark` = its sides. While syncing, `theme` is absent — the state rides
    /// these three; otherwise `theme` is the plain single theme and `light`/`dark` are absent.
    public var sync: Bool?
    public var light: String?
    public var dark: String?

    public init(id: String? = nil, tree: ControlTree? = nil, text: String? = nil,
                windows: [ControlWindowNode]? = nil, exitCode: Int? = nil, count: Int? = nil,
                affected: Int? = nil,
                theme: String? = nil, themes: [String]? = nil, ratio: Double? = nil,
                sync: Bool? = nil, light: String? = nil, dark: String? = nil) {
        self.id = id
        self.tree = tree
        self.text = text
        self.windows = windows
        self.exitCode = exitCode
        self.count = count
        self.affected = affected
        self.theme = theme
        self.themes = themes
        self.ratio = ratio
        self.sync = sync
        self.light = light
        self.dark = dark
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
