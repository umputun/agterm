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

    /// A command to run as the session's process instead of the login shell (like kitty's `launch
    /// <cmd>` / ghostty's `command`), set at creation via `session.new --command`. The surface factory
    /// reads it once; on the command exiting the session closes (the normal single-pane exit path).
    /// `@ObservationIgnored` + absent from `snapshot()`: transient and run-once, never persisted, so a
    /// restored session is a plain shell.
    @ObservationIgnored public var initialCommand: String?

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

    /// Whether the scratch terminal is shown on top of this session (full single-pane size, hiding
    /// the single/split content underneath, like a full overlay). The scratch is a third per-session
    /// shell that — unlike the ephemeral overlay — behaves like the split: hiding it keeps the shell
    /// alive (`scratchSurface` retained), so a re-show reuses it. Observed, so the detail pane shows/
    /// hides the scratch. NOT persisted (absent from `snapshot()`), so it never survives a relaunch.
    public var scratchActive: Bool = false

    /// The scratch terminal's surface: a plain login shell, lazily created on first show and kept
    /// alive across hides (`scratchSurface != nil` is "alive but hidden"). Freed only on
    /// `closeScratch` (an explicit close, the shell's own `exit`, or session/workspace/window
    /// teardown) — after which the next show spawns a fresh shell. `@ObservationIgnored` like `surface`.
    @ObservationIgnored public var scratchSurface: (any TerminalSurface)?

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
    /// `AGTERM_SESSION_PWD` token. Guarded on `splitFocused` alone (not `isSplit`): `closeSplit` resets
    /// the flag, so `splitFocused` is true only while the split pane actually exists.
    public var focusedCwd: String {
        if splitFocused, let cwd = splitCwd { return cwd }
        return currentCwd ?? initialCwd
    }

    /// The terminal title of the focused pane: the split pane's while it has focus, else the primary's.
    private var focusedOscTitle: String? { splitFocused ? splitTitle : oscTitle }

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

    /// The surface currently on top and owning keyboard focus: a full overlay, else the scratch, else
    /// the active pane. Both the overlay and the scratch are full-coverage layers (panes hidden beneath
    /// them), and the overlay renders above the scratch — so every focus path routes through this to keep
    /// first responder on the visible top surface and never on a covered pane/scratch.
    public var topmostSurface: (any TerminalSurface)? {
        if overlayActive { return overlaySurface }
        if scratchActive { return scratchSurface }
        return activeSurface
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
