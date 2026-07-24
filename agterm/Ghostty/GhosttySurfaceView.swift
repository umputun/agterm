// adapted from thdxg/macterm (MIT)

import agtermCore
import AppKit
import GhosttyKit
import QuartzCore

/// A Metal-backed NSView hosting one libghostty surface (one shell). Conforms to
/// `TerminalSurface` so the host-free `Session` can own it without importing
/// GhosttyKit/AppKit.
///
/// `surface` and the `configCStrings` strdup buffers are `nonisolated(unsafe)`:
/// they are mutated only on the main actor (create/destroy) and the C callbacks
/// that read them are serialized by libghostty's tick model.
final class GhosttySurfaceView: NSView, TerminalSurface {
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    private let workingDirectory: String

    /// The command the surface runs as its process instead of the login shell, or nil for the login
    /// shell. A creation input (like `workingDirectory`): read in `createSurface`. Used by the overlay
    /// surface to run one program (e.g. a TUI) whose exit closes the overlay.
    private let command: String?

    /// Text fed to the pty as if typed at startup (libghostty `initial_input`), or nil for none. Used by
    /// the restore-running-command feature: the captured foreground command line + `\n`, so a restored
    /// login shell re-runs it and returns to a prompt on exit (UNLIKE `command`, which replaces the shell).
    private let initialInput: String?

    /// Whether, when a `command` exits, libghostty keeps the surface open with its "press any key to
    /// close" prompt (`true`) instead of closing immediately (`false`). Only meaningful with `command`.
    private let waitAfterCommand: Bool

    /// Whether this surface grabs first responder as soon as it is created. The overlay needs it: it is
    /// added on top of an already-focused session, and `TerminalView.focusIfNeeded` only grabs focus if
    /// the view is in a window at the first `updateNSView` — which the deferred overlay surface is not,
    /// and no later update fires. So the overlay focuses itself once its surface exists (in a window).
    private let autoFocus: Bool

    /// The initial font size in points to create the surface with, or nil to use the
    /// ghostty config default. A creation input (like `workingDirectory`): read in
    /// `createSurface`, which may run after construction, so it's fixed at init. Not `private` so the
    /// `+Config` extension (which owns `applyOverlayBackgroundColor`) can read it.
    let initialFontSize: Float?

    /// Extra environment variables (the `AGTERM_*` vars) the spawned shell sees, set into the surface
    /// config at creation. A creation input (like `workingDirectory`): read in `createSurface`.
    let env: [String: String]

    /// The owning model session. `weak` to avoid a retain cycle: the `Session`
    /// strongly owns this surface via `Session.surface`. Set by the app's surface
    /// factory after construction.
    weak var session: Session?

    /// The session whose per-session visual config this surface inherits when it deliberately has no
    /// `session`. Scratch surfaces use this separate weak link so they can render the owning session's
    /// watermark without letting their OSC title/PWD reports mutate the session model. Nil for overlays
    /// and quick terminals; main/split surfaces use `session` directly.
    weak var watermarkSession: Session?

    /// Whether this surface is the session's split (right) pane rather than the primary. Set by the
    /// split factory; routes `applyPwd`/`applyTitle` to `session.splitCwd`/`splitTitle` so the split
    /// pane's reports don't clobber the primary's, and clears back to false when the pane is promoted
    /// to primary on collapse.
    var isSplitPane = false

    /// Whether this surface has the search lifecycle callbacks wired (the main/split AND scratch factories
    /// set it). Only these surfaces drive a visible bar and the END close path, so `AppActions.toggleSearch`
    /// refuses to start search on a quick-terminal/overlay surface that lacks them (which would otherwise
    /// enter libghostty search mode with no bar and no way to close).
    var isSearchable = false

    /// Called on the main actor when the shell process exits, so the app can
    /// close the owning session (free the surface and drop the sidebar row). Set
    /// by the app's surface factory.
    var onExit: (() -> Void)?

    /// For a capturing overlay surface: the temp file the command wrapper writes its exit status to
    /// (`echo $? > file`). libghostty's child-exited status reflects the login-shell wrapper (always 0),
    /// so the real command status is captured via the wrapper instead. Read in `destroySurface` (every
    /// teardown path) and then deleted, so the file's lifetime tracks the surface — no registry or sweep.
    /// nil for non-capturing surfaces.
    var overlayCodeFile: String?

    /// For an OVERLAY surface: its own solid background color as `#rrggbb` (`session.overlay.open
    /// --background-color`), or nil for the default theme background. Applied in `createSurface` once the
    /// surface exists — the overlay carries no `session`, so the session-watermark path skips it. Set by
    /// the overlay factory from `Session.overlayBackgroundColor`.
    var overlayBackgroundColorHex: String?

    /// The dynamic background color a program set on THIS surface via OSC 11 (`#rrggbb`), or nil for none.
    /// Rendered per-pane by `applyOSCBackground` (which carries the detail).
    var oscBackgroundColorHex: String?

    /// For a capturing overlay surface: receives the parsed exit status read from `overlayCodeFile` on
    /// teardown. Set by the overlay factory to record it onto the session for `session.overlay.result`.
    /// Called from `destroySurface` (main actor) on every in-process teardown, so the status is captured
    /// without depending on `onExit` (e.g. an explicit `session.overlay.close`). For a session/window
    /// force-close the recording no-ops (the session is already gone), but the result is then unqueryable
    /// anyway; the temp file is deleted regardless.
    var onExitCodeCaptured: ((Int) -> Void)?

    /// Called on the main actor when this surface gains (`true`) or loses (`false`) first
    /// responder, so the app can track which split pane is active. Set by the factory.
    var onFocusChange: ((Bool) -> Void)?
    /// Rehosting for terminal zoom must update libghostty focus without changing app model state such as
    /// the focused split pane. `TerminalView` flips this while the surface is hosted in the zoom layer.
    var suppressFocusChange = false
    /// Called on the main actor to clear the session's unseen badge + delivered banners WITHOUT the
    /// `splitFocused` write that rides `onFocusChange(true)` — the refocus-clear path for a zoom-hosted
    /// surface, where the focus report is suppressed but the user is demonstrably looking at the session.
    /// Set by the main/split factories alongside `onFocusChange`.
    var onClearUnseen: (() -> Void)?

    /// Called on the main actor on EVERY keystroke into this surface, carrying whether the key interrupts
    /// the agent (Escape or Ctrl-C). The factory's closure owns the pane-scoped decision (via
    /// `AgentIndicator.clearedBy(pane:isInterrupt:)`): it clears the glyph to idle only when THIS surface's
    /// pane owns a clearable status — `blocked`/`completed` on any key (you've engaged with the prompt /
    /// finished result), `active` only on an interrupt keystroke. Typing in a foreground pane therefore no
    /// longer wipes a background pane's block. Passing the pane in the closure (not reading `view.session`)
    /// is what lets the scratch surface — which has no `view.session` — self-clear its own block. The status
    /// is otherwise control-driven; this is the one input-driven clear, covering the decline case Claude
    /// Code fires no hook for.
    var onUserInputClearsStatus: ((Bool) -> Void)?

    /// Called on the main actor on EVERY keystroke into this surface, so the app can stamp user activity
    /// and reset the window's auto-follow idle timer. Unlike `onUserInputClearsStatus` (which fires only on
    /// a status-clearing key), this fires unconditionally — ordinary typing in an idle session must count as
    /// activity or the user would be yanked to a blocked session mid-type. Set by the factory to call the
    /// owning window's `AppStore.noteUserActivity()`.
    var onUserInput: (() -> Void)?

    /// Called on the main actor with the surface's current font size (points) when it
    /// changes (cmd +/-), so the app can persist it. Set by the factory on the primary
    /// surface only. libghostty has no font-size getter or change event, so this is driven
    /// off the CELL_SIZE action and reads the size via `ghostty_surface_inherited_config`.
    var onFontSizeChange: ((Double) -> Void)?

    /// Called on the main actor when libghostty enters search mode (START_SEARCH), carrying the current
    /// needle (nil when none). The factory wires this to toggle the session's search bar — if the bar is
    /// already visible it sends `end_search` (the ⌘F-again close), else it opens the bar and seeds the
    /// needle. Set by the main/split surface factory.
    var onSearchStart: ((String?) -> Void)?

    /// Called on the main actor when libghostty exits search mode (END_SEARCH). The factory wires this to
    /// clear the session's search fields, hide the bar, and return first responder to the terminal. Set by
    /// the main/split surface factory.
    var onSearchEnd: (() -> Void)?

    /// Called on the main actor with the total match count (SEARCH_TOTAL), or nil when libghostty reports a
    /// negative count (no query). The factory wires this to the session's `searchTotal`. Set by the
    /// main/split surface factory.
    var onSearchTotal: ((Int?) -> Void)?

    /// Called on the main actor with the 1-based index of the selected match (SEARCH_SELECTED), or nil when
    /// libghostty reports a negative index. The factory wires this to the session's `searchSelected`. Set by
    /// the main/split surface factory.
    var onSearchSelected: ((Int?) -> Void)?

    /// Heap buffers backing the `const char*` fields of the surface config —
    /// notably `initial_input`, which libghostty writes to the pty
    /// asynchronously after the child spawns, so the buffer must outlive
    /// `ghostty_surface_new`. Retained here and freed in `destroySurface`.
    nonisolated(unsafe) private var configCStrings: [UnsafeMutablePointer<CChar>] = []

    /// The `ghostty_env_var_s` structs handed to the surface config via `config.env_vars`. Each
    /// struct's `key`/`value` point into the `configCStrings` strdup buffers (same lifetime). This
    /// array must itself outlive `ghostty_surface_new`, so it's retained on the instance (a stored
    /// property, not a local), and cleared in `destroySurface`/`deinit` alongside the strdup frees.
    /// `nonisolated(unsafe)`: mutated only on the main actor (create/destroy), like `configCStrings`.
    nonisolated(unsafe) private var envVars: [ghostty_env_var_s] = []

    /// Per-surface ghostty configs built for this surface's background watermark (`configWithOverlay`),
    /// retained so they outlive their `ghostty_surface_update_config`. Capped at ONE: each re-apply
    /// (`set`/`clear`/`config.reload`) frees the prior and keeps only the current, since after
    /// `update_config` the surface no longer references the old config — so a scriptable `config.reload`
    /// loop can't grow it. The remaining one is freed in `destroySurface`/`deinit`, when the surface (its
    /// only consumer) is gone, so that free is safe too (unlike the app-wide config `GhosttyApp` never frees).
    /// `nonisolated(unsafe)`: mutated only on the main actor, like `configCStrings`. Not `private` so the
    /// `+Config` extension (which owns `applyWatermarkFromSession`/`applyOverlayBackgroundColor`) can read/write it.
    nonisolated(unsafe) var ownedConfigs: [ghostty_config_t] = []

    /// Key-window observers (didBecomeKey/didResignKey). A surface in a background window must report an
    /// unfocused (hollow) cursor, but AppKit first responder is per-window and does NOT resign when a
    /// window merely loses key, so we watch key changes and re-push `liveFocus`. Removed on teardown.
    /// `nonisolated(unsafe)`: mutated only on the main actor (register/destroy), like `configCStrings`,
    /// but read in the nonisolated `deinit` safety net.
    nonisolated(unsafe) private var focusObservers: [NSObjectProtocol] = []
    private var pendingSurfaceCreation = false
    /// Once destroySurface() runs this view is "retired": it must never
    /// recreate a surface (e.g. from a stray viewDidMoveToWindow).
    private var isDestroyed = false

    /// Guards `handleProcessExit` so the close runs once. Both the `SHOW_CHILD_EXITED` action and the
    /// `close_surface_cb` can fire for one exit (ghostty documents no ordering/exclusivity between them).
    private var didHandleProcessExit = false

    /// Auto-focus retry state (the overlay path). `makeFirstResponder` loses to the SwiftUI/AppKit
    /// responder race if called once too early, so it retries on the run loop until it sticks.
    private var autoFocusInFlight = false
    private var didAutoFocus = false
    private static let autoFocusMaxAttempts = 40
    private static let autoFocusRetryInterval: TimeInterval = 0.05

    /// Whether this surface's deck slot is the active (selected) session. The overlay/scratch auto-focus
    /// path grabs first responder when the surface attaches, so without this gate a full overlay (or scratch)
    /// opened in a BACKGROUND, non-selected session would steal keyboard input from the visible session.
    /// `TerminalView` sets it before `createSurface` so `requestAutoFocus` fires only for the active slot, and
    /// a slot going inactive mid-retry makes the loop bail. Main/split panes never auto-focus, so it's inert
    /// for them; they take focus through `TerminalView.focusIfNeeded`, which is already active-gated.
    var deckActive = true

    /// Whether this surface's deck slot is on-screen (its session is selected and not hidden by a full
    /// overlay/scratch). UNLIKE `deckActive`, this is NOT focus-gated: both panes of a visible split are
    /// `deckVisible`. `TerminalView` sets it from the deck. Load-bearing for drag-and-drop: every session's
    /// surface is eagerly realized, and SwiftUI's `.opacity(0)`/`.allowsHitTesting(false)` on inactive deck
    /// panes do NOT reach AppKit's drag machinery (the NSView keeps `alphaValue == 1`, and AppKit's
    /// drag-destination resolution does NOT consult `hitTest`), so if every surface stayed a registered
    /// drag target a file drop would land on whichever is topmost in z-order — an INVISIBLE background
    /// session — instead of the one under the cursor. `didSet` (un)registers the drag types to fix that,
    /// and (dis)installs the mouse-tracking area for the same reason (see `updatePointerTracking`).
    var deckVisible = true {
        didSet {
            // `TerminalView` assigns this on every SwiftUI update pass, so skip the tracking-area teardown/
            // rebuild + drag re-registration unless the visibility actually flipped.
            guard deckVisible != oldValue else { return }
            updateDropRegistration()
            updatePointerTracking()
        }
    }

    /// View-only mode: the surface is rendered but takes NO mouse or keyboard input (the dashboard grid
    /// cell). SwiftUI's `.allowsHitTesting(false)` does NOT stop AppKit routing a click to this real NSView
    /// (the same reason `deckVisible` gates drag registration — AppKit's hit resolution bypasses SwiftUI),
    /// so a click would reach `mouseDown` and grab first responder, defeating the view-only dashboard and
    /// stealing the keyboard from its key-catcher. When set, `hitTest` returns nil (clicks fall through to
    /// the SwiftUI cell overlay) and the surface refuses first responder, so keystrokes never reach it.
    /// `TerminalView` sets it; the dashboard cell turns it on and the deck slot turns it back off on the
    /// same reparent.
    var viewOnly = false {
        didSet {
            guard viewOnly, !oldValue else { return }
            // acceptsFirstResponder=false only blocks NEW grabs — a surface that carried first responder in
            // from the deck (the focused split pane when the dashboard opened) keeps it across the
            // reparent-within-window, so keystrokes reach the cell and defeat the dashboard's key-catcher.
            // Resign it here; once view-only, nothing can re-grab it, so the key-catcher owns the keyboard.
            if let window, window.firstResponder === self { window.makeFirstResponder(nil) }
        }
    }

    /// Register the file/text drag types only while this surface is the on-screen deck pane; unregister
    /// otherwise, so an eagerly-realized background surface is not a drag target and a drop can only reach
    /// the visible pane. Called from `deckVisible`'s didSet and once from `createSurface` (didSet does not
    /// fire for the initializer default).
    private func updateDropRegistration() {
        if deckVisible {
            registerForDraggedTypes([.fileURL, .string, .URL])
        } else {
            unregisterDraggedTypes()
        }
    }

    /// Transient dashboard font size in points that overrides `session.fontSize` for this surface while it
    /// is hosted in a dashboard grid cell; nil = not overriding. The composer prefers it,
    /// `reapplySessionConfigIfNeeded` re-emits it across a config reload, and `reportFontSize` won't persist
    /// it (so a CELL_SIZE round-trip can't write the transient size into `session.fontSize`). Writing it
    /// re-composes the surface config — a value shrinks the cell's font, nil rebuilds from the session model.
    var dashboardFontOverride: Double? {
        didSet {
            // keep a live OSC 11 tint across dashboard open/close (applyOSCBackground re-emits it with the dashboard font); else rebuild from the session model.
            if let hex = oscBackgroundColorHex { applyOSCBackground(hex) } else { applyWatermarkFromSession() }
            // a SET override (-> value) can't strand a revert report — reportFontSize's
            // `dashboardFontOverride == nil` guard drops its CELL_SIZE report while the override is active
            // — so just drop any pending restore.
            guard dashboardFontOverride == nil, let cleared = oldValue else { pendingFontRestore = nil; return }
            // CLEARING the override reverts the surface to session.fontSize (the app default when nil). that
            // fires a CELL_SIZE report ~0.4s LATER (async), long after any same-runloop latch would clear.
            // when session.fontSize is nil, persisting that report would PIN the session to the default and
            // stop it following a later Settings change. remember the size the surface reverts to so
            // reportFontSize consumes THAT report without persisting. only arm when the font actually changes
            // — an override equal to the target emits no report and would leak the flag onto a later zoom.
            let target = session?.fontSize ?? GhosttyApp.shared.baseFontSize
            pendingFontRestore = abs(cleared - target) > 0.5 ? target : nil
        }
    }

    /// The font size (points) the surface reverts to when `dashboardFontOverride` is CLEARED — the value
    /// the async CELL_SIZE report for that revert will carry. Set in the override's `didSet`, consumed by
    /// `reportFontSize`, which drops the matching report WITHOUT persisting so restoring the dashboard grid
    /// font never pins a default-following session's `session.fontSize`. State (not a one-runloop latch), so
    /// it survives the ~0.4s gap before the report arrives.
    private var pendingFontRestore: Double?

    // IME composition state shared with GhosttySurfaceView+Input.swift (stored properties can't live in an extension).
    var _markedRange = NSRange(location: NSNotFound, length: 0)
    var _selectedRange = NSRange(location: NSNotFound, length: 0)
    var keyTextAccumulator: [String] = []
    var currentKeyEvent: NSEvent?

    // the pointer's mouse-tracking area, managed by GhosttySurfaceView+Tracking.swift (a stored property
    // can't live in an extension, so it stays here as internal rather than private).
    var currentTrackingArea: NSTrackingArea?

    /// The mouse-cursor shape libghostty last requested for this surface (`GHOSTTY_ACTION_MOUSE_SHAPE`):
    /// the I-beam over the grid, the pointing hand over a detected link / OSC-8 hyperlink, resize/crosshair
    /// in the matching modes. `cursorUpdate` maps it to an `NSCursor`. Defaults to the terminal I-beam
    /// so the resting cursor is right before the first event. Not `private` so the `+Input` extension (which
    /// owns the `cursorUpdate` override and `applyMouseShape`) can read it.
    var mouseShape: ghostty_action_mouse_shape_e = GHOSTTY_MOUSE_SHAPE_TEXT

    /// Whether the pointer is inside this surface (from `mouseEntered`/`mouseExited`), gating the immediate
    /// `.set()` in `applyMouseShape` so a revert delivered after the pointer left can't leak onto the sidebar.
    var pointerInside = false

    /// The last pointer position pushed to libghostty via `ghostty_surface_mouse_pos` (view-flipped
    /// coordinates), or nil before the first report. `scrollWheel` syncs the position only when the current
    /// point differs from this, so a normal already-synced scroll doesn't re-push the same cell on every
    /// packet — which in an any-motion + sgr-pixel mouse-reporting TUI would emit a synthetic motion report
    /// per packet. Not `private` so the `+Input` extension (which owns the mouse handlers) can read/write it.
    var lastReportedMousePoint: NSPoint?

    init(workingDirectory: String, fontSize: Float? = nil, command: String? = nil, initialInput: String? = nil,
         waitAfterCommand: Bool = false, autoFocus: Bool = false, env: [String: String] = [:]) {
        self.workingDirectory = workingDirectory
        self.initialFontSize = fontSize
        self.command = command
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
        self.autoFocus = autoFocus
        self.env = env
        super.init(frame: .zero)
        wantsLayer = true
        setupTrackingArea()
        observeKeyWindowChanges()
    }

    /// Watch every window's key transitions and re-evaluate this surface's focus on each. No need to
    /// filter to my own window: `updateGhosttyFocus` reads `self.window.isKeyWindow`, so on any key change
    /// each surface reports its OWN current state (a background window's surface goes hollow, the new key
    /// window's active surface goes solid). Observing all windows also survives a re-host into another one.
    private func observeKeyWindowChanges() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            let becameKey = name == NSWindow.didBecomeKeyNotification
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateGhosttyFocus()
                    // returning focus to agterm (cmd-tab or a reactivating click) while this pane is the
                    // one on screen counts as "seeing" the session — clear its unseen badge, the same as a
                    // focus transition does. becomeFirstResponder can't cover this: AppKit's per-window
                    // first responder never resigned while agterm was backgrounded, so no focus transition
                    // fires on return, leaving the badge stuck until you switch sessions and back.
                    if becameKey {
                        self.reassertCursorOnActivation()
                        self.clearUnseenOnRefocus()
                    }
                }
            }
            focusObservers.append(token)
        }
    }

    /// Clear the "you've seen it" state (unseen badge + delivered banners) for this pane's session when
    /// agterm regains key focus on it — the inverse of notification suppression (which drops a banner only
    /// when the firing pane is the key window's first responder AND the app is active). `liveFocus` already
    /// encodes both: a window is key only while the app is active, so it fires solely for the focused pane of
    /// the now-key window, never a background one. Reuses `onFocusChange`, so it clears exactly for the
    /// main/split panes that already clear on a focus transition (a scratch/overlay has no `onFocusChange`
    /// and doesn't clear on focus either), and no-ops after teardown (the closure is nil'd).
    /// Honors `suppressFocusChange` like the first-responder call sites: a zoom-hosted surface is first
    /// responder of the key window, so `onFocusChange?(true)` here would mutate `splitFocused` on every
    /// window-key regain — the model change the zoom host suppresses on the other two paths. The unseen
    /// badge must still clear, though (the user is looking at exactly this surface), so the suppressed
    /// branch takes the focus-free `onClearUnseen` path instead of dropping the clear.
    private func clearUnseenOnRefocus() {
        guard liveFocus else { return }
        if suppressFocusChange {
            onClearUnseen?()
        } else {
            onFocusChange?(true)
        }
    }

    /// The cursor-focus state to report to libghostty: solid only when this surface is the first responder
    /// of its window AND that window is key. The key-window gate is what stops every window's active surface
    /// from blinking at once. Reading the live responder (not a cached flag) also means a re-hosted pane
    /// reports its true focus, so opening a split can't leave both panes solid.
    private var liveFocus: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    /// Push `liveFocus` to libghostty (no-op before the surface exists; `createSurface` calls this once the
    /// surface is up). Used on window-key changes, surface (re)attach, and the auto-focus/reparent grabs.
    /// First-responder transitions push directly, because the live `window.firstResponder` is not yet
    /// updated to self inside `becomeFirstResponder`/`resignFirstResponder`.
    func updateGhosttyFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, liveFocus)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        // free directly here, not via destroySurface(): deinit is nonisolated and
        // can't call the @MainActor method. surface/configCStrings are
        // nonisolated(unsafe) and freed with C calls, so this is safe. (Normal
        // teardown goes through destroySurface() on the main actor; this is the
        // safety net for a view dropped without an explicit close.)
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let surface { ghostty_surface_free(surface) }
        configCStrings.forEach { free($0) }
        envVars = []
        // free the retained per-surface watermark configs (safe now the surface is gone — see ownedConfigs).
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = []
        if let f = overlayCodeFile { try? FileManager.default.removeItem(atPath: f) }
    }

    // MARK: - Callback entry points

    func applyPwd(_ rawPwd: String) {
        // Already on the main actor (the callback hops via DispatchQueue.main.async).
        // `currentCwd` is observed, so the sidebar row refreshes live.
        //
        // Strip control characters from the OSC 7 value first: it flows unquoted into a /bin/sh -c
        // line via {AGT_SESSION_PWD} and into every cwd-inheriting spawn (split/overlay/restore), so a
        // newline (an sh -c command separator) must never survive; a real path has no control chars.
        let pwd = TerminalText.sanitized(rawPwd)

        // This deliberately does NOT save(): OSC 7 fires on every cd/prompt redraw,
        // so persisting here would thrash the disk. Live cwd is persisted on quit
        // and on structural mutations (add/close/move/rename/select), not on every
        // cd, so a crash/force-quit loses only cwd changes since the last save.
        //
        // Guard on a real value change: OSC 7 re-emits the same pwd on every prompt
        // redraw, so an equal write would still notify @Observable observers and churn
        // the sidebar reconcile for nothing.
        if isSplitPane {
            if session?.splitCwd != pwd { session?.splitCwd = pwd }
        } else {
            if session?.currentCwd != pwd { session?.currentCwd = pwd }
        }
    }

    func applyTitle(_ rawTitle: String) {
        // Already on the main actor (the callback hops via DispatchQueue.main.async).
        // `oscTitle`/`splitTitle` are observed, so the sidebar row and window title refresh live. Like
        // applyPwd, this deliberately does NOT save(): OSC set-title re-fires on every prompt redraw.
        //
        // Strip control characters from the OSC 0/1/2 title first: it flows unquoted into a /bin/sh -c
        // line via {AGT_SESSION_NAME}, so a newline (an sh -c command separator) must never survive; a
        // real title has no control chars.
        let title = TerminalText.sanitized(rawTitle)

        // Guard on a real value change so an equal re-emit doesn't notify observers and churn the sidebar.
        if isSplitPane {
            if session?.splitTitle != title { session?.splitTitle = title }
        } else {
            if session?.oscTitle != title { session?.oscTitle = title }
        }
    }

    func handleProcessExit() {
        // Already on the main actor (the close callbacks hop via DispatchQueue.main.async). Ask the app
        // to close the owning session/overlay, which tears down this surface and removes its sidebar row.
        // Idempotent: the SHOW_CHILD_EXITED action and close_surface_cb can both fire for one exit.
        guard !didHandleProcessExit else { return }
        didHandleProcessExit = true
        onExit?()
    }

    /// Whether a child-exit should close this surface immediately (suppressing ghostty's "press any key"
    /// prompt). True only for a command surface (the overlay) that did NOT opt into the wait prompt; a
    /// `waitAfterCommand` overlay keeps the prompt and closes via `close_surface_cb` after the keypress.
    /// `nonisolated` so the C action callback can read it without a main-actor hop; both backing fields
    /// are immutable `let`s set in `init`, so the read is data-race-free.
    nonisolated var shouldCloseOnChildExitAction: Bool { command != nil && !waitAfterCommand }

    func reportFontSize() {
        // already on the main actor (the CELL_SIZE callback hops via DispatchQueue.main.async).
        // while a dashboard font override is active, don't persist: it would write the transient dashboard
        // size into session.fontSize.
        guard dashboardFontOverride == nil else { return }
        // currentFontSize reads the surface's live font size; nil means libghostty hasn't resolved one yet.
        guard let size = currentFontSize() else { return }
        // clearing the override reverts the surface font and fires its own CELL_SIZE report ~0.4s later
        // (see dashboardFontOverride.didSet): drop the one whose size matches the reverted-to value so a
        // default-following session isn't pinned, then clear the flag so a later genuine zoom persists.
        if let pending = pendingFontRestore {
            pendingFontRestore = nil
            if abs(size - pending) <= 0.5 { return }
        }
        onFontSizeChange?(size) // the store no-ops a same-value write.
    }

    /// Draws the surface now, servicing libghostty's `GHOSTTY_ACTION_RENDER` demand. Main-actor.
    func renderNow() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    // MARK: - Surface lifecycle

    func createSurface() {
        guard !isDestroyed else { return }
        // register as a file drop target (issue #51) only while on-screen, so a background deck surface
        // can't intercept the drop (see updateDropRegistration). idempotent across re-entry (createSurface
        // re-runs when a deferred surface finally gets a backing size).
        updateDropRegistration()
        guard surface == nil, let app = GhosttyApp.shared.app else { return }
        let backingSize = convertToBacking(bounds).size
        guard backingSize.width > 0, backingSize.height > 0 else {
            pendingSurfaceCreation = true
            return
        }
        pendingSurfaceCreation = false

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)

        // The strdup'd working_directory buffer must stay valid for the
        // duration of the call; retained on the instance and freed in
        // destroySurface (the same contract initial_input needs later).
        configCStrings.forEach { free($0) }
        configCStrings = []
        if let p = strdup(workingDirectory) {
            configCStrings.append(p)
            config.working_directory = UnsafePointer(p)
        }
        // a command runs as the surface's process (the overlay's one program) instead of the login
        // shell; its strdup'd buffer joins the same `configCStrings` lifetime as working_directory.
        // wait_after_command controls whether the surface lingers on the "press any key" prompt when
        // the command exits; default false so the overlay vanishes immediately (opt-in via the API).
        if let command, let p = strdup(command) {
            configCStrings.append(p)
            config.command = UnsafePointer(p)
            config.wait_after_command = waitAfterCommand
        } else {
            config.command = nil // login shell
        }
        // restore-running-command: feed the captured command line to the login shell as if typed, so it
        // re-runs and exits back to a prompt. Same strdup'd-buffer lifetime as working_directory. Mutually
        // exclusive with `command` (which REPLACES the shell): a command surface ignores initialInput, so
        // the invariant is enforced here, not just by caller discipline.
        if command == nil, let initialInput, let p = strdup(initialInput) {
            configCStrings.append(p)
            config.initial_input = UnsafePointer(p)
        }
        // a persisted/restored size overrides the config default; nil leaves
        // config_new's default (the ghostty config font-size) in place.
        if let initialFontSize { config.font_size = initialFontSize }

        // extra environment for the spawned shell (the AGTERM_* vars). Each key/value is strdup'd into
        // the same `configCStrings` lifetime as working_directory; the `ghostty_env_var_s` structs
        // pointing at those buffers are retained in `envVars` (a stored property, value-type, so it
        // can't live in `configCStrings`).
        envVars = []
        for (key, value) in env {
            guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
            configCStrings.append(keyPtr)
            configCStrings.append(valuePtr)
            envVars.append(ghostty_env_var_s(key: UnsafePointer(keyPtr), value: UnsafePointer(valuePtr)))
        }
        // set the app color scheme to the current appearance BEFORE creating the surface: a new surface
        // derives its initial theme from the app's conditional state (`ghostty_surface_new` reads it), so
        // a dual `theme = light:,dark:` renders the correct side from the FIRST frame instead of defaulting
        // to light and only correcting on a later reload. Read the APP-level side (`currentIsDark()`, i.e.
        // `NSApp.effectiveAppearance`) — the single source the KVO observer also feeds, not this view's own
        // `effectiveAppearance`. `set_color_scheme` records the state; it early-returns when unchanged.
        let isDark = GhosttyApp.currentIsDark()
        ghostty_app_set_color_scheme(app, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)

        // create the surface with `config.env_vars` pointing at the retained `envVars` storage. The
        // pointer is taken inside `withUnsafeMutableBufferPointer` AND `ghostty_surface_new` runs in
        // the same closure, so it's never used past the call (no escaping-pointer UB); ghostty copies
        // the env at creation. No-env surfaces take the plain path.
        if envVars.isEmpty {
            surface = ghostty_surface_new(app, &config)
        } else {
            surface = envVars.withUnsafeMutableBufferPointer { buf in
                config.env_vars = buf.baseAddress
                config.env_var_count = buf.count
                return ghostty_surface_new(app, &config)
            }
        }
        guard let surface else { return }

        // record the same scheme on the surface itself, so a later `update_config` re-resolves its side.
        ghostty_surface_set_color_scheme(surface, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)

        if let screen = window?.screen ?? NSScreen.main,
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, displayID)
        }
        updateGhosttyFocus()

        // a session carrying a background watermark (set earlier on a never-shown session, or restored from
        // a snapshot) applies it now that the surface exists — covering deferred-size creation, the eager
        // deck, and relaunch. Scratch inherits through `watermarkSession`; overlay/quick surfaces remain
        // sessionless and skip it. ALSO re-applies a
        // standalone `dashboardFontOverride` (a dashboard member whose surface realizes AFTER the dashboard
        // set the transient font): `applyWatermarkFromSession` honors `dashboardFontOverride ?? session.fontSize`,
        // so without this the late-realized cell renders at the default font. Mirrors `reapplySessionConfigIfNeeded`.
        if (session ?? watermarkSession)?.backgroundWatermark != nil || dashboardFontOverride != nil {
            applyWatermarkFromSession()
        }
        // an overlay surface with its own background color (session.overlay.open --background-color) applies
        // it here too — the overlay is sessionless, so the watermark path above skips it.
        if overlayBackgroundColorHex != nil { applyOverlayBackgroundColor() }

        // the overlay grabs first responder itself (TerminalView's once-on-attach grab misses the
        // deferred overlay surface); a bounded run-loop retry beats the SwiftUI/AppKit responder race.
        requestAutoFocus(in: window)
    }

    /// Marks the surface focused in libghostty after a retried `makeFirstResponder` (the overlay/reparent
    /// grabs). By now `window.firstResponder === self`, so `updateGhosttyFocus` reports the true state.
    private func notifySurfaceFocused() {
        updateGhosttyFocus()
    }

    /// Starts the bounded auto-focus retry (overlay only), if not already done/in-flight.
    private func requestAutoFocus(in window: NSWindow?) {
        guard autoFocus, deckActive, !didAutoFocus, !autoFocusInFlight, let window else { return }
        autoFocusInFlight = true
        restoreAutoFocus(in: window, attempt: 0)
    }

    /// Retries `makeFirstResponder` on the run loop until this view is in `window` with a surface and
    /// actually holds first responder, then marks it focused. Bounded so it never spins forever; gives
    /// up if the view is torn down or moved windows. macterm's FocusRestoration pattern.
    private func restoreAutoFocus(in window: NSWindow, attempt: Int) {
        guard autoFocus, deckActive, !didAutoFocus, !isDestroyed else { autoFocusInFlight = false; return }
        if self.window === window, surface != nil {
            if window.firstResponder !== self { window.makeFirstResponder(self) }
            if window.firstResponder === self {
                didAutoFocus = true
                autoFocusInFlight = false
                notifySurfaceFocused()
                return
            }
        }
        guard attempt < Self.autoFocusMaxAttempts else { autoFocusInFlight = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoFocusRetryInterval) { [weak self, weak window] in
            guard let self, let window else { return }
            self.restoreAutoFocus(in: window, attempt: attempt + 1)
        }
    }

    private var reparentFocusInFlight = false

    /// Grabs first responder with a bounded run-loop retry, for a pane that just became the maximized
    /// survivor after its sibling pane closed. The collapse re-hosts this view (HSplitView → standalone)
    /// and a single `makeFirstResponder` loses the re-parent race, so retry until it's in a window with a
    /// surface and holds first responder. Distinct from the overlay's auto-focus: not gated on `autoFocus`
    /// and no `didAutoFocus` latch, so it can run again on a later collapse.
    func focusAfterReparent() {
        guard !isDestroyed, !reparentFocusInFlight else { return }
        reparentFocusInFlight = true
        retryReparentFocus(attempt: 0, heldFor: 0)
    }

    private func retryReparentFocus(attempt: Int, heldFor: Int) {
        guard !isDestroyed else { reparentFocusInFlight = false; return }
        var holds = false
        if let window, surface != nil {
            if window.firstResponder !== self { window.makeFirstResponder(self) }
            holds = window.firstResponder === self
            if holds { notifySurfaceFocused() }
        }
        // the collapse re-hosts this view a tick or two AFTER focus is first requested, and that resigns
        // the grab. So don't stop on the first success — keep re-grabbing until focus has STUCK for a few
        // consecutive ticks (past the re-host), or the attempt budget runs out.
        let nextHeld = holds ? heldFor + 1 : 0
        guard nextHeld < 3, attempt < Self.autoFocusMaxAttempts else { reparentFocusInFlight = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoFocusRetryInterval) { [weak self] in
            self?.retryReparentFocus(attempt: attempt + 1, heldFor: nextHeld)
        }
    }

    func destroySurface() {
        isDestroyed = true
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        focusObservers = []
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        configCStrings.forEach { free($0) }
        configCStrings = []
        // the env structs only point into the freed configCStrings buffers; clear them too.
        envVars = []
        // free the retained per-surface watermark configs — the surface (their only consumer) is gone.
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = []
        // read the wrapper-captured exit status, hand it off, then delete the temp file so its lifetime
        // tracks the surface. runs on every in-process teardown (natural exit, explicit close, force-close).
        if let f = overlayCodeFile {
            if let text = try? String(contentsOfFile: f, encoding: .utf8),
               let code = OverlayCapture.parseExitCode(text) {
                onExitCodeCaptured?(code)
            } else {
                NSLog("overlay exit-code file unreadable or empty: %@", f)
            }
            try? FileManager.default.removeItem(atPath: f)
            overlayCodeFile = nil
        }
        // nil the store-capturing callbacks last to break the store -> session -> surface -> closure -> store
        // retain cycle on every close path. MUST stay after the onExitCodeCaptured?(code) call above; niling
        // it earlier would silently drop the overlay exit status. no libghostty callback fires once freed.
        onExit = nil
        onExitCodeCaptured = nil
        onFocusChange = nil
        onClearUnseen = nil
        onUserInputClearsStatus = nil
        onUserInput = nil
        onFontSizeChange = nil
        onSearchStart = nil
        onSearchEnd = nil
        onSearchTotal = nil
        onSearchSelected = nil
    }

    /// `TerminalSurface` conformance: the model calls this when the owning
    /// session is closed.
    func teardown() {
        destroySurface()
    }

    // MARK: - Window / size

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if surface == nil {
            createSurface()
        } else {
            let scale = Double(window.backingScaleFactor)
            ghostty_surface_set_content_scale(surface, scale, scale)
            let size = convertToBacking(bounds).size
            if size.width > 0, size.height > 0 {
                ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
            }
            updateGhosttyFocus()
        }
        updateMetalLayerSize()
        // Focus is driven by TerminalView.updateNSView when this surface becomes the active session's
        // detail view, so it isn't grabbed here — except an auto-focus (overlay) surface, which drives
        // its own bounded retry since the representable's once-on-attach grab misses the deferred surface.
        requestAutoFocus(in: window)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if pendingSurfaceCreation { createSurface() }
        updateMetalLayerSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalLayerSize()
    }

    /// Record this surface's light/dark scheme from the authoritative `isDark` (the app-level side the
    /// caller resolved from `NSApp.effectiveAppearance`), so the NEXT `update_config` re-resolves a dual
    /// `theme = light:,dark:` to the matching side. libghostty derives the active side from the surface's
    /// RECORDED conditional state at `update_config` time — not from the config file alone — so a surface
    /// whose recorded state lagged (e.g. created before its window's appearance resolved) would re-derive
    /// the WRONG side. Re-asserting it before each reload keeps the terminal in sync; `set_color_scheme`
    /// early-returns when unchanged, so it is cheap. The APP-level scheme is set once by the caller
    /// (`GhosttyApp.reloadConfig`), so this only touches the surface.
    func syncColorScheme(isDark: Bool) {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    private func updateMetalLayerSize() {
        guard let surface, window != nil else { return }
        let scaledSize = convertToBacking(bounds).size
        guard scaledSize.width > 0, scaledSize.height > 0 else { return }
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        if let liveLayer = layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveLayer.contentsScale = CGFloat(scale)
            CATransaction.commit()
        }
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
        // force a repaint after any resize or re-attach. the split-toggle re-parent (HSplitView <-> a
        // standalone host) detaches and re-attaches the view, invalidating the Metal drawable; set_size to
        // an unchanged grid is a no-op and the 120Hz `ghostty_app_tick` only draws surfaces flagged dirty,
        // so without this the re-hosted pane keeps a blank drawable even though its terminal buffer is intact.
        ghostty_surface_refresh(surface)
    }

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { !viewOnly }

    /// In view-only mode (a dashboard grid cell) refuse hit-testing so a click passes THROUGH to the SwiftUI
    /// cell overlay (highlight/enter) instead of reaching `mouseDown` and grabbing first responder. AppKit
    /// routes clicks to this real NSView regardless of SwiftUI `.allowsHitTesting(false)`, so the block must
    /// live here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        viewOnly ? nil : super.hitTest(point)
    }

    /// Deliver the LEFT click that reactivates a background/inactive window straight to the surface (a
    /// "first mouse") instead of AppKit swallowing it just to raise the window. Without this, clicking a
    /// specific pane of a two-pane split from another window raises the window but never runs `mouseDown`,
    /// so the clicked pane doesn't become first responder and `splitFocused` stays on the previously-focused
    /// pane ("the mouse works but the pane isn't selected"). The left click then behaves like any normal
    /// in-window click — it selects the pane AND is reported to the program — matching Terminal.app/iTerm2/Ghostty.
    /// Gated to `.leftMouseDown` on purpose: a first-mouse right/middle click would otherwise reach
    /// `rightMouseDown`/`otherMouseDown`, which forward to libghostty, and with the default
    /// `right-click-action = paste` that would paste the clipboard into a window you only meant to raise —
    /// so right/middle first clicks just raise the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // with auto-hide-inactive-sidebars on, activating an inactive window expands its (currently hidden)
        // sidebar and resizes THIS surface; if the activating click also pressed the terminal button, that
        // mid-gesture resize would drag the still-held press into a phantom selection. Let the click only
        // raise the window in that mode — a follow-up click selects normally once the window is key.
        if GhosttyApp.shared.autoHideSidebarInactiveWindows { return false }
        return event?.type == .leftMouseDown
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            // becoming first responder: report focused, gated on the window being key (a background
            // window's surface stays hollow). Push directly — `window.firstResponder` is not yet self
            // inside this call, so `liveFocus` would read stale. onFocusChange (split-pane tracking) is
            // independent of key state.
            ghostty_surface_set_focus(surface, window?.isKeyWindow ?? false)
            if !suppressFocusChange { onFocusChange?(true) }
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, false)
            if !suppressFocusChange { onFocusChange?(false) }
        }
        return result
    }
}
