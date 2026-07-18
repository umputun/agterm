import agtermCore
import AppKit
import os

private let logger = Logger(subsystem: "com.umputun.agterm", category: "CustomCommandRunner")

/// Drives user-defined custom commands: an app-wide `NSEvent` local key monitor turns key presses
/// into chords, a `CustomCommandEngine` resolves them to a command (firing simple chords and leader
/// sequences like `ctrl+a > g`), and a fired command is run as a detached `/bin/sh -c` with the
/// active session's context available as both `{AGT_X}` template tokens and `$AGT_X` environment.
///
/// `@MainActor` and constructed once as `@State` in `agtermApp`. `start()`/`stop()` install/remove
/// the monitor (the asymmetric lifecycle the control server uses); `start()` is idempotent because
/// the scene `.task` fires once per window. The matcher is rebuilt from the keymap on `start()` and
/// on the `.agtermKeymapChanged` notification. Pure parsing/matching/expansion lives in agtermCore;
/// this class only maps `NSEvent` → agtermCore types, owns the leader timeout timer, resolves the
/// focused surface's owning session via the host-free `WindowLibrary`, and spawns the process.
@MainActor
final class CustomCommandRunner {
    private let library: WindowLibrary
    private let settings: SettingsModel
    private let socketProvider: () -> String

    private var commandEngine = CustomCommandEngine(commands: [])

    private var keyMonitor: Any?
    private var leaderTimer: Timer?
    private var keymapObserver: NSObjectProtocol?

    /// How long a half-typed leader sequence waits for its next chord before abandoning (kitty-style).
    private static let leaderTimeout: TimeInterval = 1.5

    init(library: WindowLibrary, settings: SettingsModel, socketProvider: @escaping () -> String) {
        self.library = library
        self.settings = settings
        self.socketProvider = socketProvider
    }

    /// Install the local `.keyDown` monitor (idempotent), build the keybind map from the current
    /// keymap, and observe `.agtermKeymapChanged` to rebuild on a keymap reload.
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

    /// Rebuild the matcher and the id→command map from the current keymap, skipping empty shortcuts
    /// (palette-only commands have none). Cross-section validation in `parseKeymap` already clears the
    /// shortcut of any command whose first chord collides with a built-in or another custom command,
    /// so a conflicted bind arrives here with an empty shortcut and is dropped from the matcher.
    private func rebuild() {
        let commands = settings.keymap.commands
        for command in commands where !command.shortcut.isEmpty {
            if parseKeybind(command.shortcut) == nil {
                logger.notice("custom command \"\(command.name, privacy: .public)\" has invalid shortcut \"\(command.shortcut, privacy: .public)\"; skipping keybind")
            }
        }
        commandEngine = CustomCommandEngine(commands: commands)
        cancelLeaderTimer()
    }

    /// The Esc virtual keycode the matcher treats specially (the leader abort); Return is a bindable
    /// base key handled via `namedKeys`, not here.
    private static let escapeKeyCode: UInt16 = 53

    /// Feed one key event to the matcher. Returns whether the event was consumed (so the caller drops
    /// it). Esc while armed resets and is consumed; a `.fired` runs and is consumed; `.armed` arms the
    /// leader timer and is consumed; `.unmatched` passes through to the terminal.
    ///
    /// Acts when the key window's first responder is a terminal surface (context from that surface), OR
    /// when the key window is an agterm terminal window whose focus is NOT on a text field — including
    /// one emptied to zero sessions (the SSH-disconnect state where every session's shell exited). It
    /// passes through for a focused text field (Settings editor, inline rename, palette search) so a
    /// bound chord never eats those keystrokes, and for an auxiliary window (Settings) whose focus is off
    /// a text field. A key repeat is ignored so a held-down shortcut spawns one process, not one per OS
    /// repeat.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !event.isARepeat else { return false }
        guard let keyWindow = NSApp.keyWindow else { return false }
        let responder = keyWindow.firstResponder
        // a focused text field (Settings editor, inline rename, palette search) becomes the window's
        // NSText field editor; it must keep its keystrokes, so drop any half-typed leader and pass through.
        if responder is NSText {
            if commandEngine.isArmed {
                commandEngine.reset()
                cancelLeaderTimer()
            }
            return false
        }
        let focusedSurface = responder as? GhosttySurfaceView
        // with no focused terminal surface, fire ONLY from an agterm terminal window (an empty one still
        // qualifies) — never from an auxiliary window like Settings whose focus sits off a text field.
        guard focusedSurface != nil || WindowRegistry.shared.contains(keyWindow) else {
            if commandEngine.isArmed {
                commandEngine.reset()
                cancelLeaderTimer()
            }
            return false
        }
        // Esc abandons a half-typed leader sequence (the same call the timeout makes); it never
        // advances the matcher (Esc is not a bindable base key), so handle it before deriving a chord.
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
        switch commandEngine.advance(chord) {
        case .fired(let command):
            cancelLeaderTimer()
            if let focusedSurface {
                // resolve context from the surface that actually had focus at key-down time, NOT the
                // frontmost active session — firing from a split/overlay/quick terminal (or during a
                // window-switch race) must run against THAT surface's session/cwd/selection.
                runFromKeybind(command, focusedSurface: focusedSurface)
            } else {
                // no fired-from surface (an emptied window, or focus off any surface in a terminal
                // window): use the active session if one exists, else the session-free launcher path.
                runNoSurface(command)
            }
            return true
        case .armed:
            startLeaderTimer()
            return true
        case .unmatched:
            cancelLeaderTimer()
            return false
        }
    }

    /// Map an `NSEvent` key-down to an agtermCore `Chord`, or nil when it carries no usable base key.
    /// Modifiers map to the agtermCore `Modifier` set; the base key is the named special key (for the
    /// keys the parser names) else the unmodified character lowercased, matching `parseKeybind`.
    private func chord(from event: NSEvent) -> Chord? {
        var mods: Modifier = []
        let flags = event.modifierFlags
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }

        if let named = Self.namedKeys[event.keyCode] {
            return Chord(mods: mods, key: named)
        }
        // Derive the UNSHIFTED base key so every key normalizes the same way. `charactersIgnoringModifiers`
        // KEEPS shift (shift+/ → "?", shift+= → "+"), and `.lowercased()` only undoes that for letters, so
        // punctuation would otherwise land on the shifted glyph and never match a `shift+/`-style binding.
        // `characters(byApplyingModifiers: [])` applies NO modifiers, giving the base char for any key
        // (shift+/ → "/", shift+5 → "5", shift+u → "u"), matching how the keymap spells chords as
        // `shift+<base>` (same call `GhosttySurfaceView` uses for unmodified key input).
        guard let chars = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
              let first = chars.first else { return nil }
        let key = String(first).lowercased()
        guard !key.isEmpty, key != " " else { return nil }
        return Chord(mods: mods, key: key)
    }

    /// The special keys `parseKeybind` names, by macOS virtual keycode.
    private static let namedKeys: [UInt16: String] = [48: "tab", 49: "space", 36: "return", 51: "delete"]

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

    /// Run a command fired from the PALETTE: resolve context from the active session (the palette has no
    /// first responder to key off). Detached `/bin/sh -c` with the `AGT_*` env, notifying on a spawn
    /// error or non-zero exit. No-op when no window/session is active — firing a session-scoped command
    /// with silently-empty tokens is unsafe (an empty `{AGT_SESSION_PWD}` turns `rm -rf …/*` into a root
    /// glob), so only the deliberate empty-window KEYBIND path (handleKeyDown) fires a session-free
    /// launcher via `sessionlessContext()`.
    func run(_ command: CustomCommand) {
        guard let store = library.activeStore, let session = store.activeSession else {
            logger.notice("custom command \"\(command.name, privacy: .public)\" fired with no active session; ignored")
            return
        }
        // palette path: selection + pane both come from the active session's focused pane. the palette has
        // no fired-from surface to key off, so the focus flag is the source — but gated on the split surface
        // EXISTING (the `Session.onScreenSurface` idiom, `splitFocused && splitSurface != nil`): in the
        // window right after `session split on`, `splitFocused` is already true while `splitSurface` is
        // still nil, so a bare flag would report `.right` (and read the selection from the nil split
        // surface) when `session.type --pane right` still errors "no split pane". A promoted survivor now
        // lives in the `surface` slot with `splitSurface == nil` and `splitFocused == false`, so `onSplit`
        // is false and it reports `.left` — the pane `--pane left` reaches.
        let onSplit = session.splitFocused && session.splitSurface != nil
        let selectionSurface = (onSplit ? session.splitSurface : session.surface) as? GhosttySurfaceView
        let context = self.context(for: session, in: store, selectionSurface: selectionSurface,
                                   pane: onSplit ? .right : .left)
        spawn(command, context: context)
    }

    /// Run a command fired by KEYBIND: resolve context from the surface that actually had focus at
    /// key-down time, so a chord fired from a split/scratch (or during a window-switch race) runs
    /// against THAT surface's session/cwd/window and reads the selection from THAT exact surface. The
    /// owning session/store come from the focused surface's `session` resolved through the host-free
    /// `WindowLibrary` (no AppKit lives in core). A sessionless focused surface (quick terminal /
    /// overlay / scratch) routes through `runFromSessionlessSurface`, which reports `.scratch` for the
    /// active session's scratch and otherwise takes the palette path.
    func runFromKeybind(_ command: CustomCommand, focusedSurface: GhosttySurfaceView) {
        guard let session = focusedSurface.session, let store = library.store(forSession: session.id) else {
            runFromSessionlessSurface(command, focusedSurface: focusedSurface)
            return
        }
        // the fired-from pane is the surface's identity, not the session's focus flag — a chord fired
        // from a pane the focus flag hasn't caught up to still reports the pane it was typed in.
        let pane: CommandContext.Pane = (session.splitSurface as? GhosttySurfaceView) === focusedSurface ? .right : .left
        let context = self.context(for: session, in: store, selectionSurface: focusedSurface, pane: pane)
        spawn(command, context: context)
    }

    /// The keybind fallback for a sessionless focused surface (no `view.session`: the quick terminal,
    /// an overlay, or the scratch). The scratch belongs to the ACTIVE session, so a chord fired from it
    /// runs against that session with `pane = .scratch` and reads the scratch's own selection — the read
    /// leg of the `$AGT_PANE` → `session type --pane scratch` round-trip. The quick terminal and overlays
    /// are not panes (their state is queryable via `tree`), so they take the plain palette path.
    private func runFromSessionlessSurface(_ command: CustomCommand, focusedSurface: GhosttySurfaceView) {
        if let store = library.activeStore, let session = store.activeSession,
           (session.scratchSurface as? GhosttySurfaceView) === focusedSurface {
            let context = self.context(for: session, in: store, selectionSurface: focusedSurface, pane: .scratch)
            spawn(command, context: context)
            return
        }
        runNoSurface(command)
    }

    /// Run a command fired by keybind with NO usable fired-from session — an emptied window, or focus off
    /// any surface (the dashboard key-catcher, a quick terminal / overlay with no owning session). Uses
    /// the active session's context when one exists (like the palette), else the session-free launcher
    /// path via `spawnSessionless`.
    private func runNoSurface(_ command: CustomCommand) {
        if library.activeStore?.activeSession != nil {
            run(command)
        } else {
            spawnSessionless(command)
        }
    }

    /// Fire `command` with a session-free context (the empty-window launcher path) — UNLESS its body
    /// references session-scoped tokens, which expand dangerously empty with no session (an empty
    /// `{AGT_SESSION_PWD}` makes `rm -rf …/*` a root glob, defeating even the quoted `$AGT_X` form). Such
    /// a command NO-OPS with a notice, exactly like the palette's `run(_:)`; a launcher (referencing only
    /// `AGT_SOCKET`/`AGT_WINDOW`/`AGT_PANE`, e.g. `agtermctl session new --command "ssh …"`) still fires.
    private func spawnSessionless(_ command: CustomCommand) {
        guard !CommandContext.referencesSessionScopedContext(command.command) else {
            logger.notice("custom command \"\(command.name, privacy: .public)\" references session context but no session is active; ignored")
            return
        }
        spawn(command, context: sessionlessContext())
    }

    /// Resolve every `{AGT_X}` token for the given session: ids + cwd from the model, the names from
    /// the owning workspace/window, the selection from `selectionSurface` (the exact focused surface),
    /// the fired-from pane (`left`|`right`|`scratch`) from the caller, and the socket from the control server.
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

    /// A session-free `CommandContext` for a command fired with no active session (an emptied window, or
    /// none open): every `{AGT_SESSION_*}`/`{AGT_WORKSPACE_*}` token and the selection resolve empty, the
    /// window id/name come from the frontmost window when there is one, and the socket lets a launcher
    /// chord reach `agtermctl` to create a fresh session.
    private func sessionlessContext() -> CommandContext {
        let windowID = library.activeWindowID
        return CommandContext(windowID: windowID?.uuidString ?? "", windowName: library.windowName(for: windowID),
                              socket: socketProvider())
    }

    /// Spawn the expanded command as a detached `/bin/sh -c`, exporting `$AGT_*` on top of the app's
    /// environment and running in the session's cwd. A thrown spawn error or a non-zero exit posts a
    /// failure banner; there is no output capture and no success banner.
    private func spawn(_ command: CustomCommand, context: CommandContext) {
        let line = context.expand(command.command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        process.environment = ProcessInfo.processInfo.environment.merging(context.environment()) { _, new in new }
        // fire-and-forget: no output capture, so pin stdio to /dev/null rather than inheriting the
        // app's fds (which vary by launch method).
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
