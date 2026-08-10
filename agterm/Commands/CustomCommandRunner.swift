import agtermCore
import AppKit
import os

private let logger = Logger(subsystem: "com.umputun.agterm", category: "CustomCommandRunner")

/// Drives user-defined custom commands: an app-wide `NSEvent` local key monitor turns key presses into
/// chords, a `CustomCommandEngine` resolves them (simple chords and leader sequences like `ctrl+a > g`), and
/// a fired command runs detached as `/bin/sh -c` with the session's context in `{AGT_X}` tokens and `$AGT_X`
/// environment. The same matcher also carries the built-in binds an `NSMenuItem` key equivalent cannot hold —
/// a `map` line's alternatives beyond its first single chord — dispatched through `AppActions.perform(_:in:)`.
///
/// Constructed once as `@State` in `agtermApp`. `start()`/`stop()` install/remove the monitor; `start()` is
/// idempotent because the scene `.task` fires once per window, and the matcher rebuilds there and on
/// `.agtermKeymapChanged`. Pure parsing/matching/expansion lives in agtermCore; this maps `NSEvent` → core
/// types, owns the leader timer, resolves the surface's session via the host-free `WindowLibrary`, and spawns.
@MainActor
final class CustomCommandRunner {
    private let library: WindowLibrary
    private let settings: SettingsModel
    private let actions: AppActions
    private let socketProvider: () -> String

    private var commandEngine = CustomCommandEngine(commands: [])

    private var keyMonitor: Any?
    private var leaderTimer: Timer?
    private var keymapObserver: NSObjectProtocol?

    /// How long a half-typed leader sequence waits for its next chord before abandoning (kitty-style).
    private static let leaderTimeout: TimeInterval = 1.5

    init(library: WindowLibrary, settings: SettingsModel, actions: AppActions,
         socketProvider: @escaping () -> String) {
        self.library = library
        self.settings = settings
        self.actions = actions
        self.socketProvider = socketProvider
    }

    /// Install the local `.keyDown` monitor (idempotent), build the keybind map, observe `.agtermKeymapChanged`.
    func start() {
        guard keyMonitor == nil else { return }
        rebuild()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // returning nil consumes the event (it never reaches the terminal); event passes it through.
            return self.handleKeyDown(event) ? nil : event
        }
        keymapObserver = NotificationCenter.default.addObserver(
            forName: .agtermKeymapChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    /// Remove the monitor, the keymap observer, and any pending leader timer.
    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let keymapObserver { NotificationCenter.default.removeObserver(keymapObserver) }
        keymapObserver = nil
        cancelLeaderTimer()
    }

    /// Rebuild the matcher from the current keymap — custom commands plus the built-in monitor binds — skipping
    /// empty shortcuts (palette-only commands have none). `parseKeymap`'s cross-section validation already
    /// empties the shortcut of a command colliding with a built-in or another custom one, so it drops out of
    /// the matcher.
    private func rebuild() {
        let keymap = settings.keymap
        commandEngine = CustomCommandEngine(commands: keymap.commands, builtinSequences: keymap.builtinSequences)
        cancelLeaderTimer()
    }

    /// The Esc virtual keycode the matcher treats specially (the leader abort); Return is bindable and goes
    /// through `namedKey(forKeyCode:)`.
    private static let escapeKeyCode: UInt16 = 53

    /// Feed one key event to the matcher; returns whether it was consumed (so the caller drops it). Esc while
    /// armed resets, `.fired` runs a command, `.firedBuiltin` runs a built-in action, `.armed` arms the leader
    /// timer, and `toggle_fullscreen`'s chord toggles full screen without reaching the matcher at all — all
    /// consumed; `.unmatched` passes through.
    ///
    /// Acts when the key window's first responder is a terminal surface (context from that surface), or when
    /// the key window is an agterm terminal window whose focus is NOT on a text field — including one emptied
    /// to zero sessions. Passes through for a focused text field (Settings editor, inline rename, palette
    /// search) so a bound chord never eats those keystrokes, and for an auxiliary window focused off a text
    /// field. A key repeat is ignored, so a held-down shortcut spawns one process, not one per OS repeat.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let keyWindow = NSApp.keyWindow else { return false }
        return handleKeyDown(event, in: keyWindow)
    }

    /// Everything after the key-window lookup, split out so a test can supply the window: a hosted test's
    /// own window never becomes `NSApp.keyWindow` (the app is not active), so `handleKeyDown(_:)` returns at
    /// that guard and none of this runs. Internal for that reason alone, like
    /// `ControlServer.collectKeyEquivalents`.
    func handleKeyDown(_ event: NSEvent, in keyWindow: NSWindow) -> Bool {
        guard !event.isARepeat else { return false }
        let responder = keyWindow.firstResponder
        // a focused text field is the window's NSText field editor and must keep its keystrokes: drop the
        // half-typed leader, pass through.
        if responder is NSText {
            if commandEngine.isArmed {
                commandEngine.reset()
                cancelLeaderTimer()
            }
            return false
        }
        let focusedSurface = responder as? GhosttySurfaceView
        // with no focused surface, fire ONLY from an agterm terminal window (empty qualifies), never Settings.
        guard focusedSurface != nil || WindowRegistry.shared.contains(keyWindow) else {
            if commandEngine.isArmed {
                commandEngine.reset()
                cancelLeaderTimer()
            }
            return false
        }
        // esc abandons a half-typed leader (the call the timeout makes) and is not bindable, so it comes
        // before the chord.
        if event.keyCode == Self.escapeKeyCode {
            guard commandEngine.isArmed else { return false }
            commandEngine.reset()
            cancelLeaderTimer()
            return true
        }
        guard let chord = chord(from: event) else {
            // a key with no usable base (e.g. a bare modifier) can't advance; while armed, keep waiting.
            return false
        }
        // `toggle_fullscreen` is the one built-in with no menu item to carry its equivalent: AppKit appends
        // the only full screen item there is, at menu-display time, and an item of agterm's own beside it is
        // the duplicate this avoids. So the rebindable chord is matched here instead. A half-typed leader
        // sequence still wins, exactly as it does over a custom command sharing its first chord.
        // Its MENU chord alone comes through here, ungated; an alternative of the same `map` line goes the
        // ordinary `.firedBuiltin` route and so takes that route's modal rule.
        if !commandEngine.isArmed, chord == settings.keymap.equivalent(for: .toggleFullscreen) {
            keyWindow.toggleFullScreen(nil)
            return true
        }
        switch commandEngine.advance(chord) {
        case .fired(let command):
            cancelLeaderTimer()
            if let focusedSurface {
                // context from the surface that had focus at key-down, not the frontmost active session.
                runFromKeybind(command, focusedSurface: focusedSurface)
            } else {
                // no fired-from surface: the active session if one exists, else the launcher path.
                runNoSurface(command)
            }
            return true
        case .firedBuiltin(let action):
            cancelLeaderTimer()
            // no focusedSurface/runNoSurface split: a built-in acts on the active session and key window,
            // like the palette row behind it. Consumed even when `perform` finds the action gated out: the
            // gate lives inside each action, so this cannot see the outcome, and passing a leader's LAST chord
            // through after swallowing its prefix would type a stray character into the terminal.
            actions.perform(action, in: keyWindow)
            return true
        case .armed:
            startLeaderTimer()
            return true
        case .unmatched:
            cancelLeaderTimer()
            return false
        }
    }

    /// Map an `NSEvent` key-down to an agtermCore `Chord`, or nil when it carries no usable base key. The base
    /// key is the named special key, else what `chordKey` resolves — the unmodified character on a layout that
    /// can type ASCII, the physical position on one that cannot.
    private func chord(from event: NSEvent) -> Chord? {
        var mods: Modifier = []
        let flags = event.modifierFlags
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }

        if let named = namedKey(forKeyCode: event.keyCode) {
            return Chord(mods: mods, key: named)
        }
        // `characters(byApplyingModifiers: [])` gives the UNSHIFTED base key (shift+/ → "/"), matching how
        // the keymap spells `shift+<base>`. `charactersIgnoringModifiers` instead KEEPS shift (shift+/ → "?")
        // and `.lowercased()` undoes that only for letters, so punctuation would land on the shifted glyph
        // and never match a `shift+/` binding. `chordKey` then applies the layout rule, so `cmd+o` still
        // fires on a Cyrillic layout (the key types `щ`).
        let produced = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers
        guard let key = chordKey(forKeyCode: event.keyCode, produced: produced,
                                 layoutIsASCIICapable: KeyboardLayout.isASCIICapable) else { return nil }
        return Chord(mods: mods, key: key)
    }

    private func startLeaderTimer() {
        cancelLeaderTimer()
        leaderTimer = Timer.scheduledTimer(withTimeInterval: Self.leaderTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.commandEngine.reset()
                self.leaderTimer = nil
            }
        }
    }

    private func cancelLeaderTimer() {
        leaderTimer?.invalidate()
        leaderTimer = nil
    }

    /// Run a command fired from the PALETTE: context from the active session (the palette has no first
    /// responder to key off). No-op with no window/session — a session-scoped command with silently-empty
    /// tokens is unsafe (an empty `{AGT_SESSION_PWD}` turns `rm -rf …/*` into a root glob), so only the
    /// deliberate empty-window KEYBIND path fires a session-free launcher.
    func run(_ command: CustomCommand) {
        guard let store = library.activeStore, let session = store.activeSession else {
            logger.notice("custom command \"\(command.name, privacy: .public)\" fired with no active session; ignored")
            return
        }
        // selection + pane come from the active session's focused pane; with no fired-from surface the focus
        // flag is the source, gated on the split surface EXISTING. right after `session split on`,
        // `splitFocused` is already true while `splitSurface` is still nil, so a bare flag would report
        // `.right` off a nil surface while `session.type --pane right` still errors "no split pane". a
        // promoted survivor sits in the `surface` slot with both nil/false, so `.left`.
        let onSplit = session.splitFocused && session.splitSurface != nil
        let selectionSurface = (onSplit ? session.splitSurface : session.surface) as? GhosttySurfaceView
        let context = self.context(for: session, in: store, selectionSurface: selectionSurface,
                                   pane: onSplit ? .right : .left)
        spawn(command, context: context)
    }

    /// Run a command fired by KEYBIND: context from the surface that had focus at key-down, so a chord from a
    /// split/scratch (or during a window-switch race) runs against THAT surface's session/cwd/window and reads
    /// its selection. A sessionless focused surface routes through `runFromSessionlessSurface`.
    func runFromKeybind(_ command: CustomCommand, focusedSurface: GhosttySurfaceView) {
        guard let session = focusedSurface.session, let store = library.store(forSession: session.id) else {
            runFromSessionlessSurface(command, focusedSurface: focusedSurface)
            return
        }
        // the pane is the surface's identity, not the focus flag, so a chord reports the pane it was typed in
        // even before the flag catches up.
        let pane: CommandContext.Pane = (session.splitSurface as? GhosttySurfaceView) === focusedSurface ? .right : .left
        let context = self.context(for: session, in: store, selectionSurface: focusedSurface, pane: pane)
        spawn(command, context: context)
    }

    /// The keybind fallback for a sessionless focused surface (quick terminal, overlay, scratch). The scratch
    /// belongs to the ACTIVE session, so a chord from it runs against that session with `pane = .scratch` and
    /// reads the scratch's own selection — the read leg of `$AGT_PANE` → `session type --pane scratch`. The
    /// others are not panes and take the plain palette path.
    private func runFromSessionlessSurface(_ command: CustomCommand, focusedSurface: GhosttySurfaceView) {
        if let store = library.activeStore, let session = store.activeSession,
           (session.scratchSurface as? GhosttySurfaceView) === focusedSurface {
            let context = self.context(for: session, in: store, selectionSurface: focusedSurface, pane: .scratch)
            spawn(command, context: context)
            return
        }
        runNoSurface(command)
    }

    /// Keybind fire with NO usable fired-from session — an emptied window, or focus off any surface. Uses the
    /// active session's context when one exists, like the palette, else `spawnSessionless`.
    private func runNoSurface(_ command: CustomCommand) {
        if library.activeStore?.activeSession != nil {
            run(command)
        } else {
            spawnSessionless(command)
        }
    }

    /// Fire `command` with a session-free context (the empty-window launcher path) — UNLESS its body names
    /// session-scoped tokens, which expand dangerously empty (an empty `{AGT_SESSION_PWD}` makes `rm -rf …/*`
    /// a root glob, defeating even the quoted `$AGT_X` form); that NO-OPS with a notice. A launcher naming
    /// only `AGT_SOCKET`/`AGT_WINDOW`/`AGT_PANE` still fires.
    private func spawnSessionless(_ command: CustomCommand) {
        guard !CommandContext.referencesSessionScopedContext(command.command) else {
            logger.notice("custom command \"\(command.name, privacy: .public)\" references session context but no session is active; ignored")
            return
        }
        spawn(command, context: sessionlessContext())
    }

    /// Resolve every `{AGT_X}` token for the given session: ids + cwd from the model, names from the owning
    /// workspace/window, the selection from `selectionSurface`, the fired-from pane from the caller
    /// (`left`|`right`|`scratch`), the socket from the control server.
    private func context(for session: Session, in store: AppStore, selectionSurface: GhosttySurfaceView?,
                         pane: CommandContext.Pane) -> CommandContext {
        let workspace = store.workspace(forSession: session.id)
        let windowID = library.windowID(forSession: session.id)
        let windowName = library.windowName(for: windowID)
        return CommandContext(
            sessionID: session.id.uuidString,
            sessionName: session.displayName,
            sessionPWD: session.effectiveCwd,
            workspaceID: workspace?.id.uuidString ?? "",
            workspaceName: workspace?.name ?? "",
            windowID: windowID?.uuidString ?? "",
            windowName: windowName,
            pane: pane,
            selection: selectionSurface?.readSelection() ?? "",
            socket: socketProvider()
        )
    }

    /// A session-free `CommandContext` (an emptied window, or none open): every `{AGT_SESSION_*}`/
    /// `{AGT_WORKSPACE_*}` token and the selection resolve empty, window id/name come from the frontmost
    /// window if any, and the socket lets a launcher chord reach `agtermctl` for a fresh session.
    private func sessionlessContext() -> CommandContext {
        let windowID = library.activeWindowID
        return CommandContext(windowID: windowID?.uuidString ?? "", windowName: library.windowName(for: windowID),
                              socket: socketProvider())
    }

    /// Spawn the expanded command as a detached `/bin/sh -c`, exporting `$AGT_*` over the app environment and
    /// running in the session's cwd. `PATH` is widened first (`CommandPath`): the app's own is launchd's, and
    /// `sh -c` runs no profile, so a bare `agtermctl` would exit 127. A spawn error or non-zero exit posts a
    /// failure banner; no output capture, no success banner.
    private func spawn(_ command: CustomCommand, context: CommandContext) {
        let line = context.expand(command.command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        var environment = ProcessInfo.processInfo.environment.merging(context.environment()) { _, new in new }
        environment["PATH"] = CommandPath.widened(environment["PATH"],
                                                  bundledCLIDirectory: CLIInstaller.bundledTool?
                                                      .deletingLastPathComponent().path)
        process.environment = environment
        // fire-and-forget: pin stdio to /dev/null rather than inherit the app's fds, which vary by launch.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if !context.sessionPWD.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: context.sessionPWD, isDirectory: true)
        }
        let name = command.name
        process.terminationHandler = { proc in
            guard proc.terminationStatus != 0 else { return }
            let status = proc.terminationStatus
            // the handler fires on an arbitrary queue; hop to the main actor to post the banner.
            DispatchQueue.main.async { NotificationManager.shared.notifyCommandFailure(name: name, detail: "exit \(status)") }
        }
        do {
            try process.run()
        } catch {
            logger.error("custom command \"\(name, privacy: .public)\" failed to spawn: \(error.localizedDescription, privacy: .public)")
            NotificationManager.shared.notifyCommandFailure(name: name, detail: error.localizedDescription)
        }
    }
}
