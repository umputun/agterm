/// A control command name, the `cmd` field of a `ControlRequest`. Raw values are the wire strings the CLI
/// and the socket server share; an unknown one fails to decode into an "unknown command" error, not a crash.
public enum Command: String, Codable, Sendable {
    case tree
    case eventsRead = "events.read"
    case workspaceNew = "workspace.new"
    case workspaceRename = "workspace.rename"
    case workspaceDelete = "workspace.delete"
    case workspaceSelect = "workspace.select"
    case workspaceGo = "workspace.go"
    case sessionNew = "session.new"
    case sessionDuplicate = "session.duplicate"
    case sessionClose = "session.close"
    case sessionSelect = "session.select"
    case sessionGo = "session.go"
    case sessionRename = "session.rename"
    case sessionReveal = "session.reveal"
    case sessionMove = "session.move"
    case workspaceMove = "workspace.move"
    case workspaceFocus = "workspace.focus"
    case workspaceFilter = "workspace.filter"
    case workspaceCollapse = "workspace.collapse"
    case workspaceExpand = "workspace.expand"
    case sessionType = "session.type"
    case sessionStatus = "session.status"
    case sessionFlag = "session.flag"
    case sessionSeen = "session.seen"
    case sessionRestore = "session.restore"
    case sessionBackground = "session.background"
    case sessionSplit = "session.split"
    case sessionSplitClose = "session.split.close"
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
    case sessionOverlayCopy = "session.overlay.copy"
    case sessionOverlayText = "session.overlay.text"
    case sessionHudOpen = "session.hud.open"
    case sessionHudUpdate = "session.hud.update"
    case sessionHudClose = "session.hud.close"
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
    case windowMinimize = "window.minimize"
    case keymapReload = "keymap.reload"
    case keymapList = "keymap.list"
    case configReload = "config.reload"
    case themeSet = "theme.set"
    case themeList = "theme.list"
    case pickOpen = "pick.open"
    case pickResult = "pick.result"
    case pickCancel = "pick.cancel"
    case restoreClear = "restore.clear"
    /// UI-TEST-ONLY: forces the app-level appearance (`light`|`dark` via `args.name`) so an XCUITest can
    /// simulate a macOS light/dark flip; with NO name it READS the side the last config feed applied, so a
    /// test can assert the flip drove the reload. Refused outside an XCUITest launch, and EXEMPT from the
    /// four-point keep-in-sync: no CLI subcommand, absent from the catalog/skill.
    case debugAppearance = "debug.appearance"
}

/// A bag of optional command parameters. Each command reads only the fields it needs; the rest stay nil and
/// are omitted from the JSON.
public struct ControlArgs: Codable, Sendable, Equatable {
    /// New name for `workspace.new`/`workspace.rename`/`session.rename`; the initial `session.new` name
    /// (blank/omitted leaves the auto basename); the `theme.set` theme (omitted/empty = ghostty's built-in
    /// colors / "default ghostty", NOT the seeded `agterm` app default).
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
    /// For `workspace.new`: create the workspace already COLLAPSED (the CLI's `--collapsed`), so a script can
    /// fill it with `session.new --no-select` without it opening. Omitted/`false` = expanded; read back as
    /// the `tree` workspace node's `collapsed`.
    public var collapsed: Bool?
    /// For `window.new`: create the window already MINIMIZED to the Dock (the CLI's `--minimized`), so a
    /// script can build project windows without each flashing on screen and stealing focus; omitted/`false`
    /// presents it. Read back as the `window.list` node's `minimized`. The new window also hands frontmost
    /// to a still-visible one, so untargeted commands do not route into the Dock.
    public var minimized: Bool?
    /// For `session.new`: create in the background without selecting or focusing (the CLI's `--no-select`);
    /// omitted/`false` keeps select-and-focus. Read back via the `tree` `active` flag — the new node is not it.
    public var noSelect: Bool?
    /// Text to inject for `session.type` / `quick.type`; the search needle for `session.search`.
    public var text: String?
    /// Whether `session.type` may select the session first when its surface is not ready (main pane only).
    /// Realization itself no longer depends on it: the main pane polls with or without `select`.
    public var select: Bool?
    /// Mode for `session.split` (`on|off|toggle`), `quick`/`surface.zoom` (`show|hide|toggle`),
    /// `session.flag` (`on|off|toggle|clear`), `sidebar.mode` (`tree|flagged|toggle`),
    /// `workspace.focus` (`on|off|toggle|add`), `workspace.filter`/`window.minimize` (`on|off|toggle`),
    /// `session.background` (`image|text|color|clear`), and `session.restore` (`set|none|clear` — pin
    /// `command`, pin nothing, or drop the pin).
    public var mode: String?
    /// Optional divider direction for `session.split`: `vertical` (left/right) or `horizontal` (top/bottom).
    /// Omitted preserves the original axis-agnostic show/hide behavior.
    public var axis: String?
    /// The image file path for `session.background` mode `image` (PNG or JPEG).
    public var path: String?
    /// The `#rrggbb` color for `session.background`: the mode-`text` tint (nil = terminal foreground) or the
    /// mode-`color` solid background (required, no opacity — it honors the Settings window translucency).
    /// Also `session.overlay.open`'s own background, independent of the session's (nil = the default theme
    /// background, same translucency), `session.hud.open`'s panel background (same rules; `session.hud.update`
    /// cannot change it — the surface reads it once at creation, so an update IGNORES this field and the live
    /// panel's color survives into the read-back), and `session.status`'s per-call glyph tint,
    /// riding the ephemeral indicator so it lasts only to the next `session.status` without a color
    /// (nil = the Settings color).
    public var color: String?
    /// The `#rrggbb` color of the HUD panel's TEXT for `session.hud.open`/`.update`; nil = the terminal
    /// foreground. Separate from `color` because a HUD sets both halves independently, and unlike `color` an
    /// UPDATE honors it: it rides the body file's header the helper re-reads, so the live panel recolors in
    /// place.
    public var textColor: String?
    /// The per-call glyph-SILHOUETTE override for `session.status`: a `StatusShape` raw value
    /// (`circle|square|triangle|diamond|capsule|star`), dispatcher-validated. Rides the ephemeral indicator,
    /// lasting until the next `session.status` without a shape; nil = the Settings shape, else a circle.
    public var shape: String?
    /// The `background-image-opacity` for `session.background` (image + text), 0...1; nil = ghostty's 1.0.
    public var opacity: Double?
    /// The `background-image-fit` for `session.background` (`contain|cover|stretch|none`); nil = `contain`.
    public var fit: String?
    /// The `background-image-position` for `session.background` (`center` + 8 anchors); nil = `center`. Also
    /// the HUD panel's placement in the pane for `session.hud.open`/`.update` — a `HudPosition` raw value
    /// over the same nine anchors, nil = `center`. `HudPosition` additionally accepts the bare `top`/`bottom`
    /// it shipped with, normalizing them to the middle column; the read-back reports the canonical name
    /// either way.
    public var position: String?
    /// The `background-image-repeat` flag for `session.background`; nil = false.
    public var repeats: Bool?
    /// Which split pane to focus for `session.focus` (`left`|`right`|`other`, `other` toggles); to read for
    /// `session.text` (`left`|`right`, omitted = the focused pane, no `other`); `session.type` injects into
    /// (`left`|`right`, omitted = left/main); set `session.status` (`left`|`right`|`scratch`, omitted =
    /// `left`/main, parsed to `StatusPane`); and `session.restore` pins (same `StatusPane` spelling, omitted
    /// = `left`/main, `scratch` rejected app-side).
    ///
    /// The `session.overlay.*` family (`.open`/`.close`/`.result`/`.copy`/`.text`) scopes to ONE pane with
    /// it, parsed to `OverlayPane`, which
    /// takes the `TerminalZoomSurface` spellings minus `scratch` (`left`/`primary`, `right`/`split`);
    /// `scratch` is rejected, there being no scratch pane to cover, and the rejection names only
    /// `left or right` as guidance. Omitted keeps the session-wide overlay, so every existing caller is
    /// unaffected. A pane overlay is always full-pane, so
    /// `--pane` conflicts with `session.overlay.open --size-percent` and `session.overlay.resize` refuses it.
    public var pane: String?
    /// A surface's STABLE spawn token for `session.status --pane-id`/`session.restore --pane-id` (the shell's
    /// baked `AGTERM_PANE_ID`, forwarded by the agent-status hook). Resolving it against the session's live
    /// surfaces OVERRIDES the stale role `pane`, so a status from a promoted-then-re-split pane lands on the
    /// CURRENT slot; empty/unknown falls back to `pane`. Opaque — validated only by resolving.
    /// `session.restore` diverges: an unresolvable token with NO explicit `pane` errors there rather than
    /// silently using `left`, since a wrong restore pin persists. See `Session.paneRole(forToken:)`, #199.
    public var paneID: String?
    /// Absolute primary-pane split fraction (0...1) for `session.resize`, clamped server-side to
    /// `AppStore.splitRatioMin...splitRatioMax`. Mutually exclusive with `ratioDelta`.
    public var ratio: Double?
    /// Signed relative split-divider nudge for `session.resize`: a positive fraction grows the PRIMARY
    /// pane, negative grows the split pane. Applied to the session's
    /// current fraction (0.5 when never moved). Mutually exclusive with `ratio`.
    public var ratioDelta: Double?
    /// For `session.text` / `quick.text`: read the full screen + scrollback instead of just the visible screen.
    public var all: Bool?
    /// For `session.text` / `quick.text`: keep only the last N lines of the full buffer.
    public var lines: Int?
    /// Direction for `session.go` (`next`|`prev`|`previous`|`first`|`last`), for `workspace.go`
    /// (`next`|`prev`|`previous` — a workspace has no attention state and no ends to jump to), for the
    /// reorder form of `session.move` / `workspace.move` (`up`|`down`|`top`|`bottom`), and for
    /// `session.search` (`next`|`prev`|`close`).
    public var to: String?
    /// Anchor session (id / unique prefix / `active`) to place a session right AFTER, for the placement form
    /// of `session.new`/`session.move`. The anchor carries its own workspace (resolved across the whole
    /// store), so it names the destination — mutually exclusive with `to`, `before`, and the workspace param.
    public var after: String?
    /// Anchor session to place a session right BEFORE, the mirror of `after` (mutually exclusive with it).
    public var before: String?
    /// App-run UUID paired with `after` for `events.read`. Both fields are omitted for a bootstrap read.
    public var run: String?
    /// Raw event-kind filters for `events.read`. Validation happens in the dispatcher so unknown future
    /// kinds produce a normal control error rather than making the request undecodable.
    public var kinds: [String]?
    /// Maximum matching events returned by `events.read`; omitted uses the dispatcher default.
    public var limit: Int?
    /// The desktop-notification title for `notify` (optional; defaults to the target session's name).
    public var title: String?
    /// The desktop-notification body for `notify` (required).
    public var body: String?
    /// The program the overlay terminal runs for `session.overlay.open` (e.g. `revdiff`); also the shell
    /// line `session.restore` pins for the next launch (mode `set` only, typed verbatim — never re-quoted).
    public var command: String?
    /// Whether a command surface keeps its "press any key to close" prompt after the command exits instead of
    /// closing: `session.overlay.open --wait`, and `session.new --command … --wait` (the primary session
    /// surface, held via `Session.commandWait`).
    public var wait: Bool?
    /// For `session.overlay.open`, the percent of the pane (1...100) a *floating* overlay panel occupies in
    /// both dimensions; omitted gives the default full-pane overlay. Also the new size for
    /// `session.overlay.resize` (mutually exclusive with `full`), and the caller's OVERRIDE of the HUD panel's
    /// app-measured WIDTH for `session.hud.open`/`.update` — a HUD is always floating, so omitting it sizes the
    /// panel from the message rather than covering the pane, and its height is measured either way.
    public var sizePercent: Int?
    /// For `session.overlay.resize`, requests the full-pane (translucent, session-hidden) overlay — the way
    /// to switch a floating overlay back to full. Mutually exclusive with `sizePercent`.
    public var full: Bool?
    /// For `session.overlay.open`, whether to select the target after opening; omitted/false opens in the
    /// background without changing the active session (the default for full and floating overlays alike).
    public var follow: Bool?
    /// The HUD panel's headline for `session.hud.open`/`.update` — required and non-empty on both, since an
    /// update with nothing to say is a close. Wrapped app-side; control characters are rejected.
    ///
    /// Separate from `title`/`body`, which `notify` owns: those two are a desktop notification's fields,
    /// where the title is OPTIONAL and defaults to the session name and the body is the required one.
    /// A HUD inverts that, so sharing them would make each field's contract read "required here, optional
    /// there" — unlike `color`, `position` and `sizePercent`, whose contracts a HUD takes unchanged.
    public var message: String?
    /// The HUD panel's dim second line, wrapped below the message; nil/omitted leaves the panel one block.
    public var detail: String?
    /// The HUD panel's spinner STYLE, a `HudSpinner` raw value; nil/omitted = static, no glyph. The CLI's
    /// bare `--spinner` resolves to `HudSpinner.defaultStyle` before it gets here, so this always names a
    /// style or nothing and the dispatcher has one thing to validate.
    /// The box reserves the glyph's cells either way, so toggling it cannot rewrap the message.
    public var spinner: String?
    /// The finished caller-provided choices for `pick.open`.
    public var items: [ControlPickItem]?
    /// Optional placeholder text for `pick.open`'s query field.
    public var prompt: String?
    /// Initial text in `pick.open`'s query field; a non-empty value opens the picker already filtered.
    public var query: String?
    /// Whether `pick.open` accepts the current query as a custom result.
    public var allowCustom: Bool?
    /// Target window whose tree a session/workspace/tree/font command operates on: id / prefix / `active`
    /// (= frontmost).
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
    /// One-shot sound for `session.status` (caller-driven, not stored on the indicator): `default`/`beep`
    /// = the system alert, anything else a named `NSSound(named:)` sound (e.g. `Glass`, also resolving
    /// custom `~/Library/Sounds`). nil/empty = none; the Settings "Blocked sound" may still play on `blocked`.
    public var sound: String?
    /// Per-slot theme names for `theme.set`: `light` is the light/single slot (an alias for the positional
    /// `name`, so passing both errors); `dark` sets the dark slot, whose presence makes the app track the
    /// macOS appearance (stored as ghostty's dual `light:,dark:` form); `none` clears it. Bundled names only.
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
    /// `targets`/`close`, composes with the font flags; resolved app-side, which needs the store's recency.
    public var mru: Bool?

    public init(name: String? = nil, cwd: String? = nil, targets: [String]? = nil,
                workspace: String? = nil, workspaceName: String? = nil,
                createWorkspace: Bool? = nil, collapsed: Bool? = nil, minimized: Bool? = nil,
                noSelect: Bool? = nil,
                text: String? = nil, select: Bool? = nil, mode: String? = nil, axis: String? = nil,
                command: String? = nil, wait: Bool? = nil, sizePercent: Int? = nil, full: Bool? = nil,
                follow: Bool? = nil, message: String? = nil, detail: String? = nil, spinner: String? = nil,
                items: [ControlPickItem]? = nil, prompt: String? = nil,
                query: String? = nil, allowCustom: Bool? = nil, window: String? = nil,
                pane: String? = nil, paneID: String? = nil, to: String? = nil,
                after: String? = nil, before: String? = nil, run: String? = nil,
                kinds: [String]? = nil, limit: Int? = nil,
                title: String? = nil, body: String? = nil,
                width: Int? = nil, height: Int? = nil, x: Int? = nil, y: Int? = nil, display: Int? = nil,
                status: String? = nil, blink: Bool? = nil, autoReset: Bool? = nil, sound: String? = nil,
                ratio: Double? = nil, ratioDelta: Double? = nil,
                path: String? = nil, color: String? = nil, textColor: String? = nil, shape: String? = nil,
                opacity: Double? = nil, fit: String? = nil,
                position: String? = nil, repeats: Bool? = nil, all: Bool? = nil, lines: Int? = nil,
                light: String? = nil, dark: String? = nil,
                close: Bool? = nil, fontSize: Double? = nil, autoSize: Bool? = nil, mru: Bool? = nil) {
        self.name = name
        self.cwd = cwd
        self.targets = targets
        self.workspace = workspace
        self.workspaceName = workspaceName
        self.createWorkspace = createWorkspace
        self.collapsed = collapsed
        self.minimized = minimized
        self.noSelect = noSelect
        self.text = text
        self.select = select
        self.mode = mode
        self.axis = axis
        self.command = command
        self.wait = wait
        self.sizePercent = sizePercent
        self.full = full
        self.follow = follow
        self.message = message
        self.detail = detail
        self.spinner = spinner
        self.items = items
        self.prompt = prompt
        self.query = query
        self.allowCustom = allowCustom
        self.window = window
        self.pane = pane
        self.paneID = paneID
        self.to = to
        self.after = after
        self.before = before
        self.run = run
        self.kinds = kinds
        self.limit = limit
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
        self.textColor = textColor
        self.shape = shape
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

/// 1 MiB cap on a request line (newline excluded), far above any realistic `session.type` payload. Over it
/// the server rejects the line and closes the connection, so a bad client can't grow the buffer unbounded;
/// the client checks the same cap before writing, so an oversized request fails with a readable error
/// instead of a write to a closing peer. Shared so the two sides cannot drift.
public enum ControlWire {
    public static let maxRequestLineBytes = 1 << 20
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

/// A terminal surface as projected into the `tree` response. `id` is the stable control address for
/// `surface.zoom`; `kind` the user-facing name (`left`, `right`, `scratch`, `overlay`). `active`/`visible`
/// derive from the session's own flags (overlay/scratch/splitFocused), NOT from terminal zoom, and `visible`
/// reads false for a pane behind a FLOATING overlay though it is visually on screen (any open overlay counts
/// as covering). Address by `id`/`kind`, not these flags; the zoom state is the top-level `zoomedSurface`.
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

/// The HUD panel occupying a session's overlay slot, as projected into the `tree` response. Present only
/// while a HUD is up, and the session node's `overlay` reads FALSE beside it, so a script polling "is a
/// program covering this session" can never mistake a message for a running program. The read side of
/// `session.hud.open`/`.update`; HUD state is poll-only, no event announces it.
public struct ControlHudNode: Codable, Sendable, Equatable {
    public let message: String
    /// The dim second line; nil/omitted when the caller set none.
    public let detail: String?
    /// The EFFECTIVE spinner style, a `HudSpinner` raw value or `HudSpinner.noneName`. Always present, the
    /// static case included, so a caller reads one field rather than inferring absence.
    public let spinner: String
    /// The panel's own `#rrggbb` background; nil/omitted when it keeps the session's terminal background. The
    /// color the open set, which survives every `session.hud.update` — the surface reads it once at creation,
    /// so this always names what the panel paints.
    public let backgroundColor: String?
    /// The panel's `#rrggbb` TEXT color; nil/omitted when it keeps the terminal foreground. Unlike
    /// `backgroundColor` this tracks the LATEST `session.hud.update`, the header the helper re-reads being
    /// what paints it.
    public let textColor: String?
    /// The EFFECTIVE share of the pane's WIDTH the panel occupies — the app's measurement, or the caller's
    /// `sizePercent` override, either way bounded by `HudLayout.clampSizePercent`, so a requested 100 reads
    /// back as the maximum a HUD may take. Reported here because the node's `overlaySizePercent` stays
    /// omitted for a HUD. Optional because it projects the slot's optional percent, but no supported path
    /// leaves a live HUD sizeless: `openHud` always sets one and `overlay.resize --full` is refused.
    public let sizePercent: Int?
    /// The EFFECTIVE share of the pane's HEIGHT, always measured from the message (`HudLayout.heightPercent`)
    /// because no command sets it. Reported beside `sizePercent` so a caller polling the panel's geometry
    /// reads both axes rather than assuming one square.
    public let heightPercent: Int?
    /// The EFFECTIVE placement, a CANONICAL `HudPosition` raw value — one of the nine anchors, never one of
    /// the accepted `top`/`bottom` aliases, so a caller reads one spelling whichever he sent. Always present,
    /// including the `center` default, so a caller who omitted it never has to know what the default is.
    public let position: String

    public init(message: String, detail: String? = nil, spinner: String = HudSpinner.noneName,
                backgroundColor: String? = nil, textColor: String? = nil,
                sizePercent: Int? = nil, heightPercent: Int? = nil, position: String) {
        self.message = message
        self.detail = detail
        self.spinner = spinner
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.sizePercent = sizePercent
        self.heightPercent = heightPercent
        self.position = position
    }
}

/// A session as projected into the `tree` response.
public struct ControlSessionNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let cwd: String
    /// The raw terminal title from the latest OSC 0/1/2 (a remote host over SSH, a shell `PROMPT_COMMAND`);
    /// nil/omitted when none reported. The unprocessed `Session.oscTitle`, distinct from `name` (the derived
    /// sidebar label, which uses it as one fallback); a remote session's local `cwd` goes stale, this does not.
    public let title: String?
    public let active: Bool
    /// Whether the split is SHOWN side by side, the read side of `session.split on|off`. A split hidden with
    /// ⌘D reports `false` while its pane stays alive, so a caller asking "is there a second pane" must read
    /// `hasSplit`, not this.
    public let split: Bool
    /// Whether the session HAS a split pane at all, shown or hidden; nil/omitted when it has none. Present
    /// exactly when `splitRatio`/`splitFocused` can be, which is what makes those two readable without
    /// second-guessing `split`. The sidebar icon, the dashboard's second cell and Focus Left/Right Pane all
    /// follow this, not `split`.
    public let hasSplit: Bool?
    /// Divider direction for a live split (`vertical`=left/right, `horizontal`=top/bottom); nil without one.
    public let splitAxis: String?
    /// The primary-pane fraction (0.05...0.95) of a session that HAS a split (shown or hidden); nil with no
    /// split OR when the ratio was never explicitly set (via `session.resize` or a divider drag), the divider
    /// then sitting at the default 0.5. The read side of `session.resize`, otherwise echoed only on that call.
    public let splitRatio: Double?
    /// For a session that HAS a split (shown or hidden), which pane holds keyboard focus: `true` = split
    /// (right), `false` = main (left); nil/omitted with no split. The read side of `session.focus`.
    public let splitFocused: Bool?
    /// Whether a caller's PROGRAM occupies the session-wide overlay slot. False while a HUD holds it — the
    /// HUD is a message, not a running program, and it reports itself in `hud` instead.
    public let overlay: Bool
    /// An OPEN overlay's size (`overlay == true`): nil/omitted = FULL-pane, else the floating panel's percent
    /// of the pane (1...100); absent with no overlay AND while a HUD holds the slot, whose size is `hud`'s.
    /// The read side of `session.overlay.resize`.
    public let overlaySizePercent: Int?
    /// The panes covered by their OWN overlay, ordered left then right (`["left"]`, `["right"]`,
    /// `["left","right"]`); nil/omitted when neither has one. Independent of `overlay`, the session-wide
    /// one — both kinds can be up at once. The read side of `session.overlay.open --pane`; those overlays
    /// are always full-pane, so there is no per-pane size to report.
    public let paneOverlays: [String]?
    /// The HUD panel occupying the session-wide overlay slot; nil/omitted when none is up. Mutually exclusive
    /// with `overlay` — one slot, and whichever holds it is the one that reports.
    public let hud: ControlHudNode?
    public let scratch: Bool
    public let flagged: Bool
    /// For a `--command` session, whether it HOLDS its surface after the command exits (`session.new
    /// --command … --wait`) instead of closing; nil/omitted for a plain or non-holding session. The read
    /// side of `session.new --wait`; it persists across restart, unlike an overlay's live-only wait.
    public let commandWait: Bool?
    /// The LIVE foreground process command (full argv) in the main pane; nil/omitted at the shell prompt —
    /// the same capture restore-running-command uses.
    public let foreground: [String]?
    /// The split (right) pane's live foreground command (full argv), the split analogue of `foreground`.
    public let splitForeground: [String]?
    /// The main pane's PERSISTED restore-command override, the read side of `session.restore`. Tri-state:
    /// omitted = no override (auto-capture), `""` = pinned to nothing (a plain shell), a command = that shell
    /// line runs on the next launch. Read from persisted state, so it still reports the pin after the
    /// override fired. Unrelated to `foreground`, the LIVE process.
    public let restoreCommand: String?
    /// The split (right) pane's persisted restore-command override, the split analogue of `restoreCommand`
    /// (the read side of `session.restore --pane right`).
    public let splitRestoreCommand: String?
    /// The session's agent status (`active`/`completed`/`blocked`) as the `AgentStatus` raw value;
    /// nil/omitted when idle. The read side of `session.status`.
    public let status: String?
    /// Which pane set the agent status (`"left"|"right"|"scratch"`, `left`=main, `right`=split); nil/omitted
    /// when idle or unspecified. The read side of `session.status --pane`.
    public let statusPane: String?
    /// Whether the agent-status glyph blinks (pulses for attention); nil/omitted when idle or not blinking.
    /// The read side of `session.status --blink`.
    public let statusBlink: Bool?
    /// The per-call `#rrggbb` glyph-tint override; nil/omitted when idle or using the Settings status color.
    /// The read side of `session.status --color`.
    public let statusColor: String?
    /// The per-call glyph-silhouette override (a `StatusShape` raw value); nil/omitted when idle or drawing
    /// the Settings shape / the default plain circle. The read side of `session.status --shape` — the
    /// PER-CALL override only, exactly like `statusColor`.
    public let statusShape: String?
    /// The session's background watermark spec; nil/omitted when none is set. The read side of
    /// `session.background`.
    public let background: BackgroundWatermark?
    /// The session's unseen-notification badge count; nil/omitted when zero. `notify` (and terminal OSC
    /// 9/777) raise it, `session.seen` clears it. Ephemeral like `status` — never persisted, resets on restart.
    public let unseen: Int?
    /// The default/left pane's live font size in points via `addressableSurface`: the main pane, or the
    /// promoted split survivor once the primary exited (the pane `font --pane left`, and the default, writes);
    /// nil/omitted when unrealized. The live cmd +/- value, persisted for the main pane but live-only for a
    /// promoted survivor.
    public let fontSize: Double?
    /// The split (right) pane's live font size in points; nil/omitted with no realized split pane. The read
    /// side of `font --pane right`, otherwise unobservable — live-only, not persisted.
    public let splitFontSize: Double?
    /// The scratch terminal's live font size in points, or nil when no scratch surface is realized (omitted).
    /// The read side of `font --pane scratch` (also live-only).
    public let scratchFontSize: Double?
    /// Addressable terminal surfaces owned by this session; nil/omitted against a server predating
    /// `surface.zoom`. Hidden-but-alive surfaces are included, so a client can zoom them without unhiding.
    public let surfaces: [ControlSurfaceNode]?
    /// Whether the MAIN pane's terminal exists — the libghostty surface created and its program spawned —
    /// as opposed to the session merely being in the model. False means `session.type`/`session.text` will
    /// report `session not realized` and a `--command` has not run yet. nil/omitted only against a server
    /// predating the field; this one always reports it.
    ///
    /// `session.new` answers `ok` for a model insert, which is honest but says nothing about the terminal:
    /// libghostty refuses to create a surface while the display is asleep, so a session a scheduled job
    /// creates overnight sits unrealized until the displays wake (#416). This is the field that tells them
    /// apart. It reports the main pane because that is what `--command` spawns on and what the input/read
    /// commands address by default; per-pane liveness is `fontSize`/`splitFontSize`/`scratchFontSize`,
    /// each omitted when its pane is unrealized.
    public let realized: Bool?

    public init(id: String, name: String, cwd: String, title: String? = nil, active: Bool, split: Bool,
                hasSplit: Bool? = nil, splitAxis: String? = nil,
                splitRatio: Double? = nil, splitFocused: Bool? = nil,
                overlay: Bool = false, overlaySizePercent: Int? = nil, paneOverlays: [String]? = nil,
                hud: ControlHudNode? = nil, scratch: Bool = false, flagged: Bool = false,
                commandWait: Bool? = nil,
                foreground: [String]? = nil, splitForeground: [String]? = nil,
                restoreCommand: String? = nil, splitRestoreCommand: String? = nil, status: String? = nil,
                statusPane: String? = nil, statusBlink: Bool? = nil, statusColor: String? = nil,
                statusShape: String? = nil,
                background: BackgroundWatermark? = nil, unseen: Int? = nil,
                fontSize: Double? = nil, splitFontSize: Double? = nil, scratchFontSize: Double? = nil,
                surfaces: [ControlSurfaceNode]? = nil, realized: Bool? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.title = title
        self.active = active
        self.split = split
        self.hasSplit = hasSplit
        self.splitAxis = splitAxis
        self.splitRatio = splitRatio
        self.splitFocused = splitFocused
        self.overlay = overlay
        self.overlaySizePercent = overlaySizePercent
        self.paneOverlays = paneOverlays
        self.hud = hud
        self.scratch = scratch
        self.flagged = flagged
        self.commandWait = commandWait
        self.foreground = foreground
        self.splitForeground = splitForeground
        self.restoreCommand = restoreCommand
        self.splitRestoreCommand = splitRestoreCommand
        self.status = status
        self.statusPane = statusPane
        self.statusBlink = statusBlink
        self.statusColor = statusColor
        self.statusShape = statusShape
        self.background = background
        self.unseen = unseen
        self.fontSize = fontSize
        self.splitFontSize = splitFontSize
        self.scratchFontSize = scratchFontSize
        self.surfaces = surfaces
        self.realized = realized
    }
}

/// A workspace and its sessions as projected into the `tree` response.
public struct ControlWorkspaceNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let active: Bool
    /// Whether this workspace is a MEMBER of the sidebar's focus set; nil/omitted when not. Reported
    /// INDEPENDENTLY of whether the filter is applied (that flag is the tree top-level `workspaceFilter`), so
    /// a marked-but-not-filtering set reads back. Distinct from `active` (the CURRENT workspace — what
    /// `--target active` resolves to, which an empty or foreground-created destination makes current while
    /// the selected session stays behind in another one). The read
    /// side of the write-only `workspace.focus`/`workspace.filter`.
    ///
    /// A workspace ROW is VISIBLE iff `tree.sidebarVisible && tree.sidebarMode == "tree" &&
    /// (!tree.workspaceFilter || focused)`, every term on the same `tree` response — no second call needed.
    /// Both shorter forms are wrong: `focused && workspaceFilter` reports nothing visible while the filter is
    /// off, and a bare `!workspaceFilter || focused` reports rows behind a hidden sidebar and in `"flagged"`
    /// mode, which renders a FLAT flagged-session list with NO workspace rows whatever membership says. The
    /// filter-ON term is exact because enabled-with-an-empty-set is unrepresentable (enabling an empty set is
    /// refused; restore prunes stale ids then disables when it empties), so an applied filter always has at
    /// least one visible member.
    public let focused: Bool?
    /// Whether this workspace is COLLAPSED in the sidebar tree; nil when expanded (the default), so an
    /// all-expanded tree omits it, matching the persisted `WorkspaceSnapshot.collapsed`. The read side of
    /// `workspace.collapse`/`workspace.expand` and `workspace.new --collapsed`. Reports the persisted
    /// `!isExpanded`, independent of a transient focus force-reveal.
    public let collapsed: Bool?
    public let sessions: [ControlSessionNode]

    public init(id: String, name: String, active: Bool, focused: Bool? = nil,
                collapsed: Bool? = nil, sessions: [ControlSessionNode]) {
        self.id = id
        self.name = name
        self.active = active
        self.focused = focused
        self.collapsed = collapsed
        self.sessions = sessions
    }
}

/// The whole workspace tree, the payload of a `tree` response.
public struct ControlTree: Codable, Sendable, Equatable {
    public let workspaces: [ControlWorkspaceNode]
    /// Milliseconds since the last user input in the projected window; nil/omitted before any activity. A
    /// LIVE, continuously-growing delta — `tree`-only, since the tree is built fresh per request on the main
    /// actor while cache-served `window.list` would freeze it between commands. The auto-follow idle metric.
    public let idleMs: Int?
    /// The window's auto-follow-blocked timeout in milliseconds, or nil when the feature is disabled
    /// (omitted from the JSON). The read side of the GUI-only Auto-follow setting.
    public let autoFollowMs: Int?
    /// Whether the projected window's sidebar is visible. LIVE, built fresh from the window's store per
    /// request — the read side of the write-only `sidebar` command. Always present on a `tree` response (the
    /// producer passes a non-optional `Bool`), unlike `idleMs`/`autoFollowMs`; the `window.list` copy omits
    /// it for a closed window.
    public let sidebarVisible: Bool?
    /// The projected window's sidebar VIEW mode — `SidebarMode.rawValue` (`tree` = the workspace tree,
    /// `flagged` = the flat flagged working-set list). LIVE and always populated on an app-produced `tree`;
    /// optional at the protocol level (like the other `tree` fields) for version skew. The read side of the
    /// write-only `sidebar.mode`. `tree`-only, as every field below is: a GUI toggle bypasses the command
    /// path, so a cached `window.list` copy would go stale.
    public let sidebarMode: String?
    /// Whether the projected window's workspace focus FILTER is applied — the flag half of the focus set,
    /// whose member half is each workspace node's `focused`. Only ONE term of the row-visibility predicate;
    /// see `focused`. LIVE and `tree`-only (the bottom-bar toggle and the row menu flip it outside the
    /// command path). The read side of the write-only `workspace.filter`. nil in a host-produced tree that
    /// projects no window.
    public let workspaceFilter: Bool?
    /// Whether the projected window's quick terminal is visible. LIVE, resolved app-side per request from the
    /// window's `QuickTerminalController`, so the `quick` toggle can be made idempotent. The read side of the
    /// write-only `quick` command; `tree`-only (the GUI ⌃` toggle). nil in a host-produced tree with no app
    /// closure.
    public let quickVisible: Bool?
    /// The control id of the surface terminal zoom fills the projected window with —
    /// `surface:<session-id>:<kind>`, or `quick` for the quick terminal — nil/omitted when nothing is zoomed.
    /// LIVE, resolved app-side per request from the window's `TerminalZoomController`: the read side of the
    /// write-only `surface.zoom`; `tree`-only.
    public let zoomedSurface: String?
    /// The open dashboard's cells as pane refs in grid order (`<session-uuid>:left` primary,
    /// `<session-uuid>:right` split), so a split session appears as TWO refs; nil/omitted with no dashboard.
    /// LIVE, resolved app-side per request from the projected window's `DashboardController` — the read side
    /// of the write-only `dashboard` command; `tree`-only. nil in a host-produced tree with no app closure.
    public let dashboardMembers: [String]?
    /// The pane ref (`<session-uuid>:left`/`:right`) of the dashboard's highlighted cell — the one Enter jumps
    /// into, focusing that exact pane; nil/omitted with no dashboard. LIVE from the window's
    /// `DashboardController`, the read side of the keyboard highlight nav.
    public let dashboardHighlighted: String?
    /// The absolute font size in points applied to the dashboard cells; nil/omitted with no dashboard OR an
    /// untouched font (the members keep their own size). LIVE from the window's `DashboardController`, the
    /// read side of `dashboard --font-size`/`--auto-size`.
    public let dashboardFontSize: Double?
    /// The dashboard's font mode — `auto` (`--auto-size`), `fixed` (`--font-size`), `untouched`; nil/omitted
    /// with no dashboard. LIVE from the window's `DashboardController`, the read side of the font flags.
    public let dashboardFontMode: String?
    /// The id of the picker currently awaiting a choice, or nil when no picker is open.
    public let pickPending: String?

    public init(workspaces: [ControlWorkspaceNode], idleMs: Int? = nil, autoFollowMs: Int? = nil,
                sidebarVisible: Bool? = nil, sidebarMode: String? = nil, workspaceFilter: Bool? = nil,
                quickVisible: Bool? = nil,
                zoomedSurface: String? = nil, dashboardMembers: [String]? = nil,
                dashboardHighlighted: String? = nil, dashboardFontSize: Double? = nil,
                dashboardFontMode: String? = nil, pickPending: String? = nil) {
        self.workspaces = workspaces
        self.idleMs = idleMs
        self.autoFollowMs = autoFollowMs
        self.sidebarVisible = sidebarVisible
        self.sidebarMode = sidebarMode
        self.workspaceFilter = workspaceFilter
        self.quickVisible = quickVisible
        self.zoomedSurface = zoomedSurface
        self.dashboardMembers = dashboardMembers
        self.dashboardHighlighted = dashboardHighlighted
        self.dashboardFontSize = dashboardFontSize
        self.dashboardFontMode = dashboardFontMode
        self.pickPending = pickPending
    }
}

/// An open window's on-screen frame — the read side of write-only `window.move`/`window.resize`, in the
/// SAME coordinate system those accept so a read-then-restore round-trips: `x`/`y` the top-left relative to
/// `display`'s top-left (y down), `width`/`height` the frame size in points, `display` a screen-list index.
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
    /// The window's auto-follow-blocked timeout in milliseconds; nil/omitted when disabled. As of the last
    /// cache refresh — `window.list` answers from a nonisolated fast path, so a just-changed setting lags
    /// until the next command; the live `idleMs` is kept off `window.list` (tree-only) for that reason.
    public let autoFollowMs: Int?
    /// Whether this window's sidebar is visible; nil/omitted for a CLOSED window with no live store. Read
    /// from the open window's store, mirroring `autoFollowMs`. The read side of `sidebar`, per window.
    public let sidebarVisible: Bool?
    /// The window's on-screen frame (position + size + display); nil/omitted for a CLOSED window with no live
    /// NSWindow. The read side of `window.move`/`window.resize`. Read live app-side on the window cache,
    /// refreshed on move/resize/zoom/fullscreen (`ControlServer` observes the NSWindow notifications), so a
    /// hand-drag or GUI toggle shows up without another command.
    public let geometry: ControlWindowFrame?
    /// Whether the window is in native macOS full screen; nil/omitted for a CLOSED window. The read side of
    /// the write-only `window.fullscreen` toggle, so it can be made idempotent. Read live app-side; like
    /// `geometry` it rides the cache.
    public let fullscreen: Bool?
    /// Whether the window is zoomed (maximized-to-screen, NOT full screen), or nil for a CLOSED window
    /// (omitted from the JSON). The read side of the write-only `window.zoom` toggle. Read live app-side.
    public let zoomed: Bool?
    /// Whether the window is minimized to the Dock; nil/omitted for a CLOSED window. The read side of
    /// `window.minimize`. Live app-side on the cache, refreshed on the NSWindow miniaturize/deminiaturize
    /// notifications so ⌘M or a Dock click shows too. A minimized window still reports its `geometry` (where
    /// it comes back to).
    public let minimized: Bool?

    public init(id: String, name: String, open: Bool, active: Bool, autoFollowMs: Int? = nil,
                sidebarVisible: Bool? = nil, geometry: ControlWindowFrame? = nil,
                fullscreen: Bool? = nil, zoomed: Bool? = nil, minimized: Bool? = nil) {
        self.id = id
        self.name = name
        self.open = open
        self.active = active
        self.autoFollowMs = autoFollowMs
        self.sidebarVisible = sidebarVisible
        self.geometry = geometry
        self.fullscreen = fullscreen
        self.zoomed = zoomed
        self.minimized = minimized
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
    /// A count payload for commands whose result is a number: the keymap-diagnostic count for
    /// `keymap.reload`; the ghostty config-diagnostic count for `config.reload` (across ALL config sources,
    /// not just the agterm-scoped `ghostty.conf` — libghostty diagnostics carry no source-file attribution);
    /// and `session.search`'s total match count (whose "N of M" display string rides in `text`).
    public var count: Int?
    /// Number of sessions actually changed by a batch mutation (`session.close` or `session.move`); separate
    /// from `count`, whose CLI rendering is specific to diagnostics/search results.
    public var affected: Int?
    /// The current/affected theme name for `theme.set` (echo) and `theme.list` (current); nil =
    /// ghostty's built-in colors ("default ghostty"), distinct from the seeded `agterm` app default.
    public var theme: String?
    /// The available bundled theme names for `theme.list`.
    public var themes: [String]?
    /// The applied primary-pane split fraction echoed by `session.resize`, after clamping / a relative nudge.
    public var ratio: Double?
    /// The light/dark syncing state for `theme.set`/`theme.list`, from the stored theme: `sync` = whether it
    /// is ghostty's dual `light:,dark:` form (the terminal tracks the macOS appearance), `light`/`dark` its
    /// sides. While syncing `theme` is absent; otherwise `theme` is the plain single theme, these absent.
    public var sync: Bool?
    public var light: String?
    public var dark: String?
    /// A page from the app-run event ring, present for `events.read` success and cursor errors.
    public var events: ControlEventBatch?
    /// The resolved keymap plus the live menu key equivalents, for `keymap.list`.
    public var keymap: ControlKeymap?
    /// The current or terminal picker outcome for `pick.result`.
    public var pick: ControlPickResult?

    public init(id: String? = nil, tree: ControlTree? = nil, text: String? = nil,
                windows: [ControlWindowNode]? = nil, exitCode: Int? = nil, count: Int? = nil,
                affected: Int? = nil,
                theme: String? = nil, themes: [String]? = nil, ratio: Double? = nil,
                sync: Bool? = nil, light: String? = nil, dark: String? = nil,
                events: ControlEventBatch? = nil, keymap: ControlKeymap? = nil,
                pick: ControlPickResult? = nil) {
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
        self.events = events
        self.keymap = keymap
        self.pick = pick
    }
}

/// Error strings for `session.overlay.result`, shared so the `agtermctl --block` poll matches the
/// server's wording exactly (the poll retries while the overlay is still running, by `error` string).
public enum OverlayResultError {
    public static let stillRunning = "overlay still running"
    public static let noResult = "no overlay result"
}

/// Error strings for `session.overlay.*` aimed at a session whose overlay slot holds a HUD. The slot is
/// shared, so these rejections need the live session and fire in `ControlServer`, not the dispatcher.
/// `session.overlay.close` is deliberately absent: closing a HUD is a courtesy the shared teardown gives.
public enum OverlayHudError {
    /// A HUD runs the app's painter, not the caller's program, so there is no status to report — and
    /// `overlayActive` alone would otherwise answer the misleading "overlay still running".
    public static let noResult = "no overlay result: the slot holds a hud"
    /// A HUD is always floating (`AppStore.openHud`): it must never cover the session it is a message about.
    /// A percent is accepted but bounded by `HudLayout.clampSizePercent`, which states the same invariant.
    public static let fullResize = "a hud is always floating: pass --size-percent, not --full"
    /// `session.hud.update`/`.close` against a slot that holds no HUD — empty, or running a caller's program.
    public static let noHud = "no hud"
    /// `session.overlay.copy`/`.text` against a HUD. The panel paints agterm's own message, so reading it
    /// would hand a caller back the text it wrote rather than a program's output, and the slot being
    /// occupied is not enough to tell the two apart.
    public static let noRead = "no overlay to read: the slot holds a hud"
    /// The body file the helper reads could not be written, so the panel would paint nothing or stale text.
    public static let writeFailed = "could not write the hud message"
}

/// Error strings for the pane-scoped (`--pane`) arm of `session.overlay.*`. Shared because the rejections
/// are split across layers — `alreadyOpen`/`paneNotVisible` need the live session and fire in
/// `ControlServer`, the rest are host-free in `ControlDispatcher` — and the wording must not drift.
public enum PaneOverlayError {
    public static let alreadyOpen = "pane overlay already open"
    public static let paneNotVisible = "pane not visible"
    /// Names the canonical spellings only; `OverlayPane.init?(controlName:)` also takes role/axis aliases.
    public static let invalidPane = "session.overlay: --pane must be left or right"
    public static let sizePercentConflict = "session.overlay.open: --pane is mutually exclusive with --size-percent"
    public static let resizeUnsupported = "session.overlay.resize: --pane is not supported (pane overlays are always full)"
}

/// Advisory text `notify` returns in `result.text` when the banner toggle is off. The command still succeeds
/// (the unseen badge tracks either way) but hands macOS nothing, so a bare `ok` would look identical to a
/// broken notification path (issue #286). Shared so wording and matchers cannot drift.
public enum ControlNotify {
    public static let bannersOffNote = "badge updated, but \"Show notification banners\" is off, so no banner was posted"
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
