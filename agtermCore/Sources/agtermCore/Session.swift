import Foundation
import Observation

/// Which pane a pane-scoped overlay covers. Two cases rather than `StatusPane` so a scratch overlay is
/// not representable and no call site needs a scratch guard.
public enum OverlayPane: String, CaseIterable, Codable, Sendable {
    case left
    case right

    /// Accepts the same pane spellings as `TerminalZoomSurface`, minus `scratch`: a pane overlay covers a
    /// split pane only. Role and axis names are accepted as aliases, so the rejection message naming only
    /// `left or right` is guidance, not the full accepted set.
    public init?(controlName: String) {
        switch controlName {
        case "left", "top", "primary":
            self = .left
        case "right", "bottom", "split":
            self = .right
        default:
            return nil
        }
    }

    /// The three `Session` slots this pane owns, plus its zoom surface — the ONE place the
    /// `left`↔`leftOverlay*` mapping is written. Every reader and writer goes through these key paths, so a
    /// transposed ternary can no longer drive the wrong pane from any of the call sites.
    @MainActor public var overlaySlot: ReferenceWritableKeyPath<Session, PaneOverlay?> {
        self == .left ? \.leftOverlay : \.rightOverlay
    }

    @MainActor public var surfaceSlot: ReferenceWritableKeyPath<Session, (any TerminalSurface)?> {
        self == .left ? \.leftOverlaySurface : \.rightOverlaySurface
    }

    @MainActor public var exitCodeSlot: ReferenceWritableKeyPath<Session, Int?> {
        self == .left ? \.leftOverlayExitCode : \.rightOverlayExitCode
    }

    /// The zoom surface addressing this pane's overlay (`surface:<id>:overlay-left|overlay-right`).
    public var zoomSurface: TerminalZoomSurface {
        self == .left ? .overlayLeft : .overlayRight
    }

    /// The pane itself as a zoom surface, the slot this overlay covers.
    public var paneZoomSurface: TerminalZoomSurface {
        self == .left ? .primary : .split
    }
}

/// One pane's ephemeral overlay — the session-scoped overlay's fields minus the size percent, which a
/// pane overlay never has (it is always full-pane). The surface lives beside this in
/// `leftOverlaySurface`/`rightOverlaySurface`, not inside, because `TerminalView` writes that slot back
/// during view update and an observed write there would loop.
public struct PaneOverlay: Equatable, Sendable {
    /// The command the overlay runs as its process, read by the overlay factory at creation.
    public var command: String
    /// The overlay's working directory, or nil to inherit `effectiveCwd`.
    public var cwd: String?
    /// The overlay's own solid background as `#rrggbb`, nil for the theme default. Per-surface, so two
    /// pane overlays open at once may carry different colors.
    public var backgroundColor: String?
    /// Whether the overlay holds its surface after the command exits (libghostty's "press any key to
    /// close"), instead of closing.
    public var wait: Bool

    public init(command: String, cwd: String? = nil, backgroundColor: String? = nil, wait: Bool = false) {
        self.command = command
        self.cwd = cwd
        self.backgroundColor = backgroundColor
        self.wait = wait
    }
}

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
    /// Stable process identity for the primary pane. It follows a promoted split survivor.
    public var paneIdentity: UUID
    /// Stable process identity for an existing split pane, including a hidden split.
    public var splitPaneIdentity: UUID?
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
    /// (nil on idle), not just on an idle→non-idle transition. Ephemeral. Sorts the attention list
    /// newest-change-first, and `controlTree` publishes it as the node's `statusChangedAt`. That read-back
    /// ships epoch seconds compared against `ControlEvent.ts`, so it must stay a wall-clock `Date` — a
    /// monotonic instant would keep the sort working and make a client's computed age meaningless.
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

    /// Whether the session is SHOWN as a one-level split; the detail pane shows/hides the second pane.
    public var isSplit: Bool = false

    /// Whether the session HAS a split pane at all, shown or hidden/maximized, unlike `isSplit`. Stays true
    /// across a hide, cleared only by `closeSplit`, so the sidebar + title-bar indicators persist while hidden.
    public var hasSplit: Bool = false

    /// The split's physical arrangement. A fresh or legacy session starts left/right; changing this while
    /// both panes exist transposes their layout without replacing either terminal surface.
    public var splitAxis: SplitAxis = .leftRight

    /// While split, whether the second pane holds focus rather than the primary; the detail pane dims the
    /// inactive one. Meaningless when not split.
    public var splitFocused: Bool = false

    /// The split divider's primary-pane fraction, captured from the live `NSSplitView` and persisted, so it
    /// survives a hide/show and a relaunch. Within `AppStore.splitRatioMin...splitRatioMax` (~0.05...0.95):
    /// capture skips degenerate extremes, restore clamps and seeds. nil = even; never read by a SwiftUI view.
    @ObservationIgnored public var splitRatio: Double?

    /// The second pane's surface, created lazily on first split and, like `surface`, surviving view churn —
    /// hiding the split keeps the shell alive. Freed only on `closeSplit`/`closeSession`.
    @ObservationIgnored public var splitSurface: (any TerminalSurface)?

    public func zmxBacking(for surface: TerminalZoomSurface) -> Bool? {
        switch surface {
        case .primary: self.surface?.backedByZmx ?? false
        case .split: splitSurface?.backedByZmx ?? false
        default: nil
        }
    }

    public var allPanesBackedByZmx: Bool {
        (surface?.backedByZmx ?? false) && (!hasSplit || (splitSurface?.backedByZmx ?? false))
    }

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
    /// the command exits. Persisted, so a command session — e.g. an `ssh …` shortcut, which escapes the
    /// foreground-pid capture because that pane's group is led by unreadable setuid-root `login` — re-runs it
    /// on restore in `rerun` launch mode (via `wasRestored`); a fresh session always runs it.
    @ObservationIgnored public var initialCommand: String?

    /// Whether a `--command` session HOLDS its surface after the command exits — libghostty's "press any key
    /// to close" prompt, final output intact — instead of closing; set via `session.new --command … --wait`.
    /// The same libghostty `wait_after_command` `overlayWait` uses, applied to the PRIMARY surface; meaningful
    /// only with `initialCommand`. Persisted, so a restored session that re-runs its command holds again.
    @ObservationIgnored public var commandWait: Bool = false

    /// The split pane's creation command, the split analogue of `initialCommand`. Persisted so a pane moved
    /// into the split role by a swap keeps its exec lifecycle across restore.
    @ObservationIgnored public var splitInitialCommand: String?

    /// The split pane's hold-after-exit policy, meaningful only with `splitInitialCommand`.
    @ObservationIgnored public var splitCommandWait: Bool = false

    /// True when the session was rebuilt by `AppStore.restore(from:)` rather than freshly created; gates the
    /// `initialCommand` re-run on `rerun` launch mode (a fresh session always runs it, a restored one gets
    /// a plain shell in any other mode). Never persisted.
    @ObservationIgnored public var wasRestored = false

    /// The main pane's foreground command (full argv) for restore-running-command, read once by the surface
    /// factory on a launch restore, then cleared. Persisted; nil at a prompt. Capture sites and the
    /// launch-only replay gate: `.claude/rules/settings.md`.
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

    /// The main pane's TRANSIENT captured foreground command for THIS launch, copied from the persisted
    /// `foregroundCommand` by an app-bootstrap restore and consumed by the surface factory. Never
    /// serialized by `snapshot()`, which is what makes the launch-time strip durable: the persisted field
    /// goes nil the moment the replay is armed, so no save landing before the surface spawns can write the
    /// argv back over the file the strip just cleaned.
    @ObservationIgnored public var pendingForegroundCommand: [String]?
    /// The split analogue of `pendingForegroundCommand`, seeded for every surviving split (`hasSplit`),
    /// hidden included: a hidden split builds no right surface at bootstrap, so it consumes this only if it
    /// is later shown, and the exit capture writes it back untouched until then.
    @ObservationIgnored public var pendingSplitForegroundCommand: [String]?

    /// Whether the session-wide overlay slot is OCCUPIED, by either of its two occupants: a caller's PROGRAM
    /// (`session.overlay.open`, which covers the session and owns first responder) or a passive HUD message
    /// (`session.hud.open`, which covers nothing). Raw, so it answers only "occupied" — ask
    /// `programOverlayActive` or `hudActive` for which, and never this, wherever the answer decides focus,
    /// coverage, or input. Control-channel only and ephemeral; the detail pane shows and hides it.
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

    /// The percent of the pane an opaque framed panel occupies with the session still VISIBLE behind it; nil
    /// is the full-pane program overlay, which hides it and draws translucent. 1...100 for a floating PROGRAM
    /// overlay, which takes it on BOTH axes and is always centered; a HUD shares the field for its WIDTH
    /// only, bounded by `HudLayout.clampSizePercent` and placed by its own `HudSpec.position`, and sizes its
    /// height through `hudHeightPercent`. Cleared on close, never persisted.
    public var overlaySizePercent: Int?

    /// The percent of the pane's HEIGHT a HUD panel occupies, measured from its message rather than set by
    /// the caller (`HudLayout.heightPercent`); nil for an empty slot and for a program overlay, which takes
    /// `overlaySizePercent` on both axes. A HUD is two or three lines of text, so sharing one percent across
    /// both axes made every panel as tall as it was wide. Observed — the deck reads it to frame the panel.
    /// Cleared with the rest of the HUD state, never persisted.
    public var hudHeightPercent: Int?

    /// Bumped on every overlay-slot OPEN so the deck can key the panel's view identity on it. A HUD is
    /// REPLACED in place — `closeOverlay` then `openOverlay` inside one store call — so `overlayActive`
    /// never dips to false where SwiftUI can see it. Without a changing identity `makeNSView` is therefore
    /// never re-invoked and `updateNSView` runs against the torn-down view with `overlaySurface` nil.
    /// Observed (the deck reads it while building the panel), ephemeral, never persisted.
    public var overlaySlotGeneration: Int = 0

    /// The HUD occupying the overlay slot, nil when the slot is empty or runs a caller's program. Observed:
    /// the deck reads it to keep the session focusable and to place the panel. Ephemeral, never persisted —
    /// a HUD is a message about work in flight and means nothing after a relaunch.
    public var hudSpec: HudSpec?

    /// Path to the rendered-message file the HUD helper re-reads each tick (`AGTERM_HUD_FILE`); `discardHudBody`
    /// deletes it. Per SESSION, so an update rewrites the path the running helper already opened.
    /// `@ObservationIgnored`: the surface factory, the HUD commands and `overlay close` read it, and none of
    /// them is a view that must re-render when it changes.
    @ObservationIgnored public var hudFile: String?

    /// Drops the HUD: deletes the body file and clears the state describing it. The single owner of that
    /// deletion, so it happens wherever a HUD is discarded — `closeOverlay` and every teardown that discards
    /// the whole session — and not only where a realized surface tears itself down. The file carries the
    /// panel's TEXT under a world-readable `/tmp` path, so a HUD closed before its surface existed must not
    /// leave it there. Deleting it also stops a helper still running against it.
    public func discardHudBody() {
        if let hudFile { try? FileManager.default.removeItem(atPath: hudFile) }
        hudSpec = nil
        hudFile = nil
        hudHeightPercent = nil
    }

    /// Whether the overlay slot holds a HUD rather than a caller's program. The one predicate separating the
    /// two occupants, so the deck's passivity exemptions and the program-overlay questions below cannot
    /// disagree about which is up.
    public var hudActive: Bool { overlayActive && hudSpec != nil }

    /// Whether the overlay slot runs a CALLER'S PROGRAM, either coverage variant. The deck's "a session-wide
    /// cover is up" question: a program overlay owns first responder and mutes the panes under it, a HUD does
    /// neither, so every passivity exemption reads this rather than the raw slot state.
    public var programOverlayActive: Bool { overlayActive && !hudActive }

    /// Whether a FULL-coverage PROGRAM overlay is up: `overlayActive` with no size percent. It hides
    /// everything beneath — the pane(s) AND a shown scratch — so its translucent background reveals the
    /// window backing, never a covered surface: under window translucency every surface renders fully
    /// transparent, so anything left visible below would bleed through. A floating (sized) overlay is not a
    /// cover. `!hudActive` keeps it a question about a running program even if a HUD ever reaches the slot
    /// without a size percent; a HUD covers nothing and must never hide the session behind it.
    public var fullOverlayActive: Bool { overlayActive && !hudActive && overlaySizePercent == nil }

    /// The left pane's overlay, covering that pane only and leaving the sibling live; nil means none is up,
    /// so the slot itself IS the "active" signal. Observed, ephemeral, control-channel only.
    public var leftOverlay: PaneOverlay?

    /// The left pane overlay's surface, created on open and torn down when its command exits or the slot is
    /// closed. `@ObservationIgnored` because `TerminalView` assigns it during view update.
    @ObservationIgnored public var leftOverlaySurface: (any TerminalSurface)?

    /// The left pane overlay program's exit status, kept OUTSIDE `PaneOverlay` so `session.overlay.result`
    /// can still read it after the slot goes nil. Reset on the next open; in-memory only.
    @ObservationIgnored public var leftOverlayExitCode: Int?

    /// The right pane's overlay, the split-pane analogue of `leftOverlay`.
    public var rightOverlay: PaneOverlay?

    /// The right pane overlay's surface (see `leftOverlaySurface`).
    @ObservationIgnored public var rightOverlaySurface: (any TerminalSurface)?

    /// The right pane overlay program's exit status (see `leftOverlayExitCode`).
    @ObservationIgnored public var rightOverlayExitCode: Int?

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

    public init(id: UUID = UUID(), initialCwd: String, customName: String? = nil,
                paneIdentity: UUID = UUID(), splitPaneIdentity: UUID? = nil) {
        self.id = id
        self.paneIdentity = paneIdentity
        self.splitPaneIdentity = splitPaneIdentity
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
    /// focus-aware (cf. `focusedCwd`): it seeds new split, overlay, scratch and quick terminals. A custom
    /// command's `AGT_SESSION_PWD` resolves through `cwd(for:)`, so the right pane's value can differ.
    public var effectiveCwd: String { currentCwd ?? initialCwd }

    /// The working directory for a given pane role: the split pane's while targeting `.right`, else the primary's.
    public func cwd(for pane: CommandContext.Pane) -> String {
        switch pane {
        case .right:
            return splitCwd ?? initialSplitCwd ?? effectiveCwd
        case .left, .scratch:
            return effectiveCwd
        }
    }

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

    /// The pane's overlay, nil when that pane has none.
    public func paneOverlay(_ pane: OverlayPane) -> PaneOverlay? { self[keyPath: pane.overlaySlot] }

    /// The pane overlay's surface, nil before the factory realizes it or after teardown.
    public func paneOverlaySurface(_ pane: OverlayPane) -> (any TerminalSurface)? {
        self[keyPath: pane.surfaceSlot]
    }

    /// The pane overlay program's exit status, surviving the overlay's close so
    /// `session.overlay.result --pane` can report it; nil until one exits or after the next open on that pane.
    public func paneOverlayExitCode(_ pane: OverlayPane) -> Int? { self[keyPath: pane.exitCodeSlot] }

    /// The panes with an overlay up, ordered left then right — the `paneOverlays` tree read-back source.
    public var openPaneOverlays: [OverlayPane] {
        OverlayPane.allCases.filter { paneOverlay($0) != nil }
    }

    /// Which pane owns keyboard focus RIGHT NOW — the single predicate every pane-scoped cover, zoom and
    /// focus decision derives from, so none of them can disagree about which pane the user is looking at.
    /// `.right` needs `splitFocused` AND a right pane that exists: shown side-by-side (`isSplit`, whose
    /// surface may still be unrealized) or hidden-maximized with a live `splitSurface`. Without the second
    /// term a promoted survivor that momentarily re-raised `splitFocused` would resolve `.right` (the
    /// `activeSurface` idiom); without `isSplit` a freshly shown split whose lazy surface has not realized
    /// yet would resolve `.left` while the user's caret sits in the right pane.
    public var focusedPane: OverlayPane {
        splitFocused && (isSplit || splitSurface != nil) ? .right : .left
    }

    /// The focused pane's overlay pane, nil when that pane's slot is empty.
    public var focusedOverlayPane: OverlayPane? {
        let pane = focusedPane
        return paneOverlay(pane) == nil ? nil : pane
    }

    /// Whether the detail pane LAYS THIS PANE OUT at all — the precondition for realizing a surface in it,
    /// since surfaces defer creation until they get a nonzero backing size. Not `deckHostsSurface`, which
    /// also yields a placeholder while zoom or the dashboard owns the slot.
    public func rendersPane(_ pane: OverlayPane) -> Bool {
        isSplit || pane == focusedPane
    }

    /// The panes the detail pane lays out RIGHT NOW, ordered left then right. Derived from the observed
    /// `isSplit`/`splitFocused`, so the deck can watch it for the moment a pane stops being laid out.
    public var renderedPanes: [OverlayPane] {
        OverlayPane.allCases.filter(rendersPane)
    }

    /// Whether ANY host is claiming this pane's overlay slot: the deck lays the pane out, or terminal zoom
    /// targets that overlay surface. The deck is not the only host — while zoom owns a slot `deckHostsSurface`
    /// deliberately returns false for it and the zoom layer mounts the surface instead — and the zoom target
    /// is a claim from the moment it is set, before SwiftUI mounts that layer. `overlay-left`/`overlay-right`
    /// are advertised zoomable as soon as the slot exists (`TerminalZoomSurface.isAvailable`), so a selected
    /// zoom target with a pending host must count.
    public func paneOverlayHosted(_ pane: OverlayPane) -> Bool {
        rendersPane(pane) || TerminalZoomRegistry.shared.targets(sessionID: id, surface: pane.zoomSurface)
    }

    /// Drops a pane overlay that can never come to life: NO host claims its slot AND its terminal was never
    /// realized, so no program was ever started and nothing would ever close the slot —
    /// `session.overlay.result --pane` would answer "overlay still running" forever and `--block` would hang
    /// on it. `openPaneOverlay` only proves the pane renders at REQUEST time; the surface is realized later
    /// by whichever host mounts it, and the pane can stop rendering in between. A REALIZED overlay is left
    /// alone: unmounting its surface keeps the program running and a re-show remounts it. Called wherever
    /// `renderedPanes` or the zoom target can change, so the bad state is torn down instead of described.
    ///
    /// The test is `TerminalSurface.isRealized`, NOT an occupied surface slot: the deck parks the view in the
    /// slot before its terminal is created, and creation defers until the view is sized, so a slot filled in
    /// that gap holds a view with no libghostty surface and no process. `teardownPaneOverlay` frees that
    /// stillborn view too, since a later open on the pane would otherwise reuse it — it is baked with the
    /// RETIRED overlay's command, cwd, and colors.
    public func dropUnrealizedPaneOverlays() {
        for pane in OverlayPane.allCases
        where paneOverlay(pane) != nil && paneOverlaySurface(pane)?.isRealized != true && !paneOverlayHosted(pane) {
            teardownPaneOverlay(pane)
        }
    }

    /// The pane whose overlay slot CURRENTLY holds `surface`, nil when neither does. Derived LIVE from slot
    /// occupancy, like `paneRole(forToken:)`: `promotePaneOverlay` moves the right pane's overlay surface
    /// into the LEFT slot without rebuilding it, so its own exit/status/focus callbacks must ask which slot
    /// they now sit in rather than trust the pane captured when the factory built them — a captured `.right`
    /// would close nothing, record the status on a dead slot, and leave the promoted pane covered forever.
    public func paneOverlayRole(of surface: any TerminalSurface) -> OverlayPane? {
        OverlayPane.allCases.first { paneOverlaySurface($0) === surface }
    }

    /// Frees the pane's overlay outright: tears the surface down and clears the slot, the surface, AND the
    /// exit code. Used where the PANE ITSELF goes away, unlike `AppStore.closePaneOverlay`, which keeps the
    /// exit code readable by `session.overlay.result`; here no pane survives to be asked. `teardown()` nils
    /// the surface's store-capturing callbacks, breaking the store/session/surface/closure cycle.
    public func teardownPaneOverlay(_ pane: OverlayPane) {
        paneOverlaySurface(pane)?.teardown()
        setPaneOverlay(nil, pane: pane)
        setPaneOverlaySurface(nil, pane: pane)
        setPaneOverlayExitCode(nil, pane: pane)
    }

    /// The pane-slot writers, paired with the `paneOverlay*` readers through `OverlayPane`'s key paths.
    public func setPaneOverlay(_ overlay: PaneOverlay?, pane: OverlayPane) {
        self[keyPath: pane.overlaySlot] = overlay
    }

    public func setPaneOverlaySurface(_ surface: (any TerminalSurface)?, pane: OverlayPane) {
        self[keyPath: pane.surfaceSlot] = surface
    }

    public func setPaneOverlayExitCode(_ code: Int?, pane: OverlayPane) {
        self[keyPath: pane.exitCodeSlot] = code
    }

    /// Frees BOTH pane overlays; the whole-session form of `teardownPaneOverlay(_:)`, called wherever the
    /// session is discarded alongside the `overlaySurface?.teardown()` for the session-wide overlay.
    public func teardownPaneOverlays() {
        OverlayPane.allCases.forEach { teardownPaneOverlay($0) }
    }

    /// Moves the right pane's overlay — slot, surface, and exit code together — into the left slot, following
    /// the split survivor `closePrimaryPane` promotes into the primary pane, so the overlay keeps covering the
    /// same shell. The left slot must already be freed. The surface MOVES rather than being rebuilt, so its
    /// callbacks re-resolve their pane through `paneOverlayRole(of:)` instead of a captured one.
    public func promotePaneOverlay() {
        setPaneOverlay(rightOverlay, pane: .left)
        setPaneOverlaySurface(rightOverlaySurface, pane: .left)
        setPaneOverlayExitCode(rightOverlayExitCode, pane: .left)
        setPaneOverlay(nil, pane: .right)
        setPaneOverlaySurface(nil, pane: .right)
        setPaneOverlayExitCode(nil, pane: .right)
    }

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

    /// Takes the pane's transient captured foreground command, clearing it so it fires once. Same
    /// consume-on-read rule as `takePendingRestoreOverride(pane:)`, and for the same reason: a leftover
    /// payload would fire again when `makeSplitSurface` runs on a fresh ⌘D mid-session. `.scratch` is
    /// never restored.
    public func takePendingForegroundCommand(pane: StatusPane) -> [String]? {
        switch pane {
        case .left:
            let pending = pendingForegroundCommand
            pendingForegroundCommand = nil
            return pending
        case .right:
            let pending = pendingSplitForegroundCommand
            pendingSplitForegroundCommand = nil
            return pending
        case .scratch:
            return nil
        }
    }

    /// Drops the unconsumed CAPTURE payloads only, leaving the persisted and pending `session.restore` pins
    /// armed. The pending half of `clearCapturedForegroundCommands()`; public because agterm-linux calls it.
    public func clearPendingForegroundCommands() {
        pendingForegroundCommand = nil
        pendingSplitForegroundCommand = nil
    }

    /// Drops the captured foreground commands whole: the persisted pair AND the unconsumed pending pair.
    /// `restore.clear` and a non-last window close both need exactly this, over different session sets.
    /// `.claude/rules/settings.md` covers why the persisted fields cannot be dropped on their own.
    public func clearCapturedForegroundCommands() {
        foregroundCommand = nil
        splitForegroundCommand = nil
        clearPendingForegroundCommands()
    }

    /// Drops every unconsumed bootstrap payload — both override pins and both captured commands — leaving
    /// the persisted fields alone. Called where a live `Session` leaves the tree but may return as the SAME
    /// object (the soft-close grace window): a payload armed at bootstrap would otherwise survive the round
    /// trip and fire when its surface is rebuilt.
    public func clearPendingRestoreOverrides() {
        pendingRestoreCommand = nil
        pendingSplitRestoreCommand = nil
        clearPendingForegroundCommands()
    }

    /// The surface on top and owning keyboard focus: an active PROGRAM overlay (full OR floating), else the
    /// scratch, else the focused pane's own overlay, else the active pane. The overlay renders above the
    /// scratch, and a full overlay or the scratch covers the panes (INCLUDING their pane overlays), so
    /// session-focus helpers route through this to keep first responder off a covered surface — except
    /// `TerminalView.focusIfNeeded`, which targets its own deck slot, already gated by `isActive`. nil while a
    /// pane overlay's slot is open but its surface has not realized yet; the bounded focus retries re-resolve
    /// a beat later.
    ///
    /// A HUD in the slot is SKIPPED, which is what keeps it passive: roughly eight app focus-routing sites
    /// read this (sidebar click, session selection, overlay-close refocus), and handing any of them the HUD
    /// helper would take first responder off the session the message is about — the deck's exemptions one
    /// layer down.
    public var topmostSurface: (any TerminalSurface)? {
        if programOverlayActive { return overlaySurface }
        if scratchActive { return scratchSurface }
        if let pane = focusedOverlayPane { return paneOverlaySurface(pane) }
        return activeSurface
    }

    /// Where pane-focus moves first responder when asked for `wantSplit`: under a session-wide cover the
    /// requested pane is hidden, so stay on `topmostSurface`; else the pane's OWN overlay when one covers it,
    /// so `session.focus right` cannot make a covered pane first responder; else the pane itself. Returns nil
    /// for a covering pane overlay whose surface has not realized yet, leaving the retry to re-resolve.
    /// A HUD is no cover, so the requested pane stays reachable while one is up.
    public func focusTarget(wantSplit: Bool) -> (any TerminalSurface)? {
        if programOverlayActive || scratchActive { return topmostSurface }
        let pane: OverlayPane = wantSplit ? .right : .left
        if paneOverlay(pane) != nil { return paneOverlaySurface(pane) }
        return wantSplit ? splitSurface : surface
    }

    /// The pane-or-scratch surface actually ON SCREEN: the scratch when it covers the panes with no program
    /// overlay up, else the focused pane — so `session.text` (no `--pane`) and `session.search` hit the
    /// scratch, not the pane beneath. A program overlay routes via `topmostSurface`; this stays
    /// pane-vs-scratch, like `searchTarget`, and a HUD leaves the scratch on screen underneath it.
    public var onScreenSurface: (any TerminalSurface)? {
        scratchActive && !programOverlayActive ? topmostSurface : activeSurface
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
