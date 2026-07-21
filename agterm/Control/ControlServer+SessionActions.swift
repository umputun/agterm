import Foundation
import agtermCore

/// `ControlServer` session/workspace/surface action adapter arms — the target-bearing ones. Dispatcher-routed
/// commands parse in agtermCore when that preserves the old response order; target-dependent parsing stays
/// here with `resolver`. App-owned commands still call nearby helpers. Split out of `ControlServer.swift` to
/// keep that file under the swiftlint size limit; the app-global arms (tree, sidebar, keymap/config reload,
/// theme, quick terminal) live in `ControlServer+AppCommands.swift`.
extension ControlServer: ControlActions {
    func typeSession(_ target: String?, window: String?, options: ControlSessionTypeOptions) async -> ControlResponse {
        // Resolve first (cross-window when no `args.window`), then realize-and-inject; the realize
        // path is async (bounded poll), so this can't go through the synchronous `resolveSession`
        // helper. The not-found / ambiguous error strings must stay in sync with `resolve(...)`.
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

    func openSessionOverlay(_ target: String?, window: String?,
                            options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard store.openOverlay(id, command: options.command, cwd: options.cwd,
                                    wait: options.wait, sizePercent: options.sizePercent,
                                    backgroundColor: options.backgroundColor) else {
                return ControlResponse(ok: false, error: "overlay already open")
            }
            // Both overlay kinds mount and run in the per-session eager deck regardless of which session
            // is active (the floating panel is a constant-shape sibling in `sessionDetail`), so opening
            // never needs an implicit select. The select is now the user-facing `--follow`: the caller
            // asked to jump to the target, so switch to it (a no-op when it's already active).
            if options.follow {
                store.selectSession(id)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func closeSessionOverlay(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard store.closeOverlay(id) else {
                return ControlResponse(ok: false, error: "no overlay")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard store.resizeOverlay(id, sizePercent: sizePercent) else {
                return ControlResponse(ok: false, error: "no overlay")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func sessionOverlayResult(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            if session.overlayActive {
                return ControlResponse(ok: false, error: OverlayResultError.stillRunning)
            }
            guard let code = session.overlayExitCode else {
                return ControlResponse(ok: false, error: OverlayResultError.noResult)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, exitCode: code))
        }
    }

    /// The destination workspace is addressed one of two mutually-exclusive ways: `workspace`
    /// (id / unique prefix / `active`, the default) or `workspaceName` (the sidebar label),
    /// the latter optionally with `createWorkspace` to add it when absent. create needs a name —
    /// there is nothing to create by id. cwd/command/name are applied in makeSessionResponse.
    func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse {
        resolver.resolvePlacementStore(options.window) { store in
            // anchor-relative placement (`--after`/`--before`): the anchor sid names its own workspace,
            // so this bypasses the `--workspace`/`--workspace-name` addressing entirely. `before` inserts
            // at the anchor's slot, `after` just past it (clamped in `AppStore.addSession`).
            if let anchor = options.after ?? options.before {
                let placeBefore = options.before != nil
                return resolveAnchorLocation(anchor, in: store) { location in
                    let index = placeBefore ? location.index : location.index + 1
                    return makeSessionResponse(in: store, workspaceID: location.workspace, options: options, at: index)
                }
            }
            // name addressing: reuse-or-create with `createWorkspace`, else require an existing match.
            if let name = options.workspaceName {
                // a blank name can neither be found NOR created — report that directly rather than
                // suggesting --create-workspace (which would also reject a blank name).
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ControlResponse(ok: false, error: "workspace name must not be blank")
                }
                // a --no-select create must not clear the workspace-focus filter (addWorkspace's auto-reveal),
                // so the background create leaves the current view untouched like the rest of --no-select.
                let workspace = options.createWorkspace == true
                    ? store.ensureWorkspace(named: name, clearFocus: !options.noSelect)
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

    /// Resolve an anchor session address (`--after`/`--before`) across the store's whole session set (all
    /// workspaces, so the anchor names its own destination workspace) and hand its `(workspace, index,
    /// count)` location to `body`. An unresolved or ambiguous anchor yields the shared resolver error; the
    /// location guard is defense-in-depth (the id came from the store's own list, so it always resolves).
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
    /// right after it in its own workspace. Takes no options — the target names both the workspace and the
    /// cwd — and, like `session.new`, focuses the duplicate when it lands in the frontmost window and returns
    /// its id. The read-back is `tree`: the new session appears after its source, carrying the source's
    /// focused-pane cwd — equal to the source node's `tree.cwd` unless the source is a split focused off its
    /// primary pane (then `tree.cwd` reports the primary and the two differ).
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
        // relative navigation acts on the store's current selection, so no session target -- just
        // the frontmost-or-`--window` store.
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
                // One grouped grace record is the batch behavior scripts cannot reproduce by looping.
                affected = store.softCloseSessions(ids) ? ids.count : 0
            } else {
                // Match the GUI's immediate batch-close path when grace undo is disabled.
                affected = ids.reduce(into: 0) { count, id in
                    guard store.session(withID: id) != nil else { return }
                    store.closeSession(id)
                    count += 1
                }
            }
            // `ok` with the count (0 included) mirrors `placeSessions` — every id already resolved, so
            // an error arm here would be dead code.
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
                // run the command as the scratch process: respawn if one is already alive (a scratch is
                // expendable), so the command is never silently ignored. closeScratch clears scratchActive,
                // so the toggle below re-shows it and the factory consumes scratchCommand.
                if session.scratchSurface != nil { store.closeScratch(id) }
                session.scratchCommand = command
            }
            if want, store.selectedSessionID != id {
                // the scratch is a full-coverage surface that grabs focus on show; it only makes sense on
                // the visible session, so select the target first. Unlike the overlay (which runs in the
                // eager deck without selecting), the scratch must be on the active session -- otherwise a
                // non-active target's scratch surface would steal first responder while hidden.
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

    /// Set the target session's agent-status indicator (control-native: no GUI/menu equivalent, like
    /// `notify`/`session.type`/`session.copy`). `status` is `idle|active|completed|blocked`; an unknown
    /// value is the structured `invalid status` error. `blink` (default false) pulses the glyph;
    /// `autoReset` (default false) clears the indicator to idle once the session is visited. `sound`, when
    /// non-empty, plays a one-shot sound once the status is applied (`default`/`beep` = system alert, any
    /// other value = named system sound); it is validated up-front so an unknown name is an `unknown sound`
    /// error that leaves the status unchanged (an empty value is treated as no per-call sound). When no
    /// per-call `sound` is given and the session TRANSITIONS into `blocked`, the user's configured Settings
    /// "Blocked sound" (`blockedStatusSoundName`) plays as a best-effort default. `update.color`, when set,
    /// is a `#rrggbb` glyph-tint override (hex-validated in the dispatcher) that rides the ephemeral
    /// indicator, so it lasts only until the next `session.status` without a color. `update.pane`
    /// (`StatusPane`, validated in the dispatcher) is threaded onto the indicator's `statusPane` — the pane
    /// that set the status — driving the pane-scoped keystroke-clear and the pane-aware attention reveal;
    /// nil is treated as `left`/main. The indicator is ephemeral and rendered on every non-idle session.
    func setSessionStatus(_ target: String?, window: String?, update: ControlSessionStatusUpdate) -> ControlResponse {
        // an explicit per-call sound is validated up-front: an unknown name errors without changing status.
        // an empty value is treated as no per-call sound, matching `AgentStatus.effectiveSound`.
        if let sound = update.sound, !sound.isEmpty, StatusSoundPlayer.shared.action(for: sound) == nil {
            let hint = StatusSoundPlayer.standardNames.joined(separator: ", ")
            return ControlResponse(ok: false, error: "unknown sound: \(sound) (use 'default', 'beep', or one of: \(hint))")
        }
        return resolver.resolveSession(target, window: window) { store, id in
            let session = store.session(withID: id)
            // capture the status BEFORE mutating so the Settings default plays only on a real transition.
            let wasBlocked = session?.agentIndicator.status == .blocked
            // a `--pane-id` that resolves against the session's LIVE surfaces overrides the stale role
            // `--pane`, so a status set from a promoted-then-re-split pane lands on the pane's CURRENT slot
            // (#199); an absent/unknown token falls back to the baked `--pane` (the pre-token behavior).
            let resolvedPane = update.paneID.flatMap { session?.paneRole(forToken: $0) } ?? update.pane
            store.setAgentIndicator(AgentIndicator(status: update.status, blink: update.blink ?? false,
                                                   autoReset: update.autoReset ?? false,
                                                   color: update.color, statusPane: resolvedPane), forSession: id)
            // explicit per-call sound wins on any status; the Settings default plays only when a session
            // newly enters `blocked`, not on a repeated `blocked` set.
            let blockedDefault = wasBlocked ? nil : self.settingsModel.settings.blockedStatusSoundName
            if let name = update.status.effectiveSound(perCall: update.sound, blockedDefault: blockedDefault) {
                StatusSoundPlayer.shared.play(name)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Pin (or unpin) the target pane's restore-command override — the per-pane shell line that wins over
    /// the captured foreground on the NEXT launch. Write-now, consume-next-launch: it touches only the
    /// PERSISTED field, so nothing runs in the current session. `update.pin` maps to the tri-state stored
    /// value (`pin(cmd)` → the line, `pinNone` → `""` = a plain shell, `unpin` → nil = back to
    /// auto-capture) and `AppStore.setRestoreCommand` saves immediately, so a hook's write survives a
    /// force-quit. That save is the ONE store write whose failure is reported rather than swallowed: the
    /// arm answers `ok: false` when it did not land, since acking a `clear` that never reached disk would
    /// leave the old command firing on every launch. The rolled-back value is still in effect, so the
    /// caller retries the same request.
    ///
    /// The pane resolves like `setSessionStatus` — `update.paneID` against the session's LIVE surfaces
    /// first, then the baked role `update.pane`, defaulting to the main pane — with ONE deliberate
    /// divergence: an unresolvable `--pane-id` supplied WITHOUT an explicit `--pane` is an ERROR here. For
    /// a status a bad fallback costs a glyph on the wrong row; here it would overwrite the MAIN pane's
    /// persisted restore command when a hook meant the split. `.scratch` and a `.right` without a split are
    /// rejected too. A `set` while the restore-running-command setting is off still succeeds, with a note
    /// in `result.text` so a hook author can see why nothing will fire; `none` and `clear` get no note —
    /// their outcome (a plain shell / back to auto-capture) is delivered regardless of the setting.
    func setSessionRestore(_ target: String?, window: String?,
                           update: ControlSessionRestoreUpdate) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            let pane: StatusPane
            // an EMPTY token counts as absent (an older shell exporting no `AGTERM_PANE_ID`), so it takes
            // the plain `--pane`/main-pane path rather than erroring.
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
            var result = ControlResult(id: id.uuidString)
            if case .pin = update.pin, self.settingsModel.settings.restoreRunningCommand != true {
                result.text = "saved, but \"Restore running commands on restart\" is off, so the override will not run"
            }
            return ControlResponse(ok: true, result: result)
        }
    }

    /// Flag/unflag the target session for the flagged working-set view (the durable `Session.flagged`
    /// membership the flat sidebar mode projects). `mode` is `on|off|toggle|clear`, computed against the
    /// session's current `flagged` so `on`/`off` are idempotent. `clear` ignores the target and unflags
    /// every session in the resolved store (frontmost or `--window`), via `AppStore.clearFlags()` — it
    /// reports ok with no id. An unknown mode is an error.
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

    /// Clears a session's unseen-notification badge without changing the selection, focus, or agent
    /// status — the focus-free counterpart to `notify`, which raises the badge over the socket but
    /// which nothing could lower without visiting the session. Idempotent (a no-op when already zero,
    /// since `clearUnseen` just assigns 0; the count is ephemeral so it triggers no save).
    func markSessionSeen(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            store.clearUnseen(id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Mode-bearing `session.move`: `to` reorders the session within its own workspace
    /// (`up`|`down`|`top`|`bottom`), `workspace` relocates it to another workspace (appending), `place`
    /// relocates + positions relative to an anchor session (the anchor carries its own workspace). Exactly
    /// one form is required (enforced in the dispatcher). An invalid `to` direction errors.
    func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse {
        switch move {
        case .reorder(let dir):
            return resolver.resolveSession(target, window: window) { store, id in
                store.reorderSession(id, dir)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .workspace(let workspace):
            // the session and the destination workspace must live in the same store: resolve the
            // session first (which fixes the store), then the workspace within that same store.
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

    /// Resolve the moved session and its anchor within the same store, then relocate + position via the
    /// host-free `SidebarDrop.resolveRelative` drop math. The anchor is resolved across the whole store
    /// (all workspaces), so it self-identifies the destination workspace. A nil resolution (anchor==self
    /// or an already-in-place move) is a successful no-op.
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

    /// Batch variant of `placeSession`: resolve every moved session in one store, compute the
    /// post-removal insertion slot with the same host-free drop math as sidebar drag, then move the block
    /// with a single `AppStore.moveSessions` call.
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

    /// Post a desktop notification attributed to a session (default: the active session of the
    /// frontmost window, via `resolveSession`). `title` defaults to the session name; `body` is
    /// required. Errors when no open window owns the resolved session.
    func sendNotification(_ target: String?, window: String?, title: String?, body: String) -> ControlResponse {
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

    /// Show / hide / toggle zoom for an addressable terminal surface. The default target is the active
    /// surface in the frontmost (or `--window`) window; explicit targets are `surface:<session-id>:<kind>`
    /// ids copied from `tree`.
    func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse {
        let rawTarget = trimmed(target) ?? "active"
        if rawTarget == "active" {
            return setActiveSurfaceZoom(window: window, mode: mode)
        }
        switch resolveSurfaceZoom(rawTarget, window: window) {
        case .failure(let response):
            return response
        case .success(let resolved):
            guard let controller = TerminalZoomRegistry.shared.controller(for: resolved.windowID) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            // `hide` is idempotent like the active-target arm: skip the availability check for `.off` —
            // the surface may have vanished since (an overlay exited, auto-clearing the zoom) and the
            // desired end state already holds; `set(.off, …)` on a non-matching target is a no-op.
            if mode != .off {
                guard TerminalZoomController.isTargetValid(resolved.target, in: resolved.store,
                                                           quickTerminalVisible: quickVisible(in: resolved.windowID)) else {
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
            // this arm only picks the effective target — the current zoom when one is up (so
            // on/off/toggle act on it), else the resolved active surface — and shapes the response;
            // the mode-vs-state semantics live in the one host-free state machine,
            // `TerminalZoomController.set`, shared with the GUI toggle and the explicit-target path.
            let effectiveTarget: TerminalZoomTarget
            if let current = controller.target {
                effectiveTarget = current
            } else {
                guard mode != .off else {
                    return ControlResponse(ok: true)
                }
                let quickVisible = quickVisible(in: windowID)
                guard let zoomTarget = TerminalZoomController.resolveTarget(store: store,
                                                                            quickTerminalVisible: quickVisible) else {
                    return ControlResponse(ok: false, error: "no active surface")
                }
                guard TerminalZoomController.isTargetValid(zoomTarget, in: store, quickTerminalVisible: quickVisible) else {
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
        // `quick` is the control id this command itself returns for a quick-terminal zoom — accept it
        // back as an explicit target (the API must accept every address it emits). Validity (the quick
        // terminal actually visible) is checked by the caller's shared `isTargetValid` gate.
        if target == "quick" {
            switch resolveOpenWindow(window) {
            case .failure(let response):
                return .failure(response)
            case .success(let (windowID, store)):
                return .success(SurfaceZoomResolution(windowID: windowID, store: store,
                                                      target: .quick, controlID: "quick"))
            }
        }
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

    private func resolveOpenWindow(_ window: String?) -> ControlTargetResolver.Resolution<(WindowInfo.ID, AppStore)> {
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

    private func resolveSurfaceOwner(_ surfaceID: TerminalSurfaceID, window: String?)
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

    private func quickVisible(in windowID: WindowInfo.ID) -> Bool {
        QuickTerminalRegistry.shared.controller(for: windowID)?.isVisible ?? false
    }
}
