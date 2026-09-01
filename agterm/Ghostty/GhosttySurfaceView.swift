// adapted from thdxg/macterm (MIT)

import agtermCore
import AppKit
import GhosttyKit
import os
import QuartzCore

private let logger = Logger(subsystem: "com.umputun.agterm", category: "GhosttySurfaceView")

/// A Metal-backed NSView hosting one libghostty surface (one shell). Conforms to `TerminalSurface` so the
/// host-free `Session` can own it without importing GhosttyKit/AppKit.
///
/// `surface` and the `configCStrings` strdup buffers are `nonisolated(unsafe)`: mutated only on the main
/// actor (create/destroy), and the C callbacks reading them are serialized by libghostty's tick model.
final class GhosttySurfaceView: NSView, PaneRoleMutableSurface {
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    private let workingDirectory: String

    /// The command run as the surface's process instead of the login shell, nil for the login shell; read in
    /// `createSurface`. The overlay uses it to run one program (e.g. a TUI) whose exit closes the overlay.
    /// The three seed fields are `nonisolated(unsafe)` for `shouldCloseOnChildExitAction`, read from a C
    /// callback: `resolveLaunchSeed` writes them on the main actor before the surface exists.
    nonisolated(unsafe) private var command: String?

    /// Text fed to the pty as if typed at startup (libghostty `initial_input`), nil for none.
    /// Restore-running-command uses it: the captured foreground command line + `\n`, so a restored login
    /// shell re-runs it and returns to a prompt on exit — UNLIKE `command`, which replaces the shell.
    nonisolated(unsafe) private var initialInput: String?

    /// Whether a `command`'s exit leaves the surface open on libghostty's "press any key to close" prompt
    /// instead of closing immediately. Only meaningful with `command`.
    nonisolated(unsafe) private var waitAfterCommand: Bool

    /// Defers this pane's seed to spawn time; nil for a view built with explicit constructor values (the
    /// overlay, scratch, quick terminal and HUD, none of which restore anything). Set by the pane
    /// factories, resolved once in `createSurface`, dropped on resolution and on teardown.
    var launchSeed: LaunchSeedProvider?

    /// This pane's place in the launch spawn queue: the key the pacer grants and the pacer holding it, both
    /// nil for every view that spawns on request (fresh panes, overlays, scratch, quick, HUD, and a restored
    /// pane that replays nothing). The pacer is `weak` — the app owns it — and both are
    /// `nonisolated(unsafe)` so the nonisolated `deinit` net can read them; written on the main actor only.
    nonisolated(unsafe) private weak var spawnPacer: SpawnPacer?
    nonisolated(unsafe) private var spawnKey: UUID?

    /// Whether this pane is mounted and sized but still waiting for its spawn permit. `isRealized` already
    /// reports it unrealized; this separates waiting on the pacer from waiting on a nonzero size.
    private(set) var awaitingSpawnPermit = false

    /// Whether this surface grabs first responder as soon as it is created — the overlay's path: it mounts
    /// over an already-focused session, and `TerminalView.focusIfNeeded` grabs only when the view is in a
    /// window at the first `updateNSView`, which the deferred overlay surface is not, with no later update.
    private let autoFocus: Bool

    /// Initial font size in points, nil for the ghostty config default. Read in `createSurface`, which may
    /// run after construction, so it is fixed at init. Not `private`: the `+Config` extension reads it.
    let initialFontSize: Float?

    /// Extra environment variables (the `AGTERM_*` vars) the spawned shell sees; read in `createSurface`.
    let env: [String: String]

    /// The owning model session, `weak` to break the cycle with `Session.surface`. Set by the factory.
    weak var session: Session?

    /// Whether this primary/split pane launched through zmx. Fixed before `createSurface` reads its config.
    let backedByZmx: Bool

    /// The session whose visual config this surface inherits when it deliberately has no `session`: the scratch
    /// renders the owner's watermark without its OSC title/PWD reports mutating the session model. Nil for
    /// overlays and quick terminals; main/split use `session`.
    weak var watermarkSession: Session?

    /// Whether this is the session's split (right) pane. Routes `applyPwd`/`applyTitle` to the session's
    /// `splitCwd`/`splitTitle` so they can't clobber the primary's; cleared when promoted on collapse.
    var isSplitPane = false

    /// Whether the search lifecycle callbacks are wired (the main/split and scratch factories set it). Only
    /// those drive a visible bar and the END close path, so `AppActions.toggleSearch` refuses a
    /// quick-terminal/overlay surface, which would enter libghostty search mode with no bar and no close.
    var isSearchable = false

    /// Called on the main actor when the shell process exits, so the app can close the owning session.
    var onExit: (() -> Void)?

    /// For a capturing overlay surface: the temp file the command wrapper writes its exit status to
    /// (`echo $? > file`), nil otherwise — libghostty's child-exited status reflects the login-shell wrapper
    /// (always 0). `destroySurface` reads then deletes it on every teardown path — no registry or sweep.
    var overlayCodeFile: String?

    /// For a HUD surface: the body file the bundled helper re-reads every tick, nil otherwise. Deleted on
    /// every teardown path like `overlayCodeFile`, which both removes the temp file and is how the helper
    /// learns to stop. `session.hud.open` writes it AFTER the store call, so a replacement's teardown
    /// cannot delete the body the incoming HUD just wrote at the same per-session path.
    var hudBodyFile: String?

    /// For an OVERLAY surface: its own solid `#rrggbb` background (`session.overlay.open --background-color`),
    /// nil for the theme background. Applied in `createSurface`, which the session-watermark path skips
    /// because the overlay is sessionless.
    var overlayBackgroundColorHex: String?

    /// The dynamic background color a program set on THIS surface via OSC 11 (`#rrggbb`), or nil for none.
    /// Rendered per-pane by `applyOSCBackground` (which carries the detail).
    var oscBackgroundColorHex: String?

    /// For a capturing overlay surface: receives the exit status parsed from `overlayCodeFile`, recorded onto
    /// the session for `session.overlay.result`. Called from `destroySurface` on every in-process teardown,
    /// so capture never depends on `onExit` (e.g. an explicit `session.overlay.close`). On a session/window
    /// force-close it no-ops — the session is gone, the result unqueryable — the file deleted regardless.
    var onExitCodeCaptured: ((Int) -> Void)?

    /// Called on the main actor when this surface gains (`true`) or loses (`false`) first responder, so the
    /// app can track which split pane is active.
    var onFocusChange: ((Bool) -> Void)?
    /// Rehosting for terminal zoom must update libghostty focus without changing app model state such as
    /// the focused split pane. `TerminalView` flips this while the surface is hosted in the zoom layer.
    var suppressFocusChange = false
    /// Called on the main actor to clear the session's unseen badge + delivered banners WITHOUT the
    /// `splitFocused` write riding `onFocusChange(true)` — the refocus-clear path for a zoom-hosted surface,
    /// whose focus report is suppressed though the user is looking at it. Set by the main/split factories.
    var onClearUnseen: (() -> Void)?

    /// Called on the main actor on EVERY keystroke into this surface, carrying whether the key interrupts the
    /// agent (Escape or Ctrl-C). The factory decides per pane via `AgentIndicator.clearedBy(pane:isInterrupt:)`:
    /// clear the glyph to idle only when THIS surface's pane owns a clearable status — `blocked`/`completed`
    /// on any key, `active` only on an interrupt — so foreground typing cannot wipe a background pane's block.
    /// Passing the pane rather than reading `view.session` lets the scratch, which has none, self-clear.
    /// Status is otherwise control-driven; this is the one input-driven clear, for the decline case Claude
    /// Code fires no hook for.
    var onUserInputClearsStatus: ((Bool) -> Void)?

    /// Called on the main actor on EVERY keystroke to stamp user activity and reset the window's auto-follow
    /// idle timer. Fires unconditionally, unlike `onUserInputClearsStatus`: ordinary typing in an idle
    /// session must count as activity or the user is yanked to a blocked session mid-type.
    var onUserInput: (() -> Void)?

    /// Called on the main actor with the current font size (points) when it changes (cmd +/-), so the app
    /// can persist it. Pane surfaces share a live-role-aware callback; scratch and overlays leave it unset.
    /// libghostty has no font-size getter or change event, so this rides CELL_SIZE and reads the inherited config.
    var onFontSizeChange: ((Double) -> Void)?

    /// Called when libghostty enters search mode (START_SEARCH) with the current needle (nil when none). The
    /// main/split factory toggles the session's search bar: visible → send `end_search` (the ⌘F-again close),
    /// else open the bar and seed the needle.
    var onSearchStart: ((String?) -> Void)?

    /// Called on the main actor when libghostty exits search mode (END_SEARCH). The main/split factory
    /// clears the session's search fields, hides the bar, and returns first responder to the terminal.
    var onSearchEnd: (() -> Void)?

    /// Called on the main actor with the total match count (SEARCH_TOTAL), nil when libghostty reports a
    /// negative count (no query). Wired to the session's `searchTotal`.
    var onSearchTotal: ((Int?) -> Void)?

    /// Called on the main actor with the 1-based index of the selected match (SEARCH_SELECTED), nil when
    /// libghostty reports a negative index. Wired to `searchSelected`.
    var onSearchSelected: ((Int?) -> Void)?

    /// Heap buffers backing the surface config's `const char*` fields — notably `initial_input`, which
    /// libghostty writes to the pty asynchronously after the child spawns, so the buffer must outlive
    /// `ghostty_surface_new`. Freed in `destroySurface`.
    nonisolated(unsafe) private var configCStrings: [UnsafeMutablePointer<CChar>] = []

    /// The `ghostty_env_var_s` structs handed to `config.env_vars`; their `key`/`value` point into the
    /// `configCStrings` buffers (same lifetime). The array must itself outlive `ghostty_surface_new`, so it is
    /// stored rather than local, cleared in `destroySurface`/`deinit`. `nonisolated(unsafe)`: main actor only.
    nonisolated(unsafe) private var envVars: [ghostty_env_var_s] = []

    /// Per-surface ghostty configs for this surface's background watermark (`configWithOverlay`), retained so
    /// they outlive their `ghostty_surface_update_config`. Capped at ONE: each re-apply frees the prior, since
    /// after `update_config` the surface no longer references it, so a scripted `config.reload` loop can't
    /// grow the array. The last is freed in `destroySurface`/`deinit`, safe because the surface — their only
    /// consumer — is gone (unlike the app-wide config `GhosttyApp` never frees). `nonisolated(unsafe)`: main
    /// actor only; internal for `+Config`.
    nonisolated(unsafe) var ownedConfigs: [ghostty_config_t] = []

    /// Key-window observers (didBecomeKey/didResignKey). A surface in a background window must report an
    /// unfocused (hollow) cursor, but AppKit first responder is per-window and does NOT resign when a window
    /// merely loses key, so key changes re-push `liveFocus`. Removed on teardown; `nonisolated(unsafe)`
    /// because the nonisolated `deinit` safety net reads them.
    nonisolated(unsafe) private var focusObservers: [NSObjectProtocol] = []
    private var pendingSurfaceCreation = false
    var rendererVisibilityTask: Task<Void, Never>?
    var rendererVisible = true
    /// Sweeps the hidden layer's retained frame on a slow cadence; exits itself on reveal or teardown.
    var hiddenJanitorTask: Task<Void, Never>?
    /// Sanitized OSC 7 value expected back as libghostty's synthetic title while this pane has no real title.
    private var pendingPwdFallbackTitle: String?
    /// After `destroySurface()` the view is retired: never recreate a surface (a stray viewDidMoveToWindow).
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

    /// Whether this surface's deck slot is the active (selected) session. The overlay/scratch auto-focus grabs
    /// first responder on attach, so without this gate one opened in a BACKGROUND session would steal the
    /// keyboard from the visible one; `TerminalView` sets it before `createSurface`, and going inactive
    /// mid-retry bails the loop. Inert for main/split panes, which take focus via `focusIfNeeded`.
    var deckActive = true

    /// Whether this surface's deck slot is on-screen (session selected, not hidden by a full overlay/scratch).
    /// Unlike `deckActive` it is not split-pane-focus-gated, so both panes of a visible split are
    /// `deckVisible`; it still drops while the quick terminal owns focus to suppress AppKit mouse routing.
    /// Load-bearing for drag-and-drop: every surface is eagerly realized, and SwiftUI's `.opacity(0)`/
    /// `.allowsHitTesting(false)` never reach AppKit's drag machinery (the NSView keeps `alphaValue == 1`, and
    /// drag-destination resolution does NOT consult `hitTest`), so with every surface registered a file drop
    /// would land on whichever is topmost in z-order — an INVISIBLE background session — not the one under
    /// the cursor. `didSet` (un)registers the drag types and the mouse-tracking area for the same reason.
    var deckVisible = true {
        didSet {
            // the user is looking at this pane, so it goes to the front of a paced launch; a no-op when
            // unpaced, granted or already expedited, so the per-update rewrites mint nothing. ahead of the
            // equality guard because the first mount writes true over the default true. `deckActive` is
            // split-focus-gated and would leave the other half of a shown split queued.
            if deckVisible { expediteSpawn() }
            // `TerminalView` assigns this on every SwiftUI update pass, so skip the tracking-area teardown/
            // rebuild + drag re-registration unless the visibility actually flipped.
            guard deckVisible != oldValue else { return }
            updateDropRegistration()
            updatePointerTracking()
            postAccessibilityExposureChange() // one of the `axExposed` terms; tell AX if the element came or went
        }
    }

    /// Whether this surface actually paints on screen. Wider than `deckVisible`: dashboard cells and
    /// passive HUDs are visible while deliberately non-interactive, and a pane stays on screen while the
    /// quick terminal merely holds key.
    var deckOnScreen = true {
        didSet {
            guard deckOnScreen != oldValue else { return }
            updateRendererVisibility()
        }
    }

    /// View-only mode: rendered but taking NO mouse or keyboard input (the dashboard grid cell). SwiftUI's
    /// `.allowsHitTesting(false)` does NOT stop AppKit routing a click to this real NSView (hit resolution
    /// bypasses SwiftUI, the same reason `deckVisible` gates drag registration), so a click would reach
    /// `mouseDown`, grab first responder, and steal the keyboard from the dashboard's key-catcher. When set,
    /// `hitTest` returns nil and the surface refuses first responder; set on the cell, cleared on the slot.
    var viewOnly = false {
        didSet {
            guard viewOnly != oldValue else { return }
            // `axExposed`'s first term. Every term drives the exposure post rather than one implying others.
            postAccessibilityExposureChange()
            guard viewOnly else { return }
            // acceptsFirstResponder=false blocks only NEW grabs: a surface carrying first responder in from
            // the deck (the focused split pane at dashboard open) keeps it across the reparent and defeats
            // the key-catcher. resign here; once view-only nothing can re-grab.
            if let window, window.firstResponder === self { window.makeFirstResponder(nil) }
        }
    }

    /// Register the file/text drag types only while this surface is the on-screen deck pane, so an eagerly
    /// realized background surface is never a drop target. Also called once from `createSurface` — `didSet`
    /// does not fire for the initializer default.
    private func updateDropRegistration() {
        if deckVisible {
            registerForDraggedTypes([.fileURL, .string, .URL])
        } else {
            unregisterDraggedTypes()
        }
    }

    /// Transient dashboard font size in points overriding `session.fontSize` while this surface is hosted in a
    /// dashboard grid cell; nil = not overriding. The composer prefers it, `reapplySessionConfigIfNeeded`
    /// re-emits it across a config reload, and `reportFontSize` won't persist it, so a CELL_SIZE round-trip
    /// can't write the transient size into `session.fontSize`.
    var dashboardFontOverride: Double? {
        didSet {
            // keep a live OSC 11 tint across dashboard open/close; else rebuild from the session model.
            if let hex = oscBackgroundColorHex { applyOSCBackground(hex) } else { applyWatermarkFromSession() }
            // a SET override can't strand a revert report — reportFontSize's `dashboardFontOverride == nil`
            // guard drops the CELL_SIZE report while the override is active — so drop any pending restore.
            guard dashboardFontOverride == nil, let cleared = oldValue else { pendingFontRestore = nil; return }
            // CLEARING reverts to session.fontSize (the app default when nil), firing a CELL_SIZE report ~0.4s
            // LATER — long after any same-runloop latch would clear — and persisting that would PIN a
            // nil-fontSize session to the default instead of following a later Settings change. remember the
            // reverted-to size so reportFontSize consumes that report without persisting; arm only on a real
            // change, since an override equal to the target emits no report and would leak onto a later zoom.
            let target = session?.fontSize ?? GhosttyApp.shared.baseFontSize
            pendingFontRestore = abs(cleared - target) > 0.5 ? target : nil
        }
    }

    /// The font size (points) the surface reverts to when `dashboardFontOverride` is CLEARED — what that
    /// revert's async CELL_SIZE report carries; `reportFontSize` drops that report WITHOUT persisting, so
    /// restoring the grid font never pins a default-following session. State, not a one-runloop latch, so it
    /// survives the ~0.4s report gap.
    private var pendingFontRestore: Double?

    // IME composition state shared with GhosttySurfaceView+Input.swift (stored properties can't live in an extension).
    var _markedRange = NSRange(location: NSNotFound, length: 0)
    var _selectedRange = NSRange(location: NSNotFound, length: 0)
    /// The in-flight composition's text. libghostty owns the preedit for RENDERING (`ghostty_surface_preedit`)
    /// and hands nothing back, so the only way to COMMIT a live composition instead of throwing it away is to
    /// keep our own copy — which every programmatic insert does (`commitOrDiscardComposition`). Maintained by the
    /// three `NSTextInputClient` methods that own `_markedRange`, and always cleared with it.
    var _markedText = ""

    /// The `isAccessibilityFocused` value last announced to AX, so `postAccessibilityFocusChange` posts on
    /// TRANSITIONS only. Every surface re-runs `updateGhosttyFocus` on any window's key change (the
    /// `didBecomeKey`/`didResignKey` observers use `object: nil`), so an ungated post would fire once per
    /// realized surface per key change — N notifications for one focus move.
    var axPostedFocus = false

    /// Whether a deferred focus post is already queued for this surface, so the resign+become PAIR that a
    /// single focus move produces coalesces into one evaluation instead of two. See
    /// `postAccessibilityFocusChange`, which schedules the hop.
    var axFocusPostScheduled = false

    /// The `axExposed` value last announced to AX, the exposure counterpart of `axPostedFocus`. Every term
    /// of `axExposed` now has a call site (`deckVisible`/`viewOnly` didSet, surface create/destroy, window
    /// move, and the miniaturize/hide observers), several of which can fire for a single transition, so the
    /// latch is what keeps one flip to one `.layoutChanged`.
    var axPostedExposed = false

    /// True only for the duration of the `discardMarkedText()` call inside `commitOrDiscardComposition`,
    /// where `insertText` refuses re-entrant input. That helper commits our copy of the composition itself
    /// and then tears the IME session down; an input method that FINALIZES rather than abandons on that
    /// teardown would send the same characters back through `insertText` and land them twice. Nothing else
    /// legitimately types during that synchronous window, so dropping the re-entrant insert is safe.
    var committingComposition = false
    var keyTextAccumulator: [String] = []
    var currentKeyEvent: NSEvent?

    // the pointer's mouse-tracking area, managed by GhosttySurfaceView+Tracking.swift (a stored property
    // can't live in an extension, so it stays here as internal rather than private).
    var currentTrackingArea: NSTrackingArea?

    /// The mouse-cursor shape libghostty last requested (`GHOSTTY_ACTION_MOUSE_SHAPE`): I-beam over the grid,
    /// pointing hand over a detected link / OSC-8 hyperlink, resize/crosshair in the matching modes.
    /// `cursorUpdate` maps it to an `NSCursor`; the I-beam default makes the resting cursor right from the start.
    var mouseShape: ghostty_action_mouse_shape_e = GHOSTTY_MOUSE_SHAPE_TEXT

    /// Whether the pointer is inside this surface (from `mouseEntered`/`mouseExited`), gating the immediate
    /// `.set()` in `applyMouseShape` so a revert delivered after the pointer left can't leak onto the sidebar.
    var pointerInside = false

    /// The last pointer position pushed via `ghostty_surface_mouse_pos` (view-flipped), nil before the first
    /// report. `scrollWheel` syncs only when the current point differs: re-pushing the same cell per packet
    /// makes an any-motion + sgr-pixel mouse-reporting TUI emit a synthetic motion report per packet.
    var lastReportedMousePoint: NSPoint?

    init(workingDirectory: String, fontSize: Float? = nil, command: String? = nil, initialInput: String? = nil,
         waitAfterCommand: Bool = false, autoFocus: Bool = false, env: [String: String] = [:],
         backedByZmx: Bool = false) {
        self.workingDirectory = workingDirectory
        self.initialFontSize = fontSize
        self.command = command
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
        self.autoFocus = autoFocus
        self.env = env
        self.backedByZmx = backedByZmx
        super.init(frame: .zero)
        wantsLayer = true
        setupTrackingArea()
        observeKeyWindowChanges()
        observeWindowVisibilityChanges()
        observeDisplayWake()
    }

    /// Re-attempt creation when the displays wake. `ghostty_surface_new` returns NULL for as long as the
    /// display is asleep, and the deck's own retries all ride SwiftUI layout, which does not run for an
    /// off-display window — so a session a scheduled job created in that window stays dead with its
    /// `--command` unrun until something incidental re-lays it out (#416). `object: nil` and a token in
    /// `focusObservers` match the sibling observers, including their `NotificationCenter.default` teardown.
    private func observeDisplayWake() {
        let token = NotificationCenter.default.addObserver(
            forName: .agtermScreensDidWake, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryCreationAfterWake() }
        }
        focusObservers.append(token)
    }

    /// Bounded re-attempts after a display wake: creation was measured still failing for a second or two
    /// past `screensDidWake`, so one shot at the notification is not enough, and an unbounded retry would
    /// spin forever against a surface that fails for some other reason. A realized surface costs nothing —
    /// the first guard returns immediately.
    private func retryCreationAfterWake(attempt: Int = 1) {
        guard !isDestroyed, surface == nil else { return }
        createSurface()
        guard surface == nil, attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.retryCreationAfterWake(attempt: attempt + 1)
        }
    }

    /// Watch every window's key transitions and re-evaluate focus on each. No filtering to my own window:
    /// `updateGhosttyFocus` reads `self.window.isKeyWindow`, so each surface reports its OWN state (a
    /// background window's goes hollow, the new key window's active one solid) and this survives a re-host.
    private func observeKeyWindowChanges() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            let becameKey = name == NSWindow.didBecomeKeyNotification
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateGhosttyFocus()
                    // returning focus to agterm while this pane is on screen counts as seeing the session, so
                    // clear its unseen badge. becomeFirstResponder can't: AppKit's per-window first responder
                    // never resigned while agterm was backgrounded, so no focus transition fires on return.
                    if becameKey {
                        self.reassertCursorOnActivation()
                        self.clearUnseenOnRefocus()
                    }
                }
            }
            focusObservers.append(token)
        }
    }

    /// Watch the transitions that move `window?.isVisible`, the `axExposed` term nothing else reports.
    /// `deckVisible` is pure MODEL state, so miniaturizing the window — or hiding the app — leaves this pane
    /// `deckVisible == true` while AppKit reports `isVisible == false`. Without these, `axExposed` went
    /// true → false → true across a minimize/restore with no `.layoutChanged` posted at all.
    /// `object: nil` like the key observers: the post recomputes from THIS view's own window, so another
    /// window's notification costs one latch compare. Tokens join `focusObservers`, so teardown is unchanged.
    private func observeWindowVisibilityChanges() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.postAccessibilityExposureChange() }
            }
            focusObservers.append(token)
        }
    }

    /// Clear the seen state (unseen badge + delivered banners) for this pane's session when agterm regains key
    /// focus on it. `liveFocus` (first responder of a key window, and a window is key only while the app is
    /// active) confines it to the focused pane of the now-key window, never a background one. Reusing
    /// `onFocusChange` clears exactly for the main/split panes that already clear on a focus transition (a
    /// scratch/overlay has neither), and no-ops after teardown once the closure is nil'd. Under
    /// `suppressFocusChange` a zoom-hosted surface IS the key window's first responder, so `onFocusChange`
    /// would mutate `splitFocused` on every key regain — take the focus-free `onClearUnseen`, since the badge
    /// must still clear.
    private func clearUnseenOnRefocus() {
        guard liveFocus else { return }
        if suppressFocusChange {
            onClearUnseen?()
        } else {
            onFocusChange?(true)
        }
    }

    /// The cursor-focus state to report to libghostty: solid only when this surface is its window's first
    /// responder AND that window is key — the key gate stops every window's active surface blinking at once.
    /// Reading the live responder rather than a cached flag keeps a re-hosted pane's focus true, so opening
    /// a split can't leave both panes solid.
    /// Not `private`: `+Accessibility.swift` reuses it for `isAccessibilityFocused` / the AX write guard,
    /// the same way `currentTrackingArea` is internal so `+Tracking.swift` can reach it.
    var liveFocus: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    /// Push `liveFocus` to libghostty (no-op before the surface exists; `createSurface` calls it once the
    /// surface is up). Used on window-key changes, surface (re)attach, and the auto-focus/reparent grabs;
    /// first-responder transitions push directly, since `window.firstResponder` is not yet self inside
    /// `becomeFirstResponder`/`resignFirstResponder`.
    func updateGhosttyFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, liveFocus)
        // `isAccessibilityFocused` mirrors `liveFocus`; AX must hear it move. This covers the key-window and
        // (re)attach paths only — the first-responder transitions post for themselves, since they run before
        // AppKit has updated `window.firstResponder` and never reach this method.
        postAccessibilityFocusChange()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        // free directly, not via destroySurface(): deinit is nonisolated and can't call the @MainActor method,
        // while the nonisolated(unsafe) fields free with plain C calls. the net for a view dropped untorn.
        // the queue exit is the exception: `cancel` is main-actor, so schedule it by KEY, capturing the pacer
        // and the key but never `self`, which is already being freed.
        if let pacer = spawnPacer, let key = spawnKey {
            Task { @MainActor in pacer.cancel(key) }
        }
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let surface { ghostty_surface_free(surface) }
        configCStrings.forEach { free($0) }
        envVars = []
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = []
        if let f = overlayCodeFile { try? FileManager.default.removeItem(atPath: f) }
        if let f = hudBodyFile { try? FileManager.default.removeItem(atPath: f) }
    }

    // MARK: - Callback entry points

    func applyPwd(_ rawPwd: String) {
        // already on the main actor (the callback hops via DispatchQueue.main.async); `currentCwd` is observed,
        // so the sidebar row refreshes live. the OSC 7 value flows unquoted into a /bin/sh -c line via
        // {AGT_SESSION_PWD} and into every cwd-inheriting spawn, so a newline (an sh -c separator) must never
        // survive; a real path has none.
        let pwd = TerminalText.sanitized(rawPwd)

        // no save(): OSC 7 fires on every cd/prompt redraw and would thrash the disk. live cwd is persisted on
        // quit and on structural mutations, so a crash loses only cwd changes since the last save. the
        // equality guard matters likewise: an equal write still notifies observers and churns the reconcile.
        if let session {
            let modelTitle = isSplitPane ? session.splitTitle : session.oscTitle
            let titleIsBlank = modelTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            pendingPwdFallbackTitle = titleIsBlank ? pwd : nil
        } else {
            pendingPwdFallbackTitle = nil
        }
        if isSplitPane {
            if session?.splitCwd != pwd { session?.splitCwd = pwd }
        } else {
            if session?.currentCwd != pwd { session?.currentCwd = pwd }
        }
    }

    func applyTitle(_ rawTitle: String) {
        // already on the main actor; `oscTitle`/`splitTitle` are observed, so the sidebar row and window
        // title refresh live. like applyPwd this does NOT save() — OSC set-title re-fires on every prompt
        // redraw — and sanitizes: the title flows unquoted into a /bin/sh -c line via {AGT_SESSION_NAME}.
        logger.debug("terminal title pane=\(self.paneToken, privacy: .public) split=\(self.isSplitPane) cwd=\(self.workingDirectory, privacy: .public) title=\(rawTitle, privacy: .public)")
        let title = TerminalText.sanitized(rawTitle)
        if pendingPwdFallbackTitle == title {
            pendingPwdFallbackTitle = nil
            return
        }
        pendingPwdFallbackTitle = nil

        if isSplitPane {
            if session?.splitTitle != title { session?.splitTitle = title }
        } else {
            if session?.oscTitle != title { session?.oscTitle = title }
        }
    }

    /// Marks this surface's exit as handled WITHOUT running `onExit`, so a queued callback for a process
    /// the caller has already destroyed becomes a no-op. Returns false when the exit had already been
    /// handled, which is the caller's signal that the pane's own teardown has run and it must not drive a
    /// second one. Reuses `didHandleProcessExit` rather than adding a parallel flag that could drift.
    @discardableResult
    func claimProcessExit() -> Bool {
        guard !didHandleProcessExit else { return false }
        didHandleProcessExit = true
        return true
    }

    func handleProcessExit() {
        // already on the main actor (the close callbacks hop via DispatchQueue.main.async). idempotent: the
        // SHOW_CHILD_EXITED action and close_surface_cb can both fire for one exit.
        guard !didHandleProcessExit else { return }
        didHandleProcessExit = true
        if backedByZmx {
            logger.error("zmx attach process exited for pane \(self.paneToken, privacy: .public)")
        }
        onExit?()
    }

    /// Whether a child-exit should close this surface immediately, suppressing ghostty's "press any key"
    /// prompt. True only for a command surface (the overlay) that did NOT opt into the wait prompt, which
    /// instead closes via `close_surface_cb` after the keypress. `nonisolated` so the C action callback reads
    /// it with no main-actor hop.
    nonisolated var shouldCloseOnChildExitAction: Bool { command != nil && !waitAfterCommand }

    func reportFontSize() {
        // already on the main actor (the CELL_SIZE callback hops). don't persist under a dashboard override —
        // it would write the transient size into session.fontSize.
        guard dashboardFontOverride == nil else { return }
        // nil means libghostty hasn't resolved a font size yet.
        guard let size = currentFontSize() else { return }
        // clearing the override fires its own CELL_SIZE report ~0.4s later (see dashboardFontOverride.didSet):
        // drop the one matching the reverted-to value, then clear the flag so a later genuine zoom persists.
        if let pending = pendingFontRestore {
            pendingFontRestore = nil
            if abs(size - pending) <= 0.5 { return }
        }
        onFontSizeChange?(size) // the store no-ops a same-value write.
    }

    // MARK: - Surface lifecycle

    func createSurface() {
        guard !isDestroyed else { return }
        // register as a file drop target (issue #51) only while on-screen, so a background deck surface can't
        // intercept it. idempotent: createSurface re-runs when a deferred surface finally gets a size.
        updateDropRegistration()
        guard surface == nil, let app = GhosttyApp.shared.app else { return }
        let backingSize = convertToBacking(bounds).size
        guard backingSize.width > 0, backingSize.height > 0 else {
            pendingSurfaceCreation = true
            return
        }
        pendingSurfaceCreation = false
        // after the size guard so a zero-size pane holds no pacer token; the pacer re-enters createSurface
        // on grant. before the seed resolves so a denied pane keeps its captured argv and restore pin armed.
        guard requestSpawnPermit() else { return }
        resolveLaunchSeed()

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)

        // the strdup'd working_directory buffer must outlive the call: retained on the instance, freed in
        // destroySurface (the same contract initial_input needs below).
        configCStrings.forEach { free($0) }
        configCStrings = []
        if let p = strdup(workingDirectory) {
            configCStrings.append(p)
            config.working_directory = UnsafePointer(p)
        }
        // a command replaces the login shell (the overlay's one program); its strdup'd buffer joins the
        // `configCStrings` lifetime. wait_after_command keeps the "press any key" prompt at exit, opt-in, so
        // by default the overlay vanishes immediately.
        if let command, let p = strdup(command) {
            configCStrings.append(p)
            config.command = UnsafePointer(p)
            config.wait_after_command = waitAfterCommand
        } else {
            config.command = nil // login shell
        }
        // restore-running-command: feed the captured command line to the login shell as if typed, so it re-runs
        // and exits back to a prompt. Ordinary command surfaces keep the fields mutually exclusive because a
        // command REPLACES the shell. A zmx-backed surface is the exception: its command is the attach client, and
        // libghostty's initial input is what that client forwards into the daemon-side shell.
        if command == nil || backedByZmx, let initialInput, let p = strdup(initialInput) {
            configCStrings.append(p)
            config.initial_input = UnsafePointer(p)
        }
        // a persisted/restored size overrides config_new's default (the ghostty config font-size).
        if let initialFontSize { config.font_size = initialFontSize }

        // extra environment for the spawned shell. each key/value is strdup'd into the `configCStrings`
        // lifetime; the structs pointing at them are retained in `envVars` — value types, so not strdup'able.
        envVars = []
        for (key, value) in env {
            guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
            configCStrings.append(keyPtr)
            configCStrings.append(valuePtr)
            envVars.append(ghostty_env_var_s(key: UnsafePointer(keyPtr), value: UnsafePointer(valuePtr)))
        }
        // set the app color scheme BEFORE creating the surface: `ghostty_surface_new` derives the initial theme
        // from the app's conditional state, so a dual `theme = light:,dark:` renders the right side from the
        // FIRST frame instead of defaulting to light until a later reload. read the APP-level `currentIsDark()`
        // (`NSApp.effectiveAppearance`, the single source the KVO observer feeds), not this view's own.
        let isDark = GhosttyApp.currentIsDark()
        ghostty_app_set_color_scheme(app, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)

        // the env pointer is taken inside `withUnsafeMutableBufferPointer` and `ghostty_surface_new` runs in
        // the same closure, so it never escapes the call (no UB); ghostty copies the env at creation.
        if envVars.isEmpty {
            surface = ghostty_surface_new(app, &config)
        } else {
            surface = envVars.withUnsafeMutableBufferPointer { buf in
                config.env_vars = buf.baseAddress
                config.env_var_count = buf.count
                return ghostty_surface_new(app, &config)
            }
        }
        guard let surface else {
            // libghostty declines to build a surface while the display is asleep. Silence here is what made
            // #416 undiagnosable from outside: `session.new` had already answered ok. Re-arm the deferred-create
            // flag so the layout path retries too — `.agtermScreensDidWake` is what makes recovery TIMELY, not
            // what makes it possible, and a view first mounted inside the residual post-wake window registers
            // its observer too late for the wake that just fired.
            pendingSurfaceCreation = true
            logger.notice("surface creation failed (display asleep?); retrying on the next wake or layout pass")
            return
        }
        // record the same scheme on the surface itself, so a later `update_config` re-resolves its side.
        ghostty_surface_set_color_scheme(surface, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)

        if let screen = window?.screen ?? NSScreen.main,
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, displayID)
        }
        updateGhosttyFocus()
        updateRendererVisibility(delayHide: false)
        // the `surface != nil` term of `axExposed` just flipped: a pane whose creation was DEFERRED
        // (`pendingSurfaceCreation`, a window still being presented) was absent from the a11y tree until
        // now, so the first window after launch never announced its Terminal element.
        postAccessibilityExposureChange()

        // a session carrying a background watermark (never shown, or restored from a snapshot) applies it now
        // the surface exists — deferred-size creation, the eager deck, relaunch; the scratch inherits via
        // `watermarkSession`, sessionless overlay/quick skip it. ALSO re-applies a standalone
        // `dashboardFontOverride` for a member realizing AFTER the dashboard set the transient font, since
        // `applyWatermarkFromSession` honors `dashboardFontOverride ?? session.fontSize`.
        if (session ?? watermarkSession)?.backgroundWatermark != nil || dashboardFontOverride != nil {
            applyWatermarkFromSession()
        }
        // an overlay surface with its own background color applies it here too — the overlay is sessionless,
        // so the watermark path above skips it.
        if overlayBackgroundColorHex != nil { applyOverlayBackgroundColor() }

        // the overlay grabs first responder itself (TerminalView's once-on-attach grab misses the deferred
        // overlay surface); a bounded run-loop retry beats the SwiftUI/AppKit responder race.
        requestAutoFocus(in: window)
    }

    /// Puts this pane in the launch spawn queue: `createSurface` asks `pacer` for `key` once the view is
    /// sized, and spawns when the grant comes back through the registry. Called by the pane factories for a
    /// restored pane that replays a program; every other view spawns on request.
    func useSpawnPacer(_ pacer: SpawnPacer, key: UUID) {
        spawnPacer = pacer
        spawnKey = key
    }

    /// Moves this pane to the front of a paced launch and grants it now. A no-op for an unpaced pane and
    /// for a key already granted or expedited, so a caller may repeat it freely.
    func expediteSpawn() {
        guard let spawnPacer, let spawnKey else { return }
        spawnPacer.expedite(spawnKey)
    }

    /// Moves the queued panes among `views` to the front, in that order, releasing none: a dashboard
    /// opening on many queued members fills its cells at the paced rate rather than in one burst.
    static func prioritizeSpawn(_ views: [GhosttySurfaceView]) {
        guard let pacer = views.lazy.compactMap(\.spawnPacer).first else { return }
        pacer.prioritize(views.compactMap { $0.spawnPacer === pacer ? $0.spawnKey : nil })
    }

    /// Whether the surface may spawn now. False leaves the pane queued and the caller returns: the pacer
    /// re-enters `createSurface` on the grant, against the bounds the view has then, so this deferral is the
    /// pacer's own rather than a next-tick hop racing layout. True for an unarmed or drained pacer, for a
    /// key already granted, and for every view outside the queue, which is today's behavior unchanged.
    func requestSpawnPermit() -> Bool {
        guard let spawnPacer, let spawnKey else { return true }
        awaitingSpawnPermit = !spawnPacer.request(spawnKey)
        return !awaitingSpawnPermit
    }

    /// Consumes the deferred launch seed on the first call, latching it into `command`/`initialInput`/
    /// `waitAfterCommand` and dropping the closure, so a creation retried after an unrelated failure never
    /// takes the session's pending slots twice. Returns the seed in force, which for a view built without a
    /// provider is its constructor values.
    @discardableResult
    func resolveLaunchSeed() -> LaunchSeed {
        guard let provider = launchSeed else {
            return LaunchSeed(command: command, initialInput: initialInput, waitAfterCommand: waitAfterCommand)
        }
        launchSeed = nil
        let seed = provider.resolve(isSplitPane ? .right : .left)
        command = seed.command
        initialInput = seed.initialInput
        waitAfterCommand = seed.waitAfterCommand
        return seed
    }

    /// Marks the surface focused in libghostty after a retried `makeFirstResponder` (the overlay/reparent
    /// grabs). By now `window.firstResponder === self`, so `updateGhosttyFocus` reports the true state.
    private func notifySurfaceFocused() {
        updateGhosttyFocus()
    }

    /// Starts the bounded auto-focus retry (overlay only), if not already done/in-flight.
    private func requestAutoFocus(in window: NSWindow?) {
        guard autoFocus, deckActive, !didAutoFocus, !autoFocusInFlight, let window,
              !Self.pickOwnsFocus(in: window) else { return }
        autoFocusInFlight = true
        restoreAutoFocus(in: window, attempt: 0)
    }

    /// Retries `makeFirstResponder` on the run loop until this view is in `window`, has a surface and holds
    /// first responder, then marks it focused. Bounded; gives up if the view is torn down or moved windows
    /// (macterm's FocusRestoration pattern).
    private func restoreAutoFocus(in window: NSWindow, attempt: Int) {
        guard autoFocus, deckActive, !didAutoFocus, !isDestroyed, !Self.pickOwnsFocus(in: window) else {
            autoFocusInFlight = false
            return
        }
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

    /// Grabs first responder with a bounded run-loop retry for the pane left as the maximized survivor of a
    /// sibling close: the collapse re-hosts this view (HSplitView → standalone) and one `makeFirstResponder`
    /// loses that race. Unlike the overlay's auto-focus there is no `autoFocus` gate and no `didAutoFocus`
    /// latch, so it runs again on a later collapse.
    func focusAfterReparent() {
        guard !isDestroyed, !reparentFocusInFlight else { return }
        reparentFocusInFlight = true
        retryReparentFocus(attempt: 0, heldFor: 0)
    }

    private func retryReparentFocus(attempt: Int, heldFor: Int) {
        guard !isDestroyed, !Self.pickOwnsFocus(in: window) else {
            reparentFocusInFlight = false
            return
        }
        var holds = false
        if let window, surface != nil {
            if window.firstResponder !== self { window.makeFirstResponder(self) }
            holds = window.firstResponder === self
            if holds { notifySurfaceFocused() }
        }
        // the collapse re-hosts this view a tick or two AFTER focus is first requested, which resigns the grab
        // — re-grab until focus STICKS for a few consecutive ticks (past the re-host) or the budget runs out.
        let nextHeld = holds ? heldFor + 1 : 0
        guard nextHeld < 3, attempt < Self.autoFocusMaxAttempts else { reparentFocusInFlight = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoFocusRetryInterval) { [weak self] in
            self?.retryReparentFocus(attempt: attempt + 1, heldFor: nextHeld)
        }
    }

    /// A picker is modal to terminal keyboard focus in its own window. The check lives inside both retry loops,
    /// not just their callers: a picker can open after a retry starts, and the next tick must stop before it
    /// steals first responder from the picker field.
    static func pickOwnsFocus(in window: NSWindow?) -> Bool {
        guard let window, let windowID = WindowRegistry.shared.windowID(for: window) else { return false }
        return PickRegistry.shared.controller(for: windowID)?.pending != nil
    }

    func destroySurface() {
        // a pane torn down before it spawned must not consume its pending slots; the session keeps them.
        launchSeed = nil
        // leave the launch queue: a key nobody will ever request holds every pane behind it for an interval,
        // and the grant that arrives anyway finds a destroyed view and no-ops.
        if let spawnKey, let spawnPacer { spawnPacer.cancel(spawnKey) }
        spawnKey = nil
        awaitingSpawnPermit = false
        cancelPendingRendererVisibility()
        hiddenJanitorTask?.cancel()
        hiddenJanitorTask = nil
        isDestroyed = true
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        focusObservers = []
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        // release the custom layer libghostty installed and this view still retains. The current pin clears
        // its display callback in `IOSurfaceLayer.release`, so this defends builds predating that fix, where
        // the callback kept pointing at the freed renderer and the next CoreAnimation display locked a mutex
        // in freed memory (#443). Must follow the free, which joins the render thread: dropping the layer
        // while it still paints trades one use-after-free for another.
        dropGhosttyLayer()
        // the other end of the `surface != nil` term: this element just left the a11y tree, and a client
        // holding it needs to re-resolve rather than keep writing into a closed session's pane.
        postAccessibilityExposureChange()
        postAccessibilityFocusChange()
        configCStrings.forEach { free($0) }
        configCStrings = []
        // the env structs only point into the freed configCStrings buffers; clear them too.
        envVars = []
        // free the retained per-surface watermark configs — the surface (their only consumer) is gone.
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = []
        // read the wrapper-captured exit status, hand it off, then delete the temp file. runs on every
        // in-process teardown: natural exit, explicit close, force-close.
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
        // the HUD's body file has no status to read: deleting it IS the teardown, on every path.
        if let f = hudBodyFile {
            try? FileManager.default.removeItem(atPath: f)
            hudBodyFile = nil
        }
        // nil the store-capturing callbacks last to break the store -> session -> surface -> closure -> store
        // retain cycle. MUST stay after the onExitCodeCaptured?(code) call above, which niling earlier would
        // silently drop. no libghostty callback fires once the surface is freed.
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

    /// Swaps libghostty's `CALayer` subclass out for a plain one, keeping the last painted frame as its
    /// contents so a pane about to be unmounted does not blank for a frame first. The contents are an
    /// `IOSurface` the layer retains, so carrying the reference over outlives the freed renderer.
    private func dropGhosttyLayer() {
        let plain = CALayer()
        if let stale = layer {
            plain.frame = stale.frame
            plain.contentsScale = stale.contentsScale
            plain.contentsGravity = stale.contentsGravity
            plain.contents = stale.contents
        }
        layer = plain
    }

    /// `TerminalSurface` conformance: the model calls this when the owning session is closed.
    func teardown() {
        destroySurface()
    }

    /// `TerminalSurface.isRealized`: the libghostty surface — and with it the spawned program — exists. False
    /// while `createSurface` is still deferred on a zero backing size (`pendingSurfaceCreation`) and after
    /// `destroySurface`, both of which leave `surface` nil.
    var isRealized: Bool { surface != nil }

    // MARK: - Window / size

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // above the nil-window guard: DETACHING is the transition nothing else reports. Hiding the quick
        // terminal unmounts its view with `deckVisible`/`viewOnly`/`surface` all unchanged, so this is the
        // only site that can clear the latch — below the guard it never ran, and the re-show then compared
        // equal and stayed silent too.
        postAccessibilityExposureChange()
        updateRendererVisibility()
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
        // focus is driven by TerminalView.updateNSView when this surface becomes the active session's detail
        // view; only an auto-focus (overlay) surface grabs here, since that grab misses a deferred surface.
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

    /// Record this surface's light/dark scheme from the authoritative app-level `isDark`
    /// (`NSApp.effectiveAppearance`), so the NEXT `update_config` re-resolves a dual `theme = light:,dark:` to
    /// the matching side: libghostty takes the active side from the surface's RECORDED conditional state, not
    /// the config file alone, so a surface created before its window's appearance resolved re-derives the
    /// WRONG side. Cheap to re-assert (`set_color_scheme` early-returns unchanged); the caller sets the APP side.
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
        // the split re-parent invalidates the Metal drawable, and neither a same-grid set_size nor the tick
        // (dirty surfaces only) repaints it — force one or the re-hosted pane stays blank over a live buffer.
        ghostty_surface_refresh(surface)
    }
}
