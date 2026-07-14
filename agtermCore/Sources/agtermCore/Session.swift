import Foundation
import Observation

/// One shell, backed by a single libghostty surface.
///
/// `@MainActor` (so it's implicitly `Sendable` via isolation — never made an
/// `actor`). The `surface` slot is `@ObservationIgnored` so assigning the
/// lazily-created NSView never churns observation; `customName`/`currentCwd` are
/// observed, so the sidebar refreshes when a rename or PWD report lands.
@Observable
@MainActor
public final class Session: Identifiable {
    public let id: UUID
    public var customName: String?
    /// The live working directory from the latest OSC 7 / PWD report. Observed, so
    /// the sidebar row refreshes when it changes. It is captured by `snapshot()`
    /// and so persisted on quit and on structural mutations, but a bare `cd` does
    /// not trigger a save (OSC 7 fires constantly), so a crash loses only cwd
    /// changes since the last structural mutation.
    public var currentCwd: String?
    public let initialCwd: String

    /// The terminal title from the latest OSC 0/1/2 set-title report — set by a shell
    /// `PROMPT_COMMAND`, ghostty's shell integration, or a remote host over SSH. Observed, so the
    /// sidebar row refreshes when it changes. Ephemeral like `currentCwd`/`unseenCount`:
    /// `SessionSnapshot` doesn't capture it, and a bare prompt redraw doesn't trigger a save.
    public var oscTitle: String?

    /// The split (right) pane's live cwd and terminal title, reported by the split surface (the one
    /// flagged `isSplitPane`). Observed and ephemeral like `currentCwd`/`oscTitle`; nil when there is
    /// no split pane. While the split pane has focus, the sidebar row and title bar derive their
    /// name/cwd from these instead of the primary's, so the chrome tracks whichever pane you're in.
    public var splitCwd: String?
    public var splitTitle: String?

    /// Count of unseen terminal notifications fired by this session's panes while it wasn't focused.
    /// Observed, so the sidebar badge reacts. Ephemeral: `SessionSnapshot` doesn't capture it, so it
    /// never survives a relaunch.
    public var unseenCount: Int = 0

    /// The per-session agent status, driven over the control channel (`session.status`). Observed, so
    /// the sidebar row's status glyph reacts. Ephemeral like `unseenCount`: `SessionSnapshot` doesn't
    /// capture it, so it never survives a relaunch.
    public var agentIndicator = AgentIndicator()

    /// The most-recent time the agent status was set to a non-idle value — stamped by
    /// `AppStore.setAgentIndicator` on EVERY non-idle set (`Date()` for any non-idle status, nil on idle),
    /// not only on an idle→non-idle transition. Sort key only — the attention list orders same-status
    /// sessions newest-change-first. `@ObservationIgnored` (no view reacts to it; the list reads it as a
    /// sort key) and ephemeral: `SessionSnapshot` doesn't capture it, so it never survives a relaunch.
    @ObservationIgnored public var statusChangedAt: Date?

    /// Whether this session is in the flagged working-set — a durable, user-set flag that surfaces the
    /// session in the sidebar's flat flagged view (across workspaces) and swaps its tree row to the
    /// filled icon variant. Observed, so the sidebar reacts to a toggle. Persisted via `SessionSnapshot.flagged`,
    /// so it survives a relaunch (and a workspace move — the flag travels with the session).
    public var flagged: Bool = false

    /// The app-side surface (a `GhosttySurfaceView`). Lazily created on first
    /// display and owned here so it survives sidebar/detail view churn.
    @ObservationIgnored public var surface: (any TerminalSurface)?

    /// Whether the session is shown as a one-level vertical split (two panes side by
    /// side). Observed, so the detail pane shows/hides the second pane when toggled.
    public var isSplit: Bool = false

    /// Whether the session HAS a split pane at all (shown side-by-side OR hidden/maximized to one
    /// pane), as opposed to `isSplit` which is only "currently shown". Stays true across a hide, and
    /// is cleared only when the split is closed (`closeSplit`). Observed, so the sidebar + title-bar
    /// split indicators persist while a split is merely hidden.
    public var hasSplit: Bool = false

    /// While split, whether the split (second) pane holds focus rather than the primary.
    /// Observed, so the detail pane can dim the inactive pane. Meaningless when not split.
    public var splitFocused: Bool = false

    /// The split divider's left-pane fraction, captured from the live `NSSplitView` so the side-by-side
    /// ratio survives a hide/show and a relaunch (persisted in `SessionSnapshot`). Within
    /// `AppStore.splitRatioMin...splitRatioMax` (~0.05...0.95) - the capture skips degenerate extremes and
    /// restore clamps. Seeded on restore, kept current by the split's introspection accessor;
    /// `@ObservationIgnored` because it is read/written imperatively, not by any SwiftUI view. nil = even.
    @ObservationIgnored public var splitRatio: Double?

    /// The second pane's surface, lazily created on first split. `@ObservationIgnored`
    /// like `surface`; it survives view churn, so hiding the split keeps the shell alive
    /// rather than destroying it. Freed only on `closeSplit`/`closeSession`.
    @ObservationIgnored public var splitSurface: (any TerminalSurface)?

    /// The directory the split (right) pane re-spawns in on restore, set from the persisted
    /// `SessionSnapshot.splitCwd` so each pane keeps its own cwd across relaunch. nil for a
    /// fresh (never-restored) split, which seeds from the session's `effectiveCwd` instead.
    /// `@ObservationIgnored`: read imperatively by the split factory, captured by `snapshot()`.
    @ObservationIgnored public var initialSplitCwd: String?

    /// The terminal font size in points, or nil to use the ghostty config default. The app
    /// sets the surface's initial size from this on creation and writes it back when the
    /// user changes it (cmd +/-). `@ObservationIgnored`: nothing in SwiftUI reacts to it —
    /// it is read imperatively at surface creation and captured by `snapshot()`.
    @ObservationIgnored public var fontSize: Double?

    /// The session's background watermark (an image or rasterized text composited behind the terminal),
    /// or nil for none. The app target applies it to the session's surface(s) via a per-surface ghostty
    /// config overlay (see `WatermarkConfig`) at creation, on change, and after a global config reload.
    /// `@ObservationIgnored` like `fontSize`: nothing in SwiftUI reacts — it is read imperatively when a
    /// surface is (re)configured and captured by `snapshot()`, so it survives a relaunch (a `.text`
    /// watermark re-renders its PNG on restore).
    @ObservationIgnored public var backgroundWatermark: BackgroundWatermark?

    /// A command to run as the session's process instead of the login shell (like kitty's `launch
    /// <cmd>` / ghostty's `command`), set at creation via `session.new --command`. The surface factory
    /// reads it once; on the command exiting the session closes (the normal single-pane exit path).
    /// `@ObservationIgnored`. Persisted via `SessionSnapshot.initialCommand` so a command session — e.g.
    /// an `ssh …` shortcut, which exec-replaces the shell and so is invisible to the foreground-pid
    /// capture — re-runs its command on restore instead of coming back a plain shell. The restore re-run
    /// is gated by `restoreRunningCommand` (via `wasRestored`); a fresh session always runs it.
    @ObservationIgnored public var initialCommand: String?

    /// True when this session was rebuilt by `AppStore.restore(from:)` rather than freshly created. The
    /// surface factory reads it to gate the `initialCommand` re-run: a FRESH command session always runs
    /// its command, but a RESTORED one re-runs only when `restoreRunningCommand` is on (else a plain
    /// shell). `@ObservationIgnored`; transient, never persisted.
    @ObservationIgnored public var wasRestored = false

    /// The main pane's foreground command (full argv) captured at the last clean quit, for the
    /// restore-running-command feature. `@ObservationIgnored`: written imperatively by the quit-flush
    /// capture and read once by the surface factory on restore (then cleared, like `scratchCommand`).
    /// Persisted via `SessionSnapshot.foregroundCommand`; nil when the pane was at its prompt.
    @ObservationIgnored public var foregroundCommand: [String]?
    /// The split (right) pane's foreground command (full argv), the split analogue of `foregroundCommand`.
    @ObservationIgnored public var splitForegroundCommand: [String]?

    /// Whether an ephemeral overlay terminal is shown on top of this session (full single-pane
    /// size, hiding the single/split content underneath). Observed, so the detail pane shows/hides
    /// the overlay. Driven only by the control channel; NOT persisted (absent from `snapshot()`), so
    /// the overlay never survives a relaunch — it exists only to run one program and vanish.
    public var overlayActive: Bool = false

    /// The overlay's surface, created when the overlay opens and torn down when its program exits or
    /// the control channel closes it (unlike the split, which is kept alive when hidden). The shell
    /// runs `overlayCommand`; on its exit the surface's process-exit closes the overlay.
    @ObservationIgnored public var overlaySurface: (any TerminalSurface)?

    /// The command the overlay runs as its process (e.g. `revdiff`); read by the overlay surface
    /// factory at creation. `@ObservationIgnored`: read imperatively, not reactive.
    @ObservationIgnored public var overlayCommand: String?

    /// The overlay's working directory, or nil to inherit `effectiveCwd`. Read by the factory at
    /// creation. `@ObservationIgnored`.
    @ObservationIgnored public var overlayCwd: String?

    /// The overlay's own solid background color as `#rrggbb`, or nil for the default theme background.
    /// Independent of the session's `backgroundWatermark` — the overlay surface is not wired to the
    /// session, so it carries its own color, set via `session.overlay.open --background-color`. Read by
    /// the factory at creation; set at open, cleared on close. `@ObservationIgnored`, never persisted.
    @ObservationIgnored public var overlayBackgroundColor: String?

    /// Whether the overlay keeps its surface open after the command exits, showing libghostty's
    /// "press any key to close" prompt (useful to read a command's final output) instead of closing
    /// immediately. Read by the factory at creation. `@ObservationIgnored`.
    @ObservationIgnored public var overlayWait: Bool = false

    /// The overlay program's exit status, recorded on the surface's teardown from the wrapper's
    /// `echo $?` temp file (NOT libghostty's child-exited status, which reflects the login-shell
    /// wrapper and is always 0). Reset to nil when a new overlay opens; read by `session.overlay.result`.
    /// In-memory only (absent from `snapshot()`), so it never persists.
    @ObservationIgnored public var overlayExitCode: Int?

    /// For a *floating* overlay, the percent of the pane (both width and height) the panel occupies,
    /// 1...100; nil for the default full-pane overlay. A floating overlay renders as an opaque, framed
    /// panel centered in the pane with the session still VISIBLE behind it (the full overlay instead
    /// hides the session and draws translucent). Observed, so the detail pane picks the right layout.
    /// Set at open, cleared on close; never persisted.
    public var overlaySizePercent: Int?

    /// Whether a FULL-coverage overlay is up: `overlayActive` with no size percent. A full overlay hides
    /// the session content beneath it — the pane(s) AND a shown scratch — so its translucent background
    /// reveals the window backing, never a covered surface (under window translucency every surface
    /// renders a fully transparent background, so anything left visible below would bleed through).
    /// A floating (sized) overlay is not a cover: it draws an opaque panel over still-visible content.
    public var fullOverlayActive: Bool { overlayActive && overlaySizePercent == nil }

    /// Whether a FLOATING overlay is up: `overlayActive` WITH a size percent — the complement of
    /// `fullOverlayActive`. A floating overlay draws an opaque, framed panel sized to `overlaySizePercent`%
    /// over the still-visible session rather than covering it, so it is not a cover. Read by the detail
    /// pane to gate the floating panel.
    public var floatingOverlayActive: Bool { overlayActive && overlaySizePercent != nil }

    /// Whether the scratch terminal is shown on top of this session (full single-pane size, hiding
    /// the single/split content underneath, like a full overlay). The scratch is a third per-session
    /// shell that — unlike the ephemeral overlay — behaves like the split: hiding it keeps the shell
    /// alive (`scratchSurface` retained), so a re-show reuses it. Observed, so the detail pane shows/
    /// hides the scratch. NOT persisted (absent from `snapshot()`), so it never survives a relaunch.
    public var scratchActive: Bool = false

    /// The scratch terminal's surface: a login shell (or `scratchCommand` when set), lazily created on
    /// first show and kept alive across hides (`scratchSurface != nil` is "alive but hidden"). Freed only
    /// on `closeScratch` (an explicit close, the shell's own `exit`, or session/workspace/window
    /// teardown) — after which the next show spawns a fresh shell. `@ObservationIgnored` like `surface`.
    @ObservationIgnored public var scratchSurface: (any TerminalSurface)?

    /// A command to run as the scratch's process instead of a login shell (set via `session.scratch
    /// --command`), the scratch analogue of `initialCommand`. RUN-ONCE: the scratch surface factory reads
    /// it once when it spawns and clears it, so after the command exits the next show is a plain shell.
    /// `@ObservationIgnored` + absent from `snapshot()`: transient like the scratch itself, never persisted.
    @ObservationIgnored public var scratchCommand: String?

    /// Whether the in-terminal search bar is shown over this session's focused pane (⌘F). Observed,
    /// so the detail pane shows/hides the bar. Written directly (from the surface factory's search
    /// callbacks + `AppActions`). NOT persisted (absent from `snapshot()`), so it never survives a relaunch.
    public var searchActive: Bool = false

    /// The current search query, mirrored from the bar's text field and the control channel. Observed
    /// + written directly like `searchActive`. Ephemeral, never persisted.
    public var searchNeedle: String = ""

    /// The number of matches for `searchNeedle`, from libghostty's `SEARCH_TOTAL` action; nil before a
    /// query runs. Observed + written directly. Ephemeral, never persisted.
    public var searchTotal: Int?

    /// The 1-based index of the currently selected match, from libghostty's `SEARCH_SELECTED` action;
    /// nil when none is selected. Observed + written directly. Ephemeral, never persisted.
    public var searchSelected: Int?

    /// The surface that owns the open search bar — the focused searchable pane at the time search opened.
    /// Pinned here so the bar's needle/navigate/close drive the SAME surface that opened search even if
    /// split focus moves afterwards (otherwise re-resolving `activeSurface` would strand the original pane
    /// in libghostty search mode). Set on open by the surface factory's START callback, cleared on close.
    /// `@ObservationIgnored` + weak (the session strongly owns its panes); ephemeral, never persisted.
    @ObservationIgnored public weak var searchSurface: (any TerminalSurface)?

    public init(id: UUID = UUID(), initialCwd: String, customName: String? = nil) {
        self.id = id
        self.initialCwd = initialCwd
        self.customName = customName
    }

    /// The sidebar label: a non-blank `customName` (a manual rename) wins; otherwise a non-blank
    /// terminal title of the focused pane (`focusedOscTitle` — the split pane's while it's focused in
    /// a split, else the primary's); otherwise the basename of the focused pane's cwd (`focusedCwd`,
    /// falling back to `initialCwd`).
    ///
    /// `customName` and the title are both trimmed before use, so a whitespace-only value falls
    /// through to the next source — matching `AppStore.renameSession`, which clears a blank name to
    /// nil. (A whitespace-only `customName` can only reach here via a hand-edited snapshot;
    /// `renameSession` never stores one.)
    ///
    /// Basename pins: root `/` → `/` (`lastPathComponent` already returns this);
    /// a trailing slash is ignored (`/a/b/` → `b`); an empty path → `~` (no
    /// sensible component exists, so we show the home shorthand).
    public var displayName: String {
        if let trimmed = customName?.trimmedOrNil { return trimmed }
        if let title = focusedOscTitle?.trimmedOrNil { return title }
        let path = focusedCwd
        if path.isEmpty { return "~" }
        return (path as NSString).lastPathComponent
    }

    /// The cwd of the pane currently in focus: the split (right) pane's while it has focus (whether
    /// the split is shown side-by-side OR hidden and maximized), otherwise the primary's; falls back
    /// to the primary cwd then `initialCwd`. The sidebar and title bar use this so they track whichever
    /// pane has focus, while `effectiveCwd` (below) stays the primary's for seeding new panes and the
    /// `AGTERM_SESSION_PWD` token. Guarded on `splitFocused && splitSurface != nil` — the same idiom as
    /// `activeSurface`: the split fields describe the split pane only while it exists, so a promoted
    /// survivor that momentarily re-raised `splitFocused` after moving into the main slot can't mask the
    /// migrated main-pane cwd/title.
    public var focusedCwd: String {
        if splitFocused, splitSurface != nil, let cwd = splitCwd { return cwd }
        return currentCwd ?? initialCwd
    }

    /// The terminal title of the focused pane: the split pane's while it has focus AND exists, else the
    /// primary's (see `focusedCwd` for why the split-existence guard).
    private var focusedOscTitle: String? { splitFocused && splitSurface != nil ? splitTitle : oscTitle }

    /// The detail shown after the workspace name on the second line of the session palette, the Ctrl-Tab
    /// switcher, and the title bar: the focused pane's terminal title when it isn't already the
    /// `displayName` (so it ADDS context rather than repeating line 1), otherwise the focused cwd.
    ///
    /// A remote (SSH) host sets the OSC title to its own `user@host:dir` while the local OSC 7 cwd report
    /// stops once the shell hops out, so `currentCwd` freezes at the stale local path. Preferring the
    /// title surfaces the remote location instead of that misleading local path. For an UNNAMED session
    /// the title is already line 1 (`displayName` prefers it over the cwd), so this falls through to the
    /// cwd — no duplication. For a plain local session the title is nil (local auto-title is suppressed),
    /// so this is just the cwd, unchanged.
    public var subtitleDetail: String {
        if let title = focusedOscTitle?.trimmedOrNil, title != displayName { return title }
        return focusedCwd
    }

    /// The session's effective working directory: the live `currentCwd` once a PWD report has
    /// arrived, otherwise `initialCwd`. Always the PRIMARY pane's (NOT focus-aware) — it seeds a new
    /// split/overlay/quick-terminal and backs the `AGTERM_SESSION_PWD` token, which should be stable
    /// regardless of which pane is focused. The focus-aware variant is `focusedCwd`.
    public var effectiveCwd: String { currentCwd ?? initialCwd }

    /// The surface of the pane currently in focus: the split (right) pane while it has focus and
    /// exists, otherwise the primary. When the split is hidden the detail pane shows this one
    /// maximized, and the focus helpers target it, so focus/typing always reaches the visible pane.
    public var activeSurface: (any TerminalSurface)? {
        splitFocused && splitSurface != nil ? splitSurface : surface
    }

    /// The session's one addressable pane for the control arms that act on "the session" rather than on a
    /// named `--pane`: `session.copy`, `session.paste`, `session.selectall`, and `font.*`. Normally the main
    /// pane, and IDENTICAL to `surface` for every ordinary or split session — including a promoted split
    /// survivor, which `closePrimaryPane` moves INTO the main slot (`surface`) and whose `splitSurface` it
    /// nils. The `?? splitSurface` term is a defensive fallback only: it keeps the arms answering (instead
    /// of `session not realized`) should `surface` ever be nil while a split shell is still alive.
    /// Deliberately NOT focus-aware (unlike `activeSurface`): a shown split keeps
    /// addressing the main pane, which is what keeps `session.selectall` and its `session.copy` read-back
    /// pointed at the same surface.
    public var addressableSurface: (any TerminalSurface)? { surface ?? splitSurface }

    /// Resolves a surface's stable spawn token (`TerminalSurface.paneToken`, baked as `AGTERM_PANE_ID` and
    /// forwarded by the agent-status hook as `session.status --pane-id`) to the pane role of the slot it
    /// CURRENTLY occupies — `.left` for the main slot, `.right` for the split, `.scratch` for the scratch.
    /// Because the role is derived LIVE from slot occupancy, a promoted split survivor (moved into `surface`
    /// by `closePrimaryPane`) resolves `.left` and a fresh re-split helper (in `splitSurface`) resolves
    /// `.right`, even though BOTH shells were baked with the same stale `right` role — the #199 fix. Returns
    /// nil for an empty or unknown token (a torn-down surface, or a shell spawned before the token existed),
    /// so the caller falls back to the baked `--pane` value. This mirrors the live-role read the pane-scoped
    /// keystroke-clear already does via `GhosttySurfaceView.isSplitPane` (see the Notifications rule).
    public func paneRole(forToken token: String) -> StatusPane? {
        guard !token.isEmpty else { return nil }
        if surface?.paneToken == token { return .left }
        if splitSurface?.paneToken == token { return .right }
        if scratchSurface?.paneToken == token { return .scratch }
        return nil
    }

    /// The surface currently on top and owning keyboard focus: an active overlay (full OR floating), else
    /// the scratch, else the active pane. The overlay renders above the scratch, and a full overlay or the
    /// scratch hides the pane(s) beneath it — so the session-focus helpers route through this to keep first
    /// responder on the top surface and never on a covered pane/scratch. (`TerminalView.focusIfNeeded` is
    /// the exception: it targets its own deck slot, which a cover already gates off via `isActive`.)
    public var topmostSurface: (any TerminalSurface)? {
        if overlayActive { return overlaySurface }
        if scratchActive { return scratchSurface }
        return activeSurface
    }

    /// The pane-or-scratch surface that is actually ON SCREEN: the scratch terminal when it covers the
    /// panes (and no overlay is up), else the focused pane. The control arms that act on "what's visible"
    /// — `session.text` with no `--pane` and `session.search` — resolve through this so they hit the
    /// scratch rather than a pane hidden beneath it (an active overlay routes to its own surface via
    /// `topmostSurface`; this stays the pane-vs-scratch choice those arms share, matching `searchTarget`).
    public var onScreenSurface: (any TerminalSurface)? {
        scratchActive && !overlayActive ? topmostSurface : activeSurface
    }

    /// The match counter shown in the search bar and returned by `session.search`: empty before a
    /// query runs (`searchTotal` nil), `"no matches"` at zero, `"N matches"` while none is selected,
    /// and `"S of N"` once a match is selected. `selected` is clamped to `total` so a stale selected
    /// index (the count shrank under it before the next SEARCH_SELECTED lands) never reads "3 of 2".
    public var searchDisplayText: String {
        guard let total = searchTotal else { return "" }
        guard total > 0 else { return "no matches" }
        guard let selected = searchSelected else { return "\(total) matches" }
        return "\(min(selected, total)) of \(total)"
    }

    /// Resets all search state to its defaults: hides the bar, clears the needle/count/index, and nils
    /// the pinned owner. Called from the pane-teardown/promote paths (`closeSplit`, `closePrimaryPane`,
    /// `closeSplitPane`) so a session whose searched pane was destroyed or promoted doesn't keep a stuck,
    /// no-op bar (the weak `searchSurface` zeroes but `searchActive` would otherwise stay true).
    public func clearSearch() {
        searchActive = false
        searchNeedle = ""
        searchTotal = nil
        searchSelected = nil
        searchSurface = nil
    }
}

extension String {
    /// The string trimmed of leading/trailing whitespace and newlines, or nil if
    /// the result is empty. The single normalizer for the rename/displayName
    /// "blank after trim" rule.
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
