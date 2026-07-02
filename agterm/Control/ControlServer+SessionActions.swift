import Foundation
import agtermCore

/// `ControlServer` session/workspace/sidebar action arms — the first half of the flat command dispatch
/// (splits, scratch, focus, status, flag, move, notify, quick terminal, sidebar). Each resolves its target
/// through `resolver` and drives the `AppActions`/`AppStore` seam. Split out of `ControlServer.swift` to
/// keep that file under the swiftlint size limit.
extension ControlServer {
    /// Resolve the target session and drive the split directly on its owning store (NOT the
    /// argument-less `AppActions.toggleSplit()`, which only acts on the active session). `mode` is
    /// `on|off|toggle`, computed against the session's current `isSplit` so `on`/`off` are
    /// idempotent. Always via `AppStore.toggleSplit` — a keep-alive hide/show that mirrors ⌘D and
    /// never tears the hidden pane's surface down (`closeSplit` stays the shell-exit-only path).
    /// Focus follows via `AppActions.focusSplitPane`.
    func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard let parsedMode = ControlToggleMode.parse(mode) else {
                return ControlResponse(ok: false, error: "invalid split mode: \(mode ?? "toggle")")
            }
            let want = parsedMode.desiredValue(current: session.isSplit)
            if want != session.isSplit {
                store.toggleSplit(id) // mirror ⌘D: keep-alive hide/show, never destroys the hidden pane
            }
            actions.focusSplitPane(session, wantSplit: session.splitFocused)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve the target session and show/hide its scratch terminal — a third, full-overlay shell.
    /// `mode` is `on|off|toggle`, computed against the session's current `scratchActive` so `on`/`off`
    /// are idempotent. Like the split, hiding keeps the shell alive (`toggleScratch`); `closeScratch`
    /// (tear down) is reserved for the shell's own `exit`. `command` (only meaningful when showing) runs
    /// that program as the scratch's process instead of a login shell, run-once like `session.new
    /// --command`: a scratch is expendable, so if one is already alive it is torn down and respawned
    /// with the command (otherwise the flag would be silently inert).
    func scratchSession(_ target: String?, window: String?, mode: String?, command: String?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard let parsedMode = ControlToggleMode.parse(mode) else {
                return ControlResponse(ok: false, error: "invalid scratch mode: \(mode ?? "toggle")")
            }
            let want = parsedMode.desiredValue(current: session.scratchActive)
            if want, let command, !command.isEmpty {
                // run the command as the scratch process: respawn if one is already alive (a scratch is
                // expendable), so the command is never silently ignored. closeScratch clears scratchActive,
                // so the toggle below re-shows it and the factory consumes scratchCommand.
                if session.scratchSurface != nil { store.closeScratch(id) }
                session.scratchCommand = command
            }
            if want, store.selectedSessionID != id {
                // the scratch is a full-coverage surface that grabs focus on show; it only makes sense on
                // the visible session, so select the target first (mirrors the floating-overlay arm).
                // Otherwise a non-active target's scratch surface would steal first responder while hidden.
                store.selectSession(id)
            }
            if want != session.scratchActive {
                store.toggleScratch(id) // keep-alive hide/show, mirrors ⌘J; never tears the shell down
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Move keyboard focus to a split session's left/right pane. `pane` is `left`|`right`|`other`
    /// (`other` toggles). Errors when the session isn't split or the pane value is unknown.
    func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard session.hasSplit else {
                return ControlResponse(ok: false, error: "session has no split")
            }
            guard let parsedPane = ControlPaneFocusMode.parse(pane) else {
                return ControlResponse(ok: false, error: "invalid pane: \(pane ?? "other")")
            }
            let toSplit = parsedPane.wantsSplit(currentSplitFocused: session.splitFocused)
            actions.setSplitFocus(toSplit, of: session)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resize a split session's divider (control-native: no GUI/menu equivalent — the GUI resizes by
    /// dragging the divider). `ratio` is an absolute left-pane fraction; `delta` is a signed relative nudge
    /// (positive grows the left pane) applied to the session's current fraction (0.5 when never moved).
    /// Exactly one must be set. The clamped fraction is stored + persisted via `AppStore.applySplitRatio`,
    /// then `.agtermApplySplitRatio` pokes the session's `SplitProbeView` to move the live divider (a no-op
    /// when the split is hidden — the stored value applies on next show). Errors when the session has no
    /// split, mirroring `session.focus`. Echoes the applied (clamped) fraction in `result.ratio`.
    func resizeSplit(_ target: String?, window: String?, ratio: Double?, delta: Double?) -> ControlResponse {
        switch (ratio, delta) {
        case (nil, nil):
            return ControlResponse(ok: false, error: "session.resize requires --split-ratio, --grow-left, or --grow-right")
        case (.some, .some):
            return ControlResponse(ok: false, error: "session.resize: --split-ratio is mutually exclusive with --grow-left/--grow-right")
        default:
            break
        }
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard session.hasSplit else {
                return ControlResponse(ok: false, error: "session has no split")
            }
            let requested = ratio ?? ((session.splitRatio ?? AppStore.splitRatioDefault) + (delta ?? 0))
            guard let applied = store.applySplitRatio(requested, forSession: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            NotificationCenter.default.post(name: .agtermApplySplitRatio, object: session)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, ratio: applied))
        }
    }

    /// Set the target session's agent-status indicator (control-native: no GUI/menu equivalent, like
    /// `notify`/`session.type`/`session.copy`). `status` is `idle|active|completed|blocked`; an unknown
    /// value is the structured `invalid status` error. `blink` (default false) pulses the glyph;
    /// `autoReset` (default false) clears the indicator to idle once the session is visited. `sound`, when
    /// non-empty, plays a one-shot sound once the status is applied (`default`/`beep` = system alert, any
    /// other value = named system sound); it is validated up-front so an unknown name is an `unknown sound`
    /// error that leaves the status unchanged (an empty value is treated as no per-call sound). When no
    /// per-call `sound` is given and the session TRANSITIONS into `blocked`, the user's configured Settings
    /// "Blocked sound" (`blockedStatusSoundName`) plays as a best-effort default. The indicator is ephemeral
    /// and rendered on every non-idle session.
    /// The per-call status payload for `setSessionStatus`; the addressing target/window stay separate.
    struct StatusUpdate {
        let status: String?
        let blink: Bool?
        let autoReset: Bool?
        let sound: String?
    }

    func setSessionStatus(_ target: String?, window: String?, update: StatusUpdate) -> ControlResponse {
        let status = update.status, blink = update.blink, autoReset = update.autoReset, sound = update.sound
        guard let parsed = AgentStatus(rawValue: status ?? "") else {
            return ControlResponse(ok: false, error: "invalid status")
        }
        // an explicit per-call sound is validated up-front: an unknown name errors without changing status.
        // an empty value is treated as no per-call sound, matching `AgentStatus.effectiveSound`.
        if let sound, !sound.isEmpty, StatusSoundPlayer.shared.action(for: sound) == nil {
            let hint = StatusSoundPlayer.standardNames.joined(separator: ", ")
            return ControlResponse(ok: false, error: "unknown sound: \(sound) (use 'default', 'beep', or one of: \(hint))")
        }
        return resolver.resolveSession(target, window: window) { store, id in
            // capture the status BEFORE mutating so the Settings default plays only on a real transition.
            let wasBlocked = store.session(withID: id)?.agentIndicator.status == .blocked
            store.setAgentIndicator(AgentIndicator(status: parsed, blink: blink ?? false,
                                                   autoReset: autoReset ?? false), forSession: id)
            // explicit per-call sound wins on any status; the Settings default plays only when a session
            // newly enters `blocked`, not on a repeated `blocked` set.
            let blockedDefault = wasBlocked ? nil : self.settingsModel.settings.blockedStatusSoundName
            if let name = parsed.effectiveSound(perCall: sound, blockedDefault: blockedDefault) {
                StatusSoundPlayer.shared.play(name)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Flag/unflag the target session for the flagged working-set view (the durable `Session.flagged`
    /// membership the flat sidebar mode projects). `mode` is `on|off|toggle|clear`, computed against the
    /// session's current `flagged` so `on`/`off` are idempotent. `clear` ignores the target and unflags
    /// every session in the resolved store (frontmost or `--window`), via `AppStore.clearFlags()` — it
    /// reports ok with no id. An unknown mode is an error.
    func flagSession(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        if mode == "clear" {
            return resolver.resolvePlacementStore(window) { store in
                store.clearFlags()
                return ControlResponse(ok: true)
            }
        }
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            let want: Bool
            switch mode {
            case "on": want = true
            case "off": want = false
            case "toggle": want = !session.flagged
            default: return ControlResponse(ok: false, error: "invalid flag mode: \(mode)")
            }
            store.setFlag(want, forSession: id) // no-op + no save when unchanged (idempotent)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Mode-bearing `session.move`: `to` reorders the session within its own workspace
    /// (`up`|`down`|`top`|`bottom`), `workspace` relocates it to another workspace (appending). Exactly
    /// one of the two is required; both set or neither set is an error. An invalid `to` direction errors.
    func moveSession(_ target: String?, window: String?, to: String?, workspace: String?) -> ControlResponse {
        if to != nil && workspace != nil {
            return ControlResponse(ok: false, error: "session.move takes either --to or a workspace, not both")
        }
        if let to {
            guard let dir = ReorderDirection(rawValue: to) else {
                return ControlResponse(ok: false, error: "session.move --to must be up|down|top|bottom")
            }
            return resolver.resolveSession(target, window: window) { store, id in
                store.reorderSession(id, dir)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        }
        guard let workspace else {
            return ControlResponse(ok: false, error: "session.move requires --to or a workspace")
        }
        // the session and the destination workspace must live in the same store: resolve the
        // session first (which fixes the store), then the workspace within that same store.
        return resolver.resolveSession(target, window: window) { store, sessionID in
            resolver.resolve(workspace, candidates: store.workspaces.map(\.id),
                    active: store.currentWorkspaceID, noun: "workspace") { workspaceID in
                store.moveSession(sessionID, toWorkspace: workspaceID)
                return ControlResponse(ok: true, result: ControlResult(id: sessionID.uuidString))
            }
        }
    }

    /// `workspace.move`: reorder a workspace among its siblings (`up`|`down`|`top`|`bottom`). `to` is
    /// required; an invalid direction errors. Resolves the workspace target via `resolveWorkspace`
    /// (honoring the global `--window` selector like other workspace commands).
    func moveWorkspace(_ target: String?, window: String?, to: String?) -> ControlResponse {
        guard let to else {
            return ControlResponse(ok: false, error: "workspace.move requires --to")
        }
        guard let dir = ReorderDirection(rawValue: to) else {
            return ControlResponse(ok: false, error: "workspace.move --to must be up|down|top|bottom")
        }
        return resolver.resolveWorkspace(target, window: window) { store, id in
            store.reorderWorkspace(id, dir)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Focus (or unfocus) a workspace — collapse the sidebar tree to that workspace's subtree, or restore
    /// the full tree. `mode` is `on|off|toggle`: `on` focuses the target, `off` unfocuses it only when it
    /// is the currently focused one (a no-op otherwise), `toggle` flips. Delta-computed via
    /// `AppStore.setFocusedWorkspace` so a no-op mode skips the write (idempotent). An unknown mode is an
    /// error. The control half of the workspace row's Focus/Unfocus menu + the pill ✕.
    func focusWorkspace(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        return resolver.resolveWorkspace(target, window: window) { store, id in
            let want: UUID?
            switch mode {
            case "on": want = id
            case "off": want = store.focusedWorkspaceID == id ? nil : store.focusedWorkspaceID
            case "toggle": want = store.focusedWorkspaceID == id ? nil : id
            default: return ControlResponse(ok: false, error: "invalid focus mode: \(mode)")
            }
            store.setFocusedWorkspace(want) // no-op + no save when unchanged (idempotent)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Post a desktop notification attributed to a session (default: the active session of the
    /// frontmost window, via `resolveSession`). `title` defaults to the session name; `body` is
    /// required. Errors when no open window owns the resolved session.
    func sendNotification(_ target: String?, window: String?, title: String?, body: String?) -> ControlResponse {
        guard let body, !body.isEmpty else {
            return ControlResponse(ok: false, error: "notify requires a body")
        }
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard NotificationManager.shared.send(toSession: session, title: title ?? "", body: body) else {
                return ControlResponse(ok: false, error: "session's window is not open")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Show / hide / toggle the frontmost window's quick terminal (each window owns its own),
    /// flipping only when the requested state differs from the current `isVisible`. An unknown mode
    /// is an error, not a silent no-op; no open window is an error rather than a silent no-op.
    func setQuickTerminal(mode: String?) -> ControlResponse {
        guard let controller = QuickTerminalRegistry.shared.controller(for: library.activeWindowID) else {
            return ControlResponse(ok: false, error: "no open window")
        }
        guard let parsedMode = ControlToggleMode.parse(mode, on: "show", off: "hide") else {
            return ControlResponse(ok: false, error: "invalid quick mode: \(mode ?? "toggle")")
        }
        let want = parsedMode.desiredValue(current: controller.isVisible)
        if want != controller.isVisible {
            if want { controller.show() } else { controller.hide() }
        }
        return ControlResponse(ok: true)
    }

    /// Show / hide / toggle the frontmost window's sidebar (the custom split owns visibility, so there's
    /// no system toggle). Flips only when the requested state differs; an unknown mode is an error, and no
    /// open window is an error rather than a silent no-op.
    func setSidebar(mode: String?) -> ControlResponse {
        guard let store = library.activeStore else {
            return ControlResponse(ok: false, error: "no open window")
        }
        guard let parsedMode = ControlToggleMode.parse(mode, on: "show", off: "hide") else {
            return ControlResponse(ok: false, error: "invalid sidebar mode: \(mode ?? "toggle")")
        }
        let want = parsedMode.desiredValue(current: store.sidebarVisible)
        store.setSidebarVisible(want) // no-op + no save when unchanged (idempotent)
        return ControlResponse(ok: true)
    }

    /// Set the frontmost window's sidebar VIEW mode (the tree vs the flat flagged list) — distinct from
    /// `setSidebar` (visibility). `mode` is `tree|flagged|toggle`, delta-computed so a no-op mode skips
    /// the write (idempotent), via `AppStore.setSidebarMode`. An unknown mode + no-open-window are errors.
    func setSidebarViewMode(mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        guard let store = library.activeStore else {
            return ControlResponse(ok: false, error: "no open window")
        }
        let want: SidebarMode
        switch mode {
        case "tree": want = .tree
        case "flagged": want = .flagged
        case "toggle": want = store.sidebarMode == .tree ? .flagged : .tree
        default: return ControlResponse(ok: false, error: "invalid sidebar mode: \(mode)")
        }
        store.setSidebarMode(want) // no-op + no save when unchanged (idempotent)
        return ControlResponse(ok: true)
    }

    /// Expand every workspace in a window's sidebar tree — the `--window` selector picks the (OPEN) target,
    /// defaulting to the frontmost window (a graceful no-op in flagged mode, which has no workspace rows).
    /// Drives `AppActions.expandAllWorkspaces(in:)` (the same path the View menu / palette drive on the
    /// frontmost). Idempotent (expanding when all are already expanded is a clean no-op); a named-but-closed
    /// window errors, and no open window at all errors rather than silently no-opping.
    func expandWorkspaces(window: String?) -> ControlResponse {
        if trimmed(window) == nil, library.activeStore == nil {
            return ControlResponse(ok: false, error: "no open window")
        }
        return resolver.resolvePlacementStore(window) { store in
            actions.expandAllWorkspaces(in: store)
            return ControlResponse(ok: true)
        }
    }

    /// Collapse every workspace except the active one (the active session's workspace) in a window's
    /// sidebar, keeping that workspace expanded and scrolled into view. The `--window` selector picks the
    /// (OPEN) target, defaulting to the frontmost. Drives `AppActions.collapseOtherWorkspaces(in:)`.
    /// Graceful no-op in flagged mode; idempotent; a named-but-closed window errors, and no open window
    /// at all errors.
    func collapseWorkspaces(window: String?) -> ControlResponse {
        if trimmed(window) == nil, library.activeStore == nil {
            return ControlResponse(ok: false, error: "no open window")
        }
        return resolver.resolvePlacementStore(window) { store in
            actions.collapseOtherWorkspaces(in: store)
            return ControlResponse(ok: true)
        }
    }
}
