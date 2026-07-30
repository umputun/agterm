import Foundation
import Observation

/// One shell, backed by a single libghostty surface.
///
/// `@MainActor`, so implicitly `Sendable` via isolation — never make it an `actor`. `surface` is
/// `@ObservationIgnored` so assigning the lazy NSView never churns observation; `customName`/`currentCwd`
/// are observed, so the sidebar refreshes on a rename or PWD report. "Ephemeral" below means absent from
/// `SessionSnapshot`, so it never survives a relaunch.
@Observable
@MainActor
public final class Session: Identifiable {
    public let id: UUID
    public var customName: String?
    /// Live cwd from the latest OSC 7 / PWD report; the sidebar row refreshes. Persisted by `snapshot()` on
    /// quit + structural mutations only (OSC 7 fires constantly), so a crash loses cwd since the last save.
    public var currentCwd: String?
    public let initialCwd: String

    /// Terminal title from the latest OSC 0/1/2 set-title report — shell `PROMPT_COMMAND`, ghostty shell
    /// integration, or a remote host over SSH; the sidebar row refreshes on change. Ephemeral, no save.
    public var oscTitle: String?

    /// The split (right) pane's live cwd and title, reported by the surface flagged `isSplitPane`. Observed,
    /// ephemeral, nil with no split pane; while it has focus the sidebar row and title bar derive from these.
    public var splitCwd: String?
    public var splitTitle: String?

    /// Unseen notifications fired by this session's panes while unfocused; the sidebar badge reacts. Ephemeral.
    public var unseenCount: Int = 0

    /// Per-session agent status, driven over the control channel (`session.status`); the sidebar row's
    /// status glyph reacts. Ephemeral.
    public var agentIndicator = AgentIndicator()

    /// Last time the status was set non-idle — stamped by `AppStore.setAgentIndicator` on EVERY non-idle set
    /// (nil on idle), not just on an idle→non-idle transition. Ephemeral sort key: the attention list orders
    /// same-status sessions newest-change-first.
    @ObservationIgnored public var statusChangedAt: Date?

    /// Whether idle auto-follow already pulled the user to THIS blocked episode; ephemeral. Set on jumping
    /// here by `AppStore.autoFollowFire`, so a later idle fire won't yank the user back to a block already
    /// shown and left. Reset by `AppStore.setAgentIndicator` on a transition INTO blocked — keyed off the
    /// transition, not `statusChangedAt`, so a hook re-asserting `blocked` over `blocked` stays muted.
    @ObservationIgnored public var autoFollowConsumed = false

    /// User-set flagged working-set membership: surfaces the session in the sidebar's flat cross-workspace
    /// flagged view with a filled row icon. Persisted, surviving a relaunch and a workspace move.
    public var flagged: Bool = false

    /// Changes only when one live primary-slot surface replaces another; SwiftUI hosts fold it into their
    /// identity, so lazy nil→first creation stays at zero while split-survivor promotion remounts the view.
    @ObservationIgnored public private(set) var primarySurfaceHostRevision = 0

    /// The app-side surface (a `GhosttySurfaceView`), created lazily on first display and owned here so it
    /// survives sidebar/detail view churn.
    @ObservationIgnored public var surface: (any TerminalSurface)? {
        didSet {
            guard let oldValue, let surface, oldValue !== surface else { return }
            primarySurfaceHostRevision &+= 1
        }
    }

    /// Whether the session is SHOWN as a one-level vertical split; the detail pane shows/hides the second pane.
    public var isSplit: Bool = false

    /// Whether the session HAS a split pane at all, shown or hidden/maximized, unlike `isSplit`. Stays true
    /// across a hide, cleared only by `closeSplit`, so the sidebar + title-bar indicators persist while hidden.
    public var hasSplit: Bool = false

    /// While split, whether the second pane holds focus rather than the primary; the detail pane dims the
    /// inactive one. Meaningless when not split.
    public var splitFocused: Bool = false

    /// The split divider's left-pane fraction, captured from the live `NSSplitView` and persisted, so it
    /// survives a hide/show and a relaunch. Within `AppStore.splitRatioMin...splitRatioMax` (~0.05...0.95):
    /// capture skips degenerate extremes, restore clamps and seeds. nil = even; never read by a SwiftUI view.
    @ObservationIgnored public var splitRatio: Double?

    /// The second pane's surface, created lazily on first split and, like `surface`, surviving view churn —
    /// hiding the split keeps the shell alive. Freed only on `closeSplit`/`closeSession`.
    @ObservationIgnored public var splitSurface: (any TerminalSurface)?

    /// Where the split (right) pane re-spawns on restore (the split factory reads it), from the persisted
    /// `SessionSnapshot.splitCwd`, so each pane keeps its own cwd across a relaunch; nil for a fresh split,
    /// which seeds from `effectiveCwd`.
    @ObservationIgnored public var initialSplitCwd: String?

    /// Terminal font size in points, nil for the ghostty config default. Set on the surface at creation,
    /// written back on cmd +/-, persisted.
    @ObservationIgnored public var fontSize: Double?

    /// The session's background watermark — an image or rasterized text behind the terminal, nil for none.
    /// Applied app-side as a per-surface ghostty config overlay (`WatermarkConfig`) at creation, on change, and
    /// after a global config reload. Persisted, so it survives a relaunch (`.text` re-renders its PNG).
    @ObservationIgnored public var backgroundWatermark: BackgroundWatermark?

    /// A command to run as the session's process instead of the login shell (kitty's `launch <cmd>`, ghostty's
    /// `command`), set via `session.new --command`. The surface factory reads it once; the session closes when
    /// the command exits. Persisted, so a command session — e.g. an `ssh …` shortcut, which exec-replaces the
    /// shell and so escapes the foreground-pid capture — re-runs it on restore when `restoreRunningCommand` is
    /// on (via `wasRestored`); a fresh session always runs it.
    @ObservationIgnored public var initialCommand: String?

    /// Whether a `--command` session HOLDS its surface after the command exits — libghostty's "press any key
    /// to close" prompt, final output intact — instead of closing; set via `session.new --command … --wait`.
    /// The same libghostty `wait_after_command` `overlayWait` uses, applied to the PRIMARY surface; meaningful
    /// only with `initialCommand`. Persisted, so a restored session that re-runs its command holds again.
    @ObservationIgnored public var commandWait: Bool = false

    /// True when the session was rebuilt by `AppStore.restore(from:)` rather than freshly created; gates the
    /// `initialCommand` re-run on `restoreRunningCommand` (a fresh session always runs it, a restored one gets
    /// a plain shell when off). Never persisted.
    @ObservationIgnored public var wasRestored = false

    /// The main pane's foreground command (full argv) for restore-running-command, captured at the last clean
    /// quit and read once by the surface factory on restore, then cleared. Persisted; nil at a prompt.
    @ObservationIgnored public var foregroundCommand: [String]?
    /// The split (right) pane's foreground command (full argv), the split analogue of `foregroundCommand`.
    @ObservationIgnored public var splitForegroundCommand: [String]?

    /// The main pane's PERSISTED restore-command override, set via `session.restore`. Tri-state: nil = no
    /// override (auto-capture), `""` = pinned to a plain shell (suppressing both the capture and
    /// `initialCommand`), `"cmd"` = run that shell line. STICKY, unlike the capture: never cleared on read, so
    /// it fires after every restart until changed. Needs its OWN slot — sharing `foregroundCommand` would let
    /// the quit-time capture clobber it with the live process's argv.
    @ObservationIgnored public var restoreCommand: String?
    /// The split (right) pane's persisted restore-command override, the split analogue of `restoreCommand`.
    @ObservationIgnored public var splitRestoreCommand: String?

    /// The main pane's TRANSIENT override for THIS launch, copied from `restoreCommand` by an app-bootstrap
    /// restore, consumed by `takePendingRestoreOverride(pane:)`, never persisted. A session that was not
    /// bootstrap-restored (fresh, Recent Closed, duplicated, rebuilt after a mid-process window reload) starts
    /// nil, so nothing fires. The ONLY restore-override state a surface factory may read: it freezes what was
    /// eligible at process start, so a command written over the socket during this run never executes in it.
    @ObservationIgnored public var pendingRestoreCommand: String?
    /// The split analogue of `pendingRestoreCommand`, seeded only when the restored split was SHOWN
    /// (`isSplit`) — a hidden split builds no right surface at bootstrap, so a pending payload would instead
    /// fire on a later manual ⌘D.
    @ObservationIgnored public var pendingSplitRestoreCommand: String?

    /// Whether an ephemeral overlay terminal covers this session (full single-pane size); the detail pane
    /// shows/hides it. Control-channel only and ephemeral — it runs one program and vanishes.
    public var overlayActive: Bool = false

    /// The overlay's surface, created on open and torn down when its `overlayCommand` exits or the control
    /// channel closes it — unlike the split, never kept alive while hidden.
    @ObservationIgnored public var overlaySurface: (any TerminalSurface)?

    /// The command the overlay runs as its process (e.g. `revdiff`), read by the overlay factory at creation.
    @ObservationIgnored public var overlayCommand: String?

    /// The overlay's working directory, or nil to inherit `effectiveCwd`. Read by the factory at creation.
    @ObservationIgnored public var overlayCwd: String?

    /// The overlay's own solid background as `#rrggbb`, nil for the theme default; set via
    /// `session.overlay.open --background-color`, read by the factory at creation, cleared on close, never
    /// persisted. Independent of `backgroundWatermark`: the overlay surface is not wired to the session.
    @ObservationIgnored public var overlayBackgroundColor: String?

    /// Whether the overlay keeps its surface after the command exits, showing libghostty's "press any key to
    /// close" prompt with the final output, instead of closing. Read by the factory at creation.
    @ObservationIgnored public var overlayWait: Bool = false

    /// The overlay program's exit status, from the wrapper's `echo $?` temp file at teardown, NOT libghostty's
    /// child-exited status (always 0 — it reports the login-shell wrapper). Reset on the next open, read by
    /// `session.overlay.result`; in-memory only.
    @ObservationIgnored public var overlayExitCode: Int?

    /// For a *floating* overlay, the percent of the pane (width and height) the panel occupies, 1...100; nil
    /// for the default full-pane overlay. Floating = an opaque framed panel centered in the pane, session
    /// still VISIBLE behind it (full instead hides it and draws translucent). Cleared on close, never persisted.
    public var overlaySizePercent: Int?

    /// Whether a FULL-coverage overlay is up: `overlayActive` with no size percent. It hides everything
    /// beneath — the pane(s) AND a shown scratch — so its translucent background reveals the window backing,
    /// never a covered surface: under window translucency every surface renders fully transparent, so anything
    /// left visible below would bleed through. A floating (sized) overlay is not a cover.
    public var fullOverlayActive: Bool { overlayActive && overlaySizePercent == nil }

    /// Whether a FLOATING overlay is up: `overlayActive` WITH a size percent, the complement of
    /// `fullOverlayActive` and not a cover. Read by the detail pane to gate the floating panel.
    public var floatingOverlayActive: Bool { overlayActive && overlaySizePercent != nil }

    /// Whether the scratch terminal covers this session (full single-pane size, like a full overlay); the
    /// detail pane shows/hides it. A third per-session shell that, unlike the ephemeral overlay, behaves like
    /// the split: hiding it keeps the shell alive, so a re-show reuses it. Not persisted.
    public var scratchActive: Bool = false

    /// The scratch terminal's surface: a login shell (or `scratchCommand`), created lazily on first show and
    /// kept alive across hides — non-nil means "alive, maybe hidden". Freed only on `closeScratch` (explicit
    /// close, the shell's own `exit`, or session/workspace/window teardown), after which a show spawns fresh.
    @ObservationIgnored public var scratchSurface: (any TerminalSurface)?

    /// The scratch analogue of `initialCommand` (`session.scratch --command`). RUN-ONCE: the scratch factory
    /// reads and clears it on spawn, so the next show is a plain shell. Never persisted.
    @ObservationIgnored public var scratchCommand: String?

    /// Whether the in-terminal search bar is shown over this session's focused pane (⌘F); the detail pane
    /// shows/hides it. Written directly by surface-factory search callbacks and `AppActions`; ephemeral.
    public var searchActive: Bool = false

    /// The current search query, mirrored from the bar's text field and the control channel. Ephemeral.
    public var searchNeedle: String = ""

    /// Match count for `searchNeedle` from libghostty's `SEARCH_TOTAL`; nil before a query runs. Ephemeral.
    public var searchTotal: Int?

    /// 1-based index of the selected match, from libghostty's `SEARCH_SELECTED`; nil when none. Ephemeral.
    public var searchSelected: Int?

    /// The surface owning the open search bar — the focused searchable pane when search opened. Pinned so the
    /// bar's needle/navigate/close drive the SAME surface even if split focus moves (re-resolving
    /// `activeSurface` would strand the original pane in libghostty search mode). Set on open by the factory's
    /// START callback, cleared on close; weak, since the session strongly owns its panes. Ephemeral.
    @ObservationIgnored public weak var searchSurface: (any TerminalSurface)?

    public init(id: UUID = UUID(), initialCwd: String, customName: String? = nil) {
        self.id = id
        self.initialCwd = initialCwd
        self.customName = customName
    }

    /// The sidebar label: a non-blank `customName` (a manual rename) wins; else the focused pane's non-blank
    /// terminal title; else the basename of `focusedCwd`, falling back to `initialCwd`. Name and title are
    /// both trimmed, so a whitespace-only value falls through — `AppStore.renameSession` clears a blank name
    /// to nil, so one can only arrive via a hand-edited snapshot.
    ///
    /// Basename pins: root `/` → `/` (free from `lastPathComponent`); a trailing slash is ignored (`/a/b/` →
    /// `b`); an empty path → `~`, the home shorthand, since no sensible component exists.
    public var displayName: String {
        if let trimmed = customName?.trimmedOrNil { return trimmed }
        if let title = focusedOscTitle?.trimmedOrNil { return title }
        let path = focusedCwd
        if path.isEmpty { return "~" }
        return (path as NSString).lastPathComponent
    }

    /// The cwd of the focused pane: the split (right) pane's while it has focus (shown or hidden-maximized),
    /// else the primary's, falling back to `initialCwd`. The sidebar and title bar track the focused pane
    /// through it, while `effectiveCwd` stays the primary's. The `splitSurface != nil` guard (the
    /// `activeSurface` idiom) stops a promoted survivor that momentarily re-raised `splitFocused` from masking
    /// the migrated main-pane cwd — the split fields describe the split pane only while it exists.
    public var focusedCwd: String {
        if splitFocused, splitSurface != nil, let cwd = splitCwd { return cwd }
        return currentCwd ?? initialCwd
    }

    /// The focused pane's terminal title: the split pane's while it has focus AND exists, else the primary's
    /// (see `focusedCwd` for the existence guard).
    private var focusedOscTitle: String? { splitFocused && splitSurface != nil ? splitTitle : oscTitle }

    /// The detail after the workspace name on line two of the session palette, the Ctrl-Tab switcher, and the
    /// title bar: the focused pane's terminal title unless that is already the `displayName` (so it ADDS
    /// context), else the focused cwd. Over SSH the remote sets the OSC title to `user@host:dir` while local
    /// OSC 7 stops, freezing `currentCwd` at a stale local path — so preferring the title surfaces the remote
    /// location. An unnamed session already shows the title as line 1, so this falls through to the cwd; a
    /// plain local session has no title (local auto-title is suppressed), so this is the cwd too.
    public var subtitleDetail: String {
        if let title = focusedOscTitle?.trimmedOrNil, title != displayName { return title }
        return focusedCwd
    }

    /// The live `currentCwd` once a PWD report arrived, else `initialCwd`. Always the PRIMARY pane's, never
    /// focus-aware (cf. `focusedCwd`): it seeds new split/overlay/quick terminals and backs
    /// `AGTERM_SESSION_PWD`, which must stay stable regardless of focus.
    public var effectiveCwd: String { currentCwd ?? initialCwd }

    /// The focused pane's surface: the split (right) while it has focus and exists, else the primary. With the
    /// split hidden the detail pane maximizes this one and focus helpers target it, so typing always reaches
    /// the visible pane.
    public var activeSurface: (any TerminalSurface)? {
        splitFocused && splitSurface != nil ? splitSurface : surface
    }

    /// The one addressable pane for control arms acting on "the session" rather than a named `--pane`
    /// (`session.copy`, `session.paste`, `session.selectall`, `font.*`): IDENTICAL to `surface` everywhere,
    /// including a promoted split survivor, which `closePrimaryPane` moves into `surface` while nilling
    /// `splitSurface`. `?? splitSurface` is a defensive fallback keeping the arms answering (not `session not
    /// realized`) should `surface` ever be nil while a split shell lives. NOT focus-aware, unlike
    /// `activeSurface`: a shown split still addresses the main pane, so `session.selectall` and its
    /// `session.copy` read-back stay on one surface.
    public var addressableSurface: (any TerminalSurface)? { surface ?? splitSurface }

    /// Resolves a surface's stable spawn token (`TerminalSurface.paneToken`, baked as `AGTERM_PANE_ID` and
    /// forwarded by the agent-status hook as `session.status --pane-id`) to the slot it CURRENTLY occupies.
    /// Derived LIVE from slot occupancy, so a promoted split survivor resolves `.left` and a fresh re-split
    /// helper `.right` even though both shells were baked with the same stale `right` role — the #199 fix.
    /// nil for an empty or unknown token (torn-down surface, or a shell spawned before the token existed), so
    /// the caller falls back to the baked `--pane`; mirrors the live-role read `GhosttySurfaceView.isSplitPane`
    /// gives the pane-scoped keystroke-clear (see the Notifications rule).
    public func paneRole(forToken token: String) -> StatusPane? {
        guard !token.isEmpty else { return nil }
        if surface?.paneToken == token { return .left }
        if splitSurface?.paneToken == token { return .right }
        if scratchSurface?.paneToken == token { return .scratch }
        return nil
    }

    /// Takes the pane's PENDING restore-command override, clearing it so a second surface for the same pane
    /// this launch gets a plain shell: `makeSplitSurface` runs again on a fresh ⌘D after a split shell exits,
    /// and a leftover payload would fire twice mid-session. The PERSISTED `restoreCommand`/`splitRestoreCommand`
    /// are untouched — sticky, they must fire again after the next restart. `.scratch` returns nil, never
    /// restored.
    public func takePendingRestoreOverride(pane: StatusPane) -> String? {
        switch pane {
        case .left:
            let pending = pendingRestoreCommand
            pendingRestoreCommand = nil
            return pending
        case .right:
            let pending = pendingSplitRestoreCommand
            pendingSplitRestoreCommand = nil
            return pending
        case .scratch:
            return nil
        }
    }

    /// Drops both unconsumed override payloads, leaving the persisted fields alone. Called where a live
    /// `Session` leaves the tree but may return as the SAME object (the soft-close grace window): a payload
    /// armed at bootstrap would otherwise survive the round trip and fire when its surface is rebuilt.
    public func clearPendingRestoreOverrides() {
        pendingRestoreCommand = nil
        pendingSplitRestoreCommand = nil
    }

    /// The surface on top and owning keyboard focus: an active overlay (full OR floating), else the scratch,
    /// else the active pane. The overlay renders above the scratch, and a full overlay or the scratch covers
    /// the panes, so session-focus helpers route through this to keep first responder off a covered surface —
    /// except `TerminalView.focusIfNeeded`, which targets its own deck slot, already gated by `isActive`.
    public var topmostSurface: (any TerminalSurface)? {
        if overlayActive { return overlaySurface }
        if scratchActive { return scratchSurface }
        return activeSurface
    }

    /// The pane-or-scratch surface actually ON SCREEN: the scratch when it covers the panes with no overlay up,
    /// else the focused pane — so `session.text` (no `--pane`) and `session.search` hit the scratch, not the
    /// pane beneath. An overlay routes via `topmostSurface`; this stays pane-vs-scratch, like `searchTarget`.
    public var onScreenSurface: (any TerminalSurface)? {
        scratchActive && !overlayActive ? topmostSurface : activeSurface
    }

    /// The match counter for the search bar and `session.search`: empty before a query runs, `"no matches"` at
    /// zero, `"N matches"` while none is selected, `"S of N"` once one is. `selected` is clamped to `total` so
    /// a stale index (the count shrank before the next SEARCH_SELECTED lands) never reads "3 of 2".
    public var searchDisplayText: String {
        guard let total = searchTotal else { return "" }
        guard total > 0 else { return "no matches" }
        guard let selected = searchSelected else { return "\(total) matches" }
        return "\(min(selected, total)) of \(total)"
    }

    /// Resets all search state. Called from the pane-teardown/promote paths (`closeSplit`, `closePrimaryPane`,
    /// `closeSplitPane`) so a session whose searched pane was destroyed or promoted keeps no stuck, no-op bar:
    /// the weak `searchSurface` zeroes but `searchActive` would otherwise stay true.
    public func clearSearch() {
        searchActive = false
        searchNeedle = ""
        searchTotal = nil
        searchSelected = nil
        searchSurface = nil
    }
}

extension String {
    /// Trimmed of surrounding whitespace and newlines, nil if empty — the one normalizer for the
    /// rename/displayName "blank after trim" rule.
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
