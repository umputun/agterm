// The read-back PROJECTIONS: the immutable snapshots `tree` and `window.list` return, distinct from the
// request envelope in `ControlProtocol.swift` and the response envelope in `ControlResponse.swift`.
// Split out for the file size limit.

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
    /// Actual zmx backing for primary/split surfaces; nil for ephemeral surfaces or older servers.
    public let backedByZmx: Bool?

    public init(id: String, kind: String, active: Bool, visible: Bool) {
        self.init(id: id, kind: kind, active: active, visible: visible, backedByZmx: nil)
    }

    public init(id: String, kind: String, active: Bool, visible: Bool, backedByZmx: Bool?) {
        self.id = id
        self.kind = kind
        self.active = active
        self.visible = visible
        self.backedByZmx = backedByZmx
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
    /// True only when every existing primary/split pane is currently zmx-backed; nil on older servers.
    public let backedByZmx: Bool?
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
    /// What the session is FOR, the read side of `session.context`; nil/omitted when none is set. Durable
    /// purpose, so it survives a relaunch and only an explicit `session.context clear` removes it.
    public let context: String?
    /// For a `--command` session, whether it HOLDS its surface after the command exits (`session.new
    /// --command … --wait`) instead of closing; nil/omitted for a plain or non-holding session. The read
    /// side of `session.new --wait`; it persists across restart, unlike an overlay's live-only wait.
    public let commandWait: Bool?
    /// The split pane's hold-after-exit policy; nil/omitted without a holding split creation command.
    public let splitCommandWait: Bool?
    /// The LIVE foreground process command (full argv) in the main pane; nil/omitted when the foreground IS a
    /// recognized shell (`foregroundShell` names it) and whenever the process cannot be read — no foreground
    /// pid, a setuid leader like `top`/`sudo`, an unresolved zmx pane, a failed syscall. Shares the restore
    /// capture's extraction but not its rules: this read descends the process group, the capture does not.
    public let foreground: [String]?
    /// The split (right) pane's live foreground command (full argv), the split analogue of `foreground`.
    public let splitForeground: [String]?
    /// The main pane's foreground process when it IS a recognized shell, as its basename (`zsh`, `fish`);
    /// nil/omitted whenever `foreground` is present. For a pane that exists, neither field means agterm could
    /// not determine the foreground state at all — the two a bare nil `foreground` used to conflate.
    ///
    /// NOT proof of an interactive prompt, so it is never permission to type: a builtin such as `read` or
    /// `vared`, and a shell loop, run inside the shell process, leaving a pane blocked on input
    /// indistinguishable from one at a prompt. Recognized means agterm knows the argv as a shell, by a
    /// built-in set widened with the user's `$SHELL`; a shell outside both reports in `foreground` like any
    /// other program.
    public let foregroundShell: String?
    /// The split (right) pane's foreground shell basename, the split analogue of `foregroundShell`. Read
    /// `hasSplit` before interpreting the split pair: with no split pane both are absent because there is no
    /// pane, not because anything could not be read.
    public let splitForegroundShell: String?
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
    /// When the agent status was last SET, as epoch seconds on the `ControlEvent.ts` clock (so the two
    /// compare directly); nil/omitted when idle. Stamped on EVERY non-idle `session.status`, not only on a
    /// change of state, so a hook re-pushing `active` refreshes it and "now minus this" reads as how long ago
    /// the status was last WRITTEN — normally the agent's own push, though a pane promotion re-tags the
    /// indicator and counts too. Ephemeral like `status` and `unseen` — never persisted.
    public let statusChangedAt: Double?
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

    /// The host a teleported session is attached to; nil/omitted for a local one. Live-only — a remote
    /// session is never persisted, so this never survives a relaunch.
    public let remoteHost: String?

    public init(id: String, name: String, cwd: String, title: String? = nil, active: Bool, split: Bool,
                hasSplit: Bool? = nil, backedByZmx: Bool?, splitAxis: String? = nil,
                splitRatio: Double? = nil, splitFocused: Bool? = nil,
                overlay: Bool = false, overlaySizePercent: Int? = nil, paneOverlays: [String]? = nil,
                hud: ControlHudNode? = nil, scratch: Bool = false, flagged: Bool = false,
                commandWait: Bool? = nil, splitCommandWait: Bool? = nil,
                foreground: [String]? = nil, splitForeground: [String]? = nil,
                foregroundShell: String? = nil, splitForegroundShell: String? = nil,
                restoreCommand: String? = nil, splitRestoreCommand: String? = nil, status: String? = nil,
                statusPane: String? = nil, statusBlink: Bool? = nil, statusColor: String? = nil,
                statusShape: String? = nil, statusChangedAt: Double? = nil,
                background: BackgroundWatermark? = nil, unseen: Int? = nil,
                fontSize: Double? = nil, splitFontSize: Double? = nil, scratchFontSize: Double? = nil,
                surfaces: [ControlSurfaceNode]? = nil, realized: Bool? = nil,
                context: String? = nil, remoteHost: String? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.title = title
        self.active = active
        self.split = split
        self.hasSplit = hasSplit
        self.backedByZmx = backedByZmx
        self.splitAxis = splitAxis
        self.splitRatio = splitRatio
        self.splitFocused = splitFocused
        self.overlay = overlay
        self.overlaySizePercent = overlaySizePercent
        self.paneOverlays = paneOverlays
        self.hud = hud
        self.scratch = scratch
        self.flagged = flagged
        self.context = context
        self.commandWait = commandWait
        self.splitCommandWait = splitCommandWait
        self.foreground = foreground
        self.splitForeground = splitForeground
        self.foregroundShell = foregroundShell
        self.splitForegroundShell = splitForegroundShell
        self.restoreCommand = restoreCommand
        self.splitRestoreCommand = splitRestoreCommand
        self.status = status
        self.statusPane = statusPane
        self.statusBlink = statusBlink
        self.statusColor = statusColor
        self.statusShape = statusShape
        self.statusChangedAt = statusChangedAt
        self.background = background
        self.unseen = unseen
        self.fontSize = fontSize
        self.splitFontSize = splitFontSize
        self.scratchFontSize = scratchFontSize
        self.surfaces = surfaces
        self.realized = realized
        self.remoteHost = remoteHost
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
    /// The projected window's sidebar divider position in points - the read side of `sidebar.width`, and the
    /// only place it is reported. LIVE and `tree`-only, like every field below and like `sidebarMode`: the
    /// tree is the live per-window read surface, and nothing needs width discovery ACROSS windows, which is
    /// the only thing the cached `window.list` copy would add.
    public let sidebarWidth: Double?
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
    /// The app serving this socket. Constant rather than live like every field above it, and present so an
    /// agent already reading the tree gets its version floor without a second round-trip; `version` answers
    /// the same question for a caller that has no tree, no window, and no JSON parser.
    public let app: AppIdentity?

    public init(workspaces: [ControlWorkspaceNode], idleMs: Int? = nil, autoFollowMs: Int? = nil,
                sidebarVisible: Bool? = nil, sidebarMode: String? = nil, sidebarWidth: Double? = nil, workspaceFilter: Bool? = nil,
                quickVisible: Bool? = nil,
                zoomedSurface: String? = nil, dashboardMembers: [String]? = nil,
                dashboardHighlighted: String? = nil, dashboardFontSize: Double? = nil,
                dashboardFontMode: String? = nil, pickPending: String? = nil,
                app: AppIdentity? = nil) {
        self.workspaces = workspaces
        self.idleMs = idleMs
        self.autoFollowMs = autoFollowMs
        self.sidebarVisible = sidebarVisible
        self.sidebarMode = sidebarMode
        self.sidebarWidth = sidebarWidth
        self.workspaceFilter = workspaceFilter
        self.quickVisible = quickVisible
        self.zoomedSurface = zoomedSurface
        self.dashboardMembers = dashboardMembers
        self.dashboardHighlighted = dashboardHighlighted
        self.dashboardFontSize = dashboardFontSize
        self.dashboardFontMode = dashboardFontMode
        self.pickPending = pickPending
        self.app = app
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
