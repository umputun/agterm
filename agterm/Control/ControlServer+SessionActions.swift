import Foundation
import agtermCore

/// `ControlServer`'s target-bearing action arms; the app-global ones (tree, sidebar, keymap/config reload,
/// theme, quick terminal) are in `ControlServer+AppCommands.swift`, split for the swiftlint size limit.
/// Target-dependent parsing stays here; dispatcher-routed ones parse in agtermCore, keeping response order.
extension ControlServer: ControlActions {
    func typeSession(_ target: String?, window: String?, options: ControlSessionTypeOptions) async -> ControlResponse {
        // resolve first (cross-window without `args.window`), then realize-and-inject: the async
        // bounded-poll realize rules out the synchronous `resolveSession`. Error strings must match `resolve(...)`.
        switch resolver.resolveSessionTarget(target, window: window) {
        case .failure(let response):
            return response
        case .success(let (store, id)):
            return await injectText(options.text, into: id, store: store, select: options.select,
                                    pane: options.pane)
        }
    }

    func copySessionSelection(_ target: String?, window: String?) -> ControlResponse {
        copySelection(target, window: window)
    }

    /// `options.pane` picks the kind: nil opens the session-wide overlay, `left`/`right` a pane-scoped one
    /// covering that pane alone. The pane arm's two rejections need the LIVE session (its own slot occupied,
    /// or the pane not laid out at all, which would leave the slot active with no surface ever created), so
    /// they sit here rather than in the dispatcher.
    func openSessionOverlay(_ target: String?, window: String?,
                            options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            if let pane = options.pane {
                if let failure = store.openPaneOverlay(id, pane: pane, command: options.command,
                                                       cwd: options.cwd, wait: options.wait,
                                                       backgroundColor: options.backgroundColor) {
                    return paneOverlayFailure(failure, target: target)
                }
            } else {
                guard store.openOverlay(id, command: options.command, cwd: options.cwd,
                                        wait: options.wait, sizePercent: options.sizePercent,
                                        backgroundColor: options.backgroundColor) else {
                    return ControlResponse(ok: false, error: "overlay already open")
                }
            }
            // both overlay kinds run in the per-session eager deck whatever is active, so opening never
            // needs an implicit select — this is `--follow`, a no-op when the target is already active.
            if options.follow {
                store.selectSession(id)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    private func paneOverlayFailure(_ failure: PaneOverlayOpenFailure, target: String?) -> ControlResponse {
        switch failure {
        case .unknownSession: return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
        case .alreadyOpen: return ControlResponse(ok: false, error: PaneOverlayError.alreadyOpen)
        case .paneNotVisible: return ControlResponse(ok: false, error: PaneOverlayError.paneNotVisible)
        }
    }

    /// Closes a HUD too, as a courtesy: the slot is shared, so `closeOverlay` tears either occupant down and
    /// discards the HUD state and its body file with it.
    func closeSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            let closed = pane.map { store.closePaneOverlay(id, pane: $0) } ?? store.closeOverlay(id)
            guard closed else {
                return ControlResponse(ok: false, error: "no overlay")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// A HUD resizes through the same slot and field as any floating panel, but never to FULL, which would
    /// make the message cover the session it is about. The percent reaches its WIDTH only — its height stays
    /// measured from the message, and the text wraps at `HudLayout.maxColumns` rather than at the panel, so
    /// a resize cannot change how many rows it needs. A resized HUD also gets its body rewritten: the helper
    /// centers on the grid in that file's header, so a new panel with the old header would paint the message
    /// off-center until the next `session.hud.update`. A refused rewrite puts the size back rather than
    /// leave the two disagreeing.
    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            let session = store.session(withID: id)
            let hud = session?.hudActive == true
            if sizePercent == nil, hud {
                return ControlResponse(ok: false, error: OverlayHudError.fullResize)
            }
            let previousSize = session?.overlaySizePercent
            guard store.resizeOverlay(id, sizePercent: sizePercent) else {
                return ControlResponse(ok: false, error: "no overlay")
            }
            if hud, let session, !self.writeHudBody(session, pane: self.paneMetrics(for: session)) {
                store.resizeOverlay(id, sizePercent: previousSize)
                return ControlResponse(ok: false, error: OverlayHudError.writeFailed)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func sessionOverlayResult(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            // the app's painter is not the caller's program: without this the shared slot would answer
            // "overlay still running" for a HUD that will never report a status.
            if pane == nil, session.hudActive {
                return ControlResponse(ok: false, error: OverlayHudError.noResult)
            }
            let (running, exitCode) = pane.map { (session.paneOverlay($0) != nil, session.paneOverlayExitCode($0)) }
                ?? (session.overlayActive, session.overlayExitCode)
            if running {
                return ControlResponse(ok: false, error: OverlayResultError.stillRunning)
            }
            guard let code = exitCode else {
                return ControlResponse(ok: false, error: OverlayResultError.noResult)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, exitCode: code))
        }
    }

    /// Destination addressing is mutually exclusive: `workspace` (id / unique prefix / `active`, the
    /// default) or `workspaceName` (the sidebar label) plus optional `createWorkspace` — create needs a
    /// name, there is nothing to create by id. cwd/command/name are applied in `makeSessionResponse`.
    func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse {
        resolver.resolvePlacementStore(options.window) { store in
            // anchor-relative placement: the anchor names its own workspace, bypassing `--workspace`/
            // `--workspace-name`. `before` takes the anchor's slot, `after` the next (clamped in `addSession`).
            if let anchor = options.after ?? options.before {
                let placeBefore = options.before != nil
                return resolveAnchorLocation(anchor, in: store) { location in
                    let index = placeBefore ? location.index : location.index + 1
                    return makeSessionResponse(in: store, workspaceID: location.workspace, options: options, at: index)
                }
            }
            // name addressing: reuse-or-create with `createWorkspace`, else require an existing match.
            if let name = options.workspaceName {
                // a blank name can neither be found nor created (--create-workspace rejects it too).
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ControlResponse(ok: false, error: "workspace name must not be blank")
                }
                // --no-select must not widen the focus set via addWorkspace's auto-reveal.
                let workspace = options.createWorkspace == true
                    ? store.ensureWorkspace(named: name, revealNewWorkspace: !options.noSelect)
                    : store.workspace(named: name)
                guard let workspace else {
                    return ControlResponse(ok: false, error: "no workspace named \"\(name)\" (pass --create-workspace to add it)")
                }
                return makeSessionResponse(in: store, workspaceID: workspace.id, options: options)
            }
            // id addressing (default `active`): the canonical prefix/active resolver.
            let target = options.workspace ?? "active"
            return resolver.resolve(target, candidates: store.workspaces.map(\.id),
                           active: store.currentWorkspaceID, noun: "workspace") { workspaceID in
                makeSessionResponse(in: store, workspaceID: workspaceID, options: options)
            }
        }
    }

    /// Resolve an `--after`/`--before` anchor across all workspaces (so it names its own destination) and
    /// hand its `(workspace, index, count)` to `body`. Unresolved/ambiguous yields the shared resolver
    /// error; the location guard is defense-in-depth — the id came from the store's own list.
    private func resolveAnchorLocation(_ anchor: String, in store: AppStore,
                                       _ body: ((workspace: UUID, index: Int, count: Int)) -> ControlResponse) -> ControlResponse {
        resolver.resolve(anchor, candidates: store.workspaces.flatMap { $0.sessions.map(\.id) },
                       active: store.selectedSessionID, noun: "session") { anchorID in
            guard let location = store.sessionLocation(ofSession: anchorID) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            return body(location)
        }
    }

    /// The control half of the sidebar row's "Duplicate": a fresh shell in the target's directory, inserted
    /// right after it in its own workspace, focused when it lands in the frontmost window. Read-back is
    /// `tree`; the duplicate's cwd is the source's FOCUSED pane, so it differs from the source node's
    /// (primary) `tree.cwd` when the source is a split focused off its primary.
    func duplicateSession(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.duplicateSession(id) else {
                return ControlResponse(ok: false, error: "could not duplicate session")
            }
            if store === library.activeStore { actions.focusActiveSession() }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    func selectSession(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            store.selectSession(id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func goSession(window: String?, direction: SessionNavigation) -> ControlResponse {
        // relative nav acts on the store's current selection: no session target, just the frontmost/`--window` store.
        resolver.resolvePlacementStore(window) { store in
            store.navigateSession(direction)
            guard let id = store.selectedSessionID else {
                return ControlResponse(ok: false, error: "no session to navigate")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func closeSession(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            store.closeSession(id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func closeSessions(_ targets: [String], window: String?) -> ControlResponse {
        resolveBatchSessions(targets, window: window) { store, ids in
            guard ids.count > 1 else {
                guard let id = ids.first else { return ControlResponse(ok: false, error: "session.close requires at least one --target") }
                store.closeSession(id)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
            let affected: Int
            if settingsModel.settings.closeGraceUndoEnabled ?? true {
                // one grouped grace record is the batch behavior scripts cannot reproduce by looping.
                affected = store.softCloseSessions(ids) ? ids.count : 0
            } else {
                // match the GUI's immediate batch-close path when grace undo is disabled.
                affected = ids.reduce(into: 0) { count, id in
                    guard store.session(withID: id) != nil else { return }
                    store.closeSession(id)
                    count += 1
                }
            }
            // `ok` with the count (0 included) mirrors `placeSessions` — every id resolved, so no error arm.
            return ControlResponse(ok: true, result: ControlResult(affected: affected))
        }
    }

    func renameSession(_ target: String?, window: String?, name: String) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            store.renameSession(id, to: name)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func revealSession(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard actions.revealSessionInFinder(id, in: store) else {
                return ControlResponse(ok: false, error: "session cwd is not an existing directory")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Compatibility entry point. An omitted axis preserves an existing split's axis and defaults a new
    /// split to left/right.
    func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        splitSession(target, window: window, mode: mode, axis: nil)
    }

    /// Drive the split on the target's own store. An explicit axis creates or transposes; `nil` preserves
    /// the current axis. `on|off|toggle` is computed against `isSplit` and keeps a hidden pane alive;
    /// `session.split.close` is the teardown verb.
    func splitSession(_ target: String?, window: String?, mode: String?, axis: SplitAxis?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard let parsedMode = ControlToggleMode.parse(mode) else {
                return ControlResponse(ok: false, error: "invalid split mode: \(mode ?? "toggle")")
            }
            switch parsedMode {
            case .on:
                store.setSplitVisibility(id, shown: true, axis: axis)
            case .off:
                store.setSplitVisibility(id, shown: false)
            case .toggle:
                store.toggleSplit(id, axis: axis)
            }
            actions.focusSplitPane(session, wantSplit: session.splitFocused)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Tear the target's split pane down, which `session.split off` cannot: it hides and keeps the shell.
    /// Kills whatever the pane runs, the point of it — `session.type $'exit\n'` reaches only a shell at a
    /// prompt. Idempotent: no right pane answers ok, so a script need not read `tree` first.
    func closeSessionSplit(_ target: String?, window: String?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard session.hasSplit else {
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
            store.closeSplit(id)
            actions.focusSplitPane(session, wantSplit: false)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve the control target, then delegate every swap side effect to the AppActions operation the GUI
    /// twin also uses.
    func swapSessionPanes(_ target: String?, window: String?) async -> ControlResponse {
        switch resolver.resolveSessionTarget(target, window: window) {
        case .failure(let response): return response
        case .success(let (store, id)): return await actions.swapSessionPanes(id, in: store)
        }
    }

    /// Show/hide the target's scratch terminal, a third full-overlay shell. `on|off|toggle` is computed
    /// against `scratchActive`, so both are idempotent; hiding keeps the shell alive, the `closeScratch`
    /// teardown being reserved for the shell's own `exit`. `command` (only when showing) runs that program
    /// instead of a login shell, run-once: a live scratch is torn down and respawned with it, else inert.
    func scratchSession(_ target: String?, window: String?, mode: String?,
                        command: String?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard let parsedMode = ControlToggleMode.parse(mode) else {
                return ControlResponse(ok: false, error: "invalid scratch mode: \(mode ?? "toggle")")
            }
            let want = parsedMode.desiredValue(current: session.scratchActive)
            if want, let command, !command.isEmpty {
                // closeScratch clears scratchActive, so the toggle below re-shows it and the factory uses it.
                if session.scratchSurface != nil { store.closeScratch(id) }
                session.scratchCommand = command
            }
            if want, store.selectedSessionID != id {
                // the scratch is full-coverage and grabs focus on show, so select the target first — unlike
                // the overlay (eager deck, no select), a non-active scratch would steal focus while hidden.
                store.selectSession(id)
            }
            if want != session.scratchActive {
                store.toggleScratch(id)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Move keyboard focus to a split session's pane: `pane` is `left`|`right`|`other` (`other` toggles).
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

    /// Resize a split's divider (control-native — the GUI only drags it, or double-clicks it for an even
    /// split). `ratio` is an absolute primary-pane
    /// fraction, `delta` a signed nudge (positive grows the primary pane) on the current fraction (0.5 when
    /// never moved); exactly one must be set. `applySplitRatio` clamps + persists, then
    /// `.agtermApplySplitRatio` pokes the session's `SplitProbeView` to move the live divider — a no-op
    /// while the split is hidden, where the stored value applies on next show. Errors without a split, and
    /// echoes the clamped fraction in `result.ratio`.
    func resizeSplit(_ target: String?, window: String?, resize: ControlSplitResize) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard session.hasSplit else {
                return ControlResponse(ok: false, error: "session has no split")
            }
            let requested: Double
            switch resize {
            case .ratio(let ratio):
                requested = ratio
            case .delta(let delta):
                requested = (session.splitRatio ?? AppStore.splitRatioDefault) + delta
            }
            guard let applied = store.applySplitRatio(requested, forSession: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            NotificationCenter.default.post(name: .agtermApplySplitRatio, object: session)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, ratio: applied))
        }
    }

    /// Set the target's agent-status indicator (control-native). `status` is `idle|active|completed|blocked`,
    /// else a structured `invalid status` error; `blink` (default false) pulses the glyph, `autoReset`
    /// (default false) clears to idle once the session is visited. A non-empty `sound` plays once on apply
    /// (`default`/`beep` = system alert, else a named system sound), validated up-front so an unknown name
    /// errors `unknown sound` leaving the status unchanged; empty counts as none, and with none given a
    /// TRANSITION into `blocked` plays the Settings "Blocked sound" (`blockedStatusSoundName`).
    /// `update.color` (`#rrggbb` glyph tint) and `update.shape` (silhouette) are dispatcher-validated and
    /// ride the EPHEMERAL indicator, lasting only until the next `session.status` without them.
    /// `update.pane` (`StatusPane`, dispatcher-validated, nil = `left`/main) records the pane that set the
    /// status, driving the pane-scoped keystroke-clear and pane-aware reveal. Renders on every non-idle one.
    func setSessionStatus(_ target: String?, window: String?, update: ControlSessionStatusUpdate) -> ControlResponse {
        // validated before any mutation; an empty value counts as none, matching `AgentStatus.effectiveSound`.
        if let sound = update.sound, !sound.isEmpty, StatusSoundPlayer.shared.action(for: sound) == nil {
            let hint = StatusSoundPlayer.standardNames.joined(separator: ", ")
            return ControlResponse(ok: false, error: "unknown sound: \(sound) (use 'default', 'beep', or one of: \(hint))")
        }
        return resolver.resolveSession(target, window: window) { store, id in
            let session = store.session(withID: id)
            // capture the status BEFORE mutating so the Settings default plays only on a real transition.
            let wasBlocked = session?.agentIndicator.status == .blocked
            // `--pane-id` resolves against the LIVE surfaces and overrides the stale role `--pane`, so a
            // promoted-then-re-split pane lands on its CURRENT slot (#199); absent/unknown falls back to it.
            let resolvedPane = update.paneID.flatMap { session?.paneRole(forToken: $0) } ?? update.pane
            store.setAgentIndicator(AgentIndicator(status: update.status, blink: update.blink ?? false,
                                                   autoReset: update.autoReset ?? false,
                                                   color: update.color, shape: update.shape,
                                                   statusPane: resolvedPane), forSession: id)
            // per-call sound wins on any status; the Settings default plays only on a NEW entry into `blocked`.
            let blockedDefault = wasBlocked ? nil : self.settingsModel.settings.blockedStatusSoundName
            if let name = update.status.effectiveSound(perCall: update.sound, blockedDefault: blockedDefault) {
                StatusSoundPlayer.shared.play(name)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Pin (or unpin) the target pane's restore-command override — the per-pane shell line that wins over
    /// the captured foreground on the NEXT launch. Only the PERSISTED field is touched, so nothing runs in
    /// the current session. `update.pin` is tri-state (`pin(cmd)` → the line, `pinNone` → `""` = a plain
    /// shell, `unpin` → nil = back to auto-capture), saved immediately so a hook's write survives a
    /// force-quit. That save is the ONE store write whose failure is reported rather than swallowed —
    /// acking a `clear` that never reached disk would leave the old command firing on every launch — so the
    /// arm answers `ok: false`, the rolled-back value still in effect.
    ///
    /// The pane resolves like `setSessionStatus` (`update.paneID` against the LIVE surfaces first, then the
    /// baked role `update.pane`, defaulting to main) with ONE divergence: an unresolvable `--pane-id`
    /// WITHOUT an explicit `--pane` is an ERROR here, since a bad fallback would overwrite the MAIN pane's
    /// persisted command when a hook meant the split (a status only puts a glyph on the wrong row).
    /// `.scratch` and a `.right` without a split are rejected too. `set` and `none` outside rerun mode still
    /// save policy and return a note naming the active mode; either clear form remains mode-independent.
    func setSessionRestore(_ target: String?, window: String?,
                           update: ControlSessionRestoreUpdate) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            let pane: StatusPane
            // an EMPTY token (an older shell exporting no `AGTERM_PANE_ID`) counts as absent: the plain
            // `--pane`/main-pane path, not an error.
            if let token = update.paneID, !token.isEmpty {
                guard let resolved = session.paneRole(forToken: token) ?? update.pane else {
                    return ControlResponse(ok: false, error: "unknown pane id: \(token)")
                }
                pane = resolved
            } else {
                pane = update.pane ?? .left
            }
            guard pane != .scratch else {
                return ControlResponse(ok: false, error: "the scratch terminal is never restored")
            }
            guard pane != .right || session.hasSplit else {
                return ControlResponse(ok: false, error: "session has no split")
            }
            let value: String?
            switch update.pin {
            case .pin(let command): value = command
            case .pinNone: value = ""
            case .unpin: value = nil
            }
            guard store.setRestoreCommand(value, pane: pane, forSession: id) else {
                return ControlResponse(ok: false,
                                       error: "failed to save the restore override, the previous value is still in effect")
            }
            var result = ControlResult(id: id.uuidString, pane: pane.rawValue)
            if update.pin != .unpin, self.launchRestoreMode != .rerun {
                result.text = "saved for rerun mode; active restore mode is \(self.launchRestoreMode.rawValue)"
            }
            return ControlResponse(ok: true, result: result)
        }
    }

    /// Flag/unflag the target for the flagged working-set view (the durable `Session.flagged` the flat
    /// sidebar mode projects). `on|off|toggle` is computed against `flagged`, so both are idempotent;
    /// `clear` ignores the target, unflags every session in the resolved store, and reports ok with no id.
    func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse {
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

    /// Set or clear a session's title-bar context. The value is already trimmed and validated by the
    /// dispatcher, so nil here means clear rather than "nothing supplied".
    func setSessionContext(_ target: String?, window: String?, context: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard store.session(withID: id) != nil else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            store.setContext(context, forSession: id) // no-op, no save and no event when unchanged
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Clear a session's unseen-notification badge without touching selection, focus, or agent status — the
    /// counterpart to `notify`, whose badge nothing else lowers without visiting. Idempotent, and the count
    /// is ephemeral so it triggers no save.
    func markSessionSeen(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            store.clearUnseen(id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Mode-bearing `session.move`: `to` (`up`|`down`|`top`|`bottom`) reorders within the session's own
    /// workspace, `workspace` relocates to another one (appending), `place` relocates + positions against an
    /// anchor session (which carries its own workspace). Exactly one form, enforced in the dispatcher.
    func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse {
        switch move {
        case .reorder(let dir):
            return resolver.resolveSession(target, window: window) { store, id in
                store.reorderSession(id, dir)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .workspace(let workspace):
            // both must live in the same store: resolve the session first (fixing it), then the workspace.
            return resolver.resolveSession(target, window: window) { store, sessionID in
                resolver.resolve(workspace, candidates: store.workspaces.map(\.id),
                        active: store.currentWorkspaceID, noun: "workspace") { workspaceID in
                    store.moveSession(sessionID, toWorkspace: workspaceID)
                    return ControlResponse(ok: true, result: ControlResult(id: sessionID.uuidString))
                }
            }
        case .place(let anchor, let after):
            return placeSession(target, window: window, anchor: anchor, after: after)
        }
    }

    func moveSessions(_ targets: [String], window: String?, move: ControlSessionMove) -> ControlResponse {
        switch move {
        case .reorder:
            return ControlResponse(ok: false, error: "session.move --target can be repeated only with a workspace or --after/--before")
        case .workspace(let workspace):
            return resolveBatchSessions(targets, window: window) { store, ids in
                resolver.resolve(workspace, candidates: store.workspaces.map(\.id),
                        active: store.currentWorkspaceID, noun: "workspace") { workspaceID in
                    let affected = store.moveSessions(ids, toWorkspace: workspaceID)
                    return ControlResponse(ok: true, result: ControlResult(affected: affected))
                }
            }
        case .place(let anchor, let after):
            return placeSessions(targets, window: window, anchor: anchor, after: after)
        }
    }

    /// Resolve the moved session and its anchor in one store, then relocate + position via the host-free
    /// `SidebarDrop.resolveRelative` math. A nil resolution (anchor==self, already in place) is a no-op.
    private func placeSession(_ target: String?, window: String?, anchor: String, after: Bool) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, sessionID in
            guard let source = store.sessionLocation(ofSession: sessionID) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            return resolveAnchorLocation(anchor, in: store) { anchorLoc in
                if let resolution = SidebarDrop.resolveRelative(
                    source: (workspace: source.workspace, index: source.index),
                    anchor: (workspace: anchorLoc.workspace, index: anchorLoc.index, count: anchorLoc.count),
                    placeAfter: after) {
                    store.moveSession(sessionID, toWorkspace: resolution.workspace, at: resolution.destination)
                }
                return ControlResponse(ok: true, result: ControlResult(id: sessionID.uuidString))
            }
        }
    }

    /// Batch variant of `placeSession`: compute the post-removal insertion slot with the same host-free
    /// drop math as sidebar drag, then move the block with one `AppStore.moveSessions` call.
    private func placeSessions(_ targets: [String], window: String?, anchor: String, after: Bool) -> ControlResponse {
        resolveBatchSessions(targets, window: window) { store, ids in
            let sources = ids.compactMap { id -> SidebarDrop.SessionSource? in
                guard let source = store.sessionLocation(ofSession: id) else { return nil }
                return SidebarDrop.SessionSource(workspace: source.workspace, index: source.index)
            }
            guard sources.count == ids.count else {
                return ControlResponse(ok: false, error: "no such session")
            }
            return resolveAnchorLocation(anchor, in: store) { anchorLoc in
                let target = SidebarDrop.SessionDropTarget.sessionRow(workspace: anchorLoc.workspace,
                                                                      sessionIndex: anchorLoc.index,
                                                                      sessionCount: anchorLoc.count)
                let affected: Int
                if let resolution = SidebarDrop.resolveSessions(
                    sources: sources,
                    target: target,
                    childIndex: after ? SidebarDrop.onItemIndex : anchorLoc.index
                ) {
                    affected = store.moveSessions(ids, toWorkspace: resolution.workspace,
                                                  at: resolution.destination)
                } else {
                    affected = 0
                }
                return ControlResponse(ok: true, result: ControlResult(affected: affected))
            }
        }
    }

    private func resolveBatchSessions(_ targets: [String], window: String?,
                                      _ body: (AppStore, [UUID]) -> ControlResponse) -> ControlResponse {
        guard let first = targets.first else {
            return ControlResponse(ok: false, error: "session command requires at least one --target")
        }
        switch resolver.resolveSessionTarget(first, window: window) {
        case .failure(let response):
            return response
        case .success(let (store, firstID)):
            var ids: [UUID] = []
            var seen = Set<UUID>()
            ids.append(firstID)
            seen.insert(firstID)
            let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
            for target in targets.dropFirst() {
                let response = resolver.resolve(target, candidates: candidates,
                                                active: store.selectedSessionID, noun: "session") { id in
                    guard seen.insert(id).inserted else { return ControlResponse(ok: true) }
                    ids.append(id)
                    return ControlResponse(ok: true)
                }
                guard response.ok else { return response }
            }
            return body(store, ids)
        }
    }

    /// Post a desktop notification attributed to a session (default: the frontmost window's active one).
    /// `title` defaults to the session name, `body` is required; errors when no open window owns it.
    ///
    /// With banners off the post still returns `ok` plus a note in `result.text`: the badge still tracks,
    /// but a bare `ok` for a call that posts nothing to the OS is indistinguishable from a broken
    /// notification path (issue #286).
    func sendNotification(_ target: String?, window: String?, title: String?, body: String) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard NotificationManager.shared.send(toSession: session, title: title ?? "", body: body) else {
                return ControlResponse(ok: false, error: "session's window is not open")
            }
            var result = ControlResult(id: id.uuidString)
            if !NotificationManager.shared.bannersEnabled {
                result.text = ControlNotify.bannersOffNote
            }
            return ControlResponse(ok: true, result: result)
        }
    }

    /// Show / hide / toggle zoom for an addressable terminal surface — `surface:<session-id>:<kind>` ids
    /// from `tree`, or the default: the active surface in the frontmost (or `--window`) window.
    func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse {
        let rawTarget = trimmed(target) ?? "active"
        if rawTarget == "active" {
            return setActiveSurfaceZoom(window: window, mode: mode)
        }
        // `quick` names the detached panel, which no window's zoom controller can hold — it fills its own
        // screen instead of a window. It takes no `--window` for the same reason.
        if rawTarget == "quick" {
            guard QuickTerminalController.shared.setZoom(mode) else {
                return ControlResponse(ok: false, error: "surface not available: quick")
            }
            return ControlResponse(ok: true, result: ControlResult(id: "quick"))
        }
        switch resolveSurfaceZoom(rawTarget, window: window) {
        case .failure(let response):
            return response
        case .success(let resolved):
            guard let controller = TerminalZoomRegistry.shared.controller(for: resolved.windowID) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            let want = mode.desiredValue(current: controller.target == resolved.target)
            if want, controller.target != resolved.target,
               PickRegistry.shared.controller(for: resolved.windowID)?.pending != nil {
                return ControlResponse(ok: false, error: "pick pending")
            }
            // `hide` is idempotent: skip the availability check for `.off`, since the surface may have
            // vanished (an exited overlay auto-clears the zoom) while the end state holds; `set(.off, …)`
            // on a non-matching target is a no-op.
            if mode != .off {
                guard TerminalZoomController.isTargetValid(resolved.target, in: resolved.store) else {
                    return ControlResponse(ok: false, error: "surface not available: \(resolved.controlID)")
                }
            }
            controller.set(mode, target: resolved.target)
            return ControlResponse(ok: true, result: ControlResult(id: resolved.controlID))
        }
    }

    private func setActiveSurfaceZoom(window: String?, mode: ControlToggleMode) -> ControlResponse {
        switch resolveOpenWindow(window) {
        case .failure(let response):
            return response
        case .success(let (windowID, store)):
            guard let controller = TerminalZoomRegistry.shared.controller(for: windowID) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            if controller.target == nil, mode != .off,
               PickRegistry.shared.controller(for: windowID)?.pending != nil {
                return ControlResponse(ok: false, error: "pick pending")
            }
            // this arm only picks the effective target (the current zoom when one is up, so on/off/toggle
            // act on it, else the resolved active surface) and shapes the response; mode-vs-state semantics
            // live in host-free `TerminalZoomController.set`, shared with the GUI and explicit-target paths.
            let effectiveTarget: TerminalZoomTarget
            if let current = controller.target {
                effectiveTarget = current
            } else {
                guard mode != .off else {
                    return ControlResponse(ok: true)
                }
                guard let zoomTarget = TerminalZoomController.resolveTarget(store: store) else {
                    return ControlResponse(ok: false, error: "no active surface")
                }
                guard TerminalZoomController.isTargetValid(zoomTarget, in: store) else {
                    return ControlResponse(ok: false, error: "surface not available: \(zoomTarget.controlID)")
                }
                effectiveTarget = zoomTarget
            }
            controller.set(mode, target: effectiveTarget)
            return ControlResponse(ok: true, result: ControlResult(id: effectiveTarget.controlID))
        }
    }

    private struct SurfaceZoomResolution {
        let windowID: WindowInfo.ID
        let store: AppStore
        let target: TerminalZoomTarget
        let controlID: String
    }

    private func resolveSurfaceZoom(_ target: String, window: String?)
        -> ControlTargetResolver.Resolution<SurfaceZoomResolution> {
        // `quick` never arrives here — `setSurfaceZoom` routes it to the panel before resolving a window.
        guard let surfaceID = TerminalSurfaceID(rawValue: target) else {
            return .failure(ControlResponse(ok: false, error: "invalid surface: \(target)"))
        }
        switch resolveSurfaceOwner(surfaceID, window: window) {
        case .failure(let response):
            return .failure(response)
        case .success(let (windowID, store)):
            let zoomTarget = TerminalZoomTarget.session(surfaceID.sessionID, surfaceID.surface)
            return .success(SurfaceZoomResolution(windowID: windowID, store: store,
                                                  target: zoomTarget, controlID: surfaceID.rawValue))
        }
    }

    func resolveOpenWindow(_ window: String?) -> ControlTargetResolver.Resolution<(WindowInfo.ID, AppStore)> {
        guard let window = trimmed(window) else {
            guard let windowID = library.activeWindowID, let store = library.store(for: windowID) else {
                return .failure(ControlResponse(ok: false, error: "no open window"))
            }
            return .success((windowID, store))
        }
        switch resolver.resolveWindowID(window) {
        case .failure(let response):
            return .failure(response)
        case .success(let windowID):
            guard let store = library.store(for: windowID) else {
                return .failure(ControlResponse(ok: false, error: "window not open — window.select it first"))
            }
            return .success((windowID, store))
        }
    }

    func resolveSurfaceOwner(_ surfaceID: TerminalSurfaceID, window: String?)
        -> ControlTargetResolver.Resolution<(WindowInfo.ID, AppStore)> {
        if trimmed(window) != nil {
            switch resolveOpenWindow(window) {
            case .failure(let response):
                return .failure(response)
            case .success(let (windowID, store)):
                guard store.session(withID: surfaceID.sessionID) != nil else {
                    return .failure(ControlResponse(ok: false, error: "no such surface: \(surfaceID.rawValue)"))
                }
                return .success((windowID, store))
            }
        }
        guard let windowID = library.windowID(forSession: surfaceID.sessionID),
              let store = library.store(for: windowID) else {
            return .failure(ControlResponse(ok: false, error: "no such surface: \(surfaceID.rawValue)"))
        }
        return .success((windowID, store))
    }

}
