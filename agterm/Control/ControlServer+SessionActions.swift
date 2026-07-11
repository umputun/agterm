import Foundation
import agtermCore

/// `ControlServer` session/workspace/sidebar action adapter arms. Dispatcher-routed commands parse in
/// agtermCore when that preserves the old response order; target-dependent parsing stays here with
/// `resolver`. App-owned commands still call nearby helpers. Split out of `ControlServer.swift` to keep
/// that file under the swiftlint size limit.
extension ControlServer: ControlActions {
    func controlTree(window: String?) -> ControlResponse {
        resolver.resolvePlacementStore(window) { store in
            ControlResponse(ok: true, result: ControlResult(tree: buildTree(in: store)))
        }
    }

    func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse {
        setSidebar(mode: mode)
    }

    func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse {
        setSidebarViewMode(mode: mode)
    }

    func expandSidebar(window: String?) -> ControlResponse {
        expandWorkspaces(window: window)
    }

    func collapseSidebar(window: String?) -> ControlResponse {
        collapseWorkspaces(window: window)
    }

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
                let workspace = options.createWorkspace == true
                    ? store.ensureWorkspace(named: name)
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

    func createWorkspace(window: String?, name: String?) -> ControlResponse {
        // placement target: the window's frontmost store (or `args.window`'s). name defaults to
        // the auto-generated workspace name when none is given.
        resolver.resolvePlacementStore(window) { store in
            let name = trimmed(name) ?? store.defaultWorkspaceName
            let workspace = store.addWorkspace(name: name)
            return ControlResponse(ok: true, result: ControlResult(id: workspace.id.uuidString))
        }
    }

    func selectWorkspace(_ target: String?, window: String?) -> ControlResponse {
        // selecting a workspace selects its first session (workspace rows are not selectable on
        // their own); an empty workspace just clears nothing and reports the workspace id.
        resolver.resolveWorkspace(target, window: window) { store, id in
            if let first = store.workspaces.first(where: { $0.id == id })?.sessions.first {
                store.selectSession(first.id)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func renameWorkspace(_ target: String?, window: String?, name: String) -> ControlResponse {
        resolver.resolveWorkspace(target, window: window) { store, id in
            store.renameWorkspace(id, to: name)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func deleteWorkspace(_ target: String?, window: String?) -> ControlResponse {
        // honors keep-at-least-one; returns an error rather than the GUI confirm alert.
        resolver.resolveWorkspace(target, window: window) { store, id in
            guard store.canRemoveWorkspace else {
                return ControlResponse(ok: false, error: "cannot delete last workspace")
            }
            store.removeWorkspace(id)
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

    // MARK: - Keymap

    /// Re-read and re-parse `keymap.conf`, returning the count of parse diagnostics. The SAME
    /// `reloadKeymap()` path the GUI's File ▸ Reload Keymap menu/palette item drives, so the menu/palette
    /// and `keymap.reload` never diverge — control-native here only in the count it reports back.
    func reloadKeymap() -> ControlResponse {
        settingsModel.reloadKeymap()
        return ControlResponse(ok: true, result: ControlResult(count: settingsModel.keymapDiagnostics.count))
    }

    // MARK: - Config

    /// Re-read and apply the ghostty config, returning the config-diagnostic count (0 = clean), counted
    /// across ALL config sources (bundled defaults, the global `~/.config/ghostty/config`, the agterm-scoped
    /// `ghostty.conf`, and the UI settings conf) — libghostty diagnostics carry no source-file attribution.
    /// The SAME `AppActions.reloadGhosttyConfig()` path the GUI's File ▸ Reload Config menu/palette item
    /// drives (which posts the warning banner on diagnostics), so the GUI and `config.reload` never diverge
    /// — control-native here only in the count it reports back. The count is the value the reload actually
    /// produced (threaded back from the reload), not a separate re-read. App-global (one settings model +
    /// one GhosttyApp), so no `--window` selector, like `keymap.reload`.
    func reloadGhosttyConfig() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(count: actions.reloadGhosttyConfig()))
    }

    // MARK: - Theme

    /// Set + persist a theme PER SLOT — the control half of the Settings pickers / the `.themes` palette
    /// commit (no live preview over the socket). `args.name` (alias `args.light`; both is an error) sets the
    /// light/single slot, keeping any dark slot; `args.dark` sets the dark slot and turns macOS-appearance
    /// syncing ON (the stored value becomes ghostty's dual `light:,dark:`, light side seeded), and the
    /// reserved value `none` (any case) clears it (syncing off). A nil/empty name selects ghostty's built-in colors
    /// ("default ghostty"), NOT the seeded `agterm` app default; any other name must be a bundled theme, else
    /// an error (a typo silently doing nothing is worse than a fail). Echoes the full post-change state
    /// (`theme`/`sync`/`light`/`dark`). App-global: one `SettingsModel`, so no `--window` selector.
    func setTheme(args: ControlArgs?) -> ControlResponse {
        let name = ThemeCatalog.resolvedName(args?.name)
        let light = ThemeCatalog.resolvedName(args?.light)
        let dark = ThemeCatalog.resolvedName(args?.dark)
        if name != nil && light != nil {
            return ControlResponse(ok: false, error: "theme.set takes either a name or --light, not both")
        }
        let lightSlot = name ?? light
        let clearDark = dark?.lowercased() == "none"
        let catalog = ThemeCatalog(names: actions.availableThemes())
        for theme in [lightSlot, clearDark ? nil : dark].compactMap({ $0 })
        where !catalog.contains(name: theme) {
            return ControlResponse(ok: false, error: "unknown theme: \(theme)")
        }
        if clearDark {
            actions.setDarkTheme(nil)
            if lightSlot != nil { actions.setLightTheme(lightSlot) }
        } else if let dark {
            if let lightSlot {
                actions.setSystemThemes(light: lightSlot, dark: dark)
            } else {
                actions.setDarkTheme(dark)
            }
        } else {
            actions.setLightTheme(lightSlot) // nil = bare `theme set`: reset to ghostty built-in
        }
        return ControlResponse(ok: true, result: ControlResult(
            theme: actions.currentTheme, sync: actions.followsSystemAppearance,
            light: actions.currentLightTheme, dark: actions.currentDarkTheme))
    }

    func listThemes() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(theme: actions.currentTheme,
                                                        themes: actions.availableThemes(),
                                                        sync: actions.followsSystemAppearance,
                                                        light: actions.currentLightTheme,
                                                        dark: actions.currentDarkTheme))
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
            // capture the status BEFORE mutating so the Settings default plays only on a real transition.
            let wasBlocked = store.session(withID: id)?.agentIndicator.status == .blocked
            store.setAgentIndicator(AgentIndicator(status: update.status, blink: update.blink ?? false,
                                                   autoReset: update.autoReset ?? false,
                                                   color: update.color, statusPane: update.pane), forSession: id)
            // explicit per-call sound wins on any status; the Settings default plays only when a session
            // newly enters `blocked`, not on a repeated `blocked` set.
            let blockedDefault = wasBlocked ? nil : self.settingsModel.settings.blockedStatusSoundName
            if let name = update.status.effectiveSound(perCall: update.sound, blockedDefault: blockedDefault) {
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

    /// `workspace.move`: reorder a workspace among its siblings (`up`|`down`|`top`|`bottom`). `to` is
    /// required; an invalid direction errors. Resolves the workspace target via `resolveWorkspace`
    /// (honoring the global `--window` selector like other workspace commands).
    func moveWorkspace(_ target: String?, window: String?, direction dir: ReorderDirection) -> ControlResponse {
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
        if let zoom = TerminalZoomRegistry.shared.controller(for: library.activeWindowID), zoom.target != nil {
            // a script must always be able to DISMISS the quick terminal (hide was a guaranteed-ok
            // idempotent no-op pre-zoom, and cleanup code relies on that): hiding un-zooms a zoomed
            // quick terminal first, then hides it. Only SHOWING one under/over the zoom layer stays
            // blocked — that would strand an unmounted-but-visible cover.
            guard !want else {
                return ControlResponse(ok: false, error: "terminal zoom active")
            }
            if zoom.target == .quick { zoom.clear() }
            if controller.isVisible { controller.hide() }
            return ControlResponse(ok: true)
        }
        if want != controller.isVisible {
            if want { controller.show() } else { controller.hide() }
        }
        return ControlResponse(ok: true)
    }

    /// Inject `text` as literal keystrokes into the frontmost window's quick terminal, the quick-terminal
    /// twin of `session.type` (input goes where the user is typing when the overlay is up). `quick show`
    /// flips `isVisible` before SwiftUI mounts + libghostty realizes the surface, so `quick show; quick
    /// type` would otherwise race the mount — this polls briefly (like `session.type`'s realize poll) so a
    /// back-to-back script types reliably. Fails fast with `quick terminal not open` when the overlay has
    /// never been shown (no surface AND not visible), `quick terminal not realized` if a shown surface
    /// never comes up within the poll, `no open window` when there is no window.
    func typeQuick(text: String) async -> ControlResponse {
        guard let controller = QuickTerminalRegistry.shared.controller(for: library.activeWindowID) else {
            return ControlResponse(ok: false, error: "no open window")
        }
        // probe first (fast path), then sleep-then-probe up to 12 more times — a probe follows every sleep
        // so the full ~360ms window is used, matching `session.type`'s realize poll (no wasted trailing sleep).
        for attempt in 0...12 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            if let surface = controller.currentSurface() {
                // a false inject means the view exists but its libghostty surface isn't realized yet — keep
                // polling rather than reporting a silent-drop false ok. A shown-then-hidden surface stays
                // alive and realized (types while hidden, like `--pane scratch`), so it lands here at once.
                if surface.inject(text: text) {
                    return ControlResponse(ok: true)
                }
            } else if !controller.isVisible {
                // no surface and not showing → never shown; don't wait out the poll.
                return ControlResponse(ok: false, error: "quick terminal not open")
            }
        }
        return ControlResponse(ok: false, error: "quick terminal not realized")
    }

    /// Read the frontmost window's quick-terminal screen as plain text, the quick-terminal twin of
    /// `session.text` — the read-back for `quick.type`. `all` reads the full screen + scrollback, `lines`
    /// keeps only the last N; the quick terminal has a single surface, so there's no `--pane`. Polls for
    /// mount + realization like `typeQuick` so `quick show; quick text` doesn't race the mount; fails fast
    /// with `quick terminal not open` when never shown, `failed to read surface buffer` if a shown surface
    /// never realizes within the poll, `no open window` when there is no window.
    func readQuickText(all: Bool, lines: Int?) async -> ControlResponse {
        guard let controller = QuickTerminalRegistry.shared.controller(for: library.activeWindowID) else {
            return ControlResponse(ok: false, error: "no open window")
        }
        // probe first, then sleep-then-probe up to 12 more times (a probe follows every sleep), like `typeQuick`.
        for attempt in 0...12 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            if let surface = controller.currentSurface() {
                // readScreenText returns nil only for an unrealized surface ("" for a realized blank
                // screen), so a non-nil result means the surface is up — return it.
                if let text = surface.readScreenText(all: all, lines: lines) {
                    return ControlResponse(ok: true, result: ControlResult(text: text))
                }
            } else if !controller.isVisible {
                return ControlResponse(ok: false, error: "quick terminal not open")
            }
        }
        return ControlResponse(ok: false, error: "failed to read surface buffer")
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

    /// Show / hide / toggle the frontmost window's sidebar (the custom split owns visibility, so there's
    /// no system toggle). Flips only when the requested state differs; an unknown mode is an error, and no
    /// open window is an error rather than a silent no-op.
    func setSidebar(mode: ControlToggleMode) -> ControlResponse {
        guard let store = library.activeStore else {
            return ControlResponse(ok: false, error: "no open window")
        }
        let want = mode.desiredValue(current: store.sidebarVisible)
        store.setSidebarVisible(want) // no-op + no save when unchanged (idempotent)
        return ControlResponse(ok: true)
    }

    /// Set the frontmost window's sidebar VIEW mode (the tree vs the flat flagged list) — distinct from
    /// `setSidebar` (visibility). `mode` is `tree|flagged|toggle`, delta-computed so a no-op mode skips
    /// the write (idempotent), via `AppStore.setSidebarMode`. An unknown mode + no-open-window are errors.
    func setSidebarViewMode(mode: ControlSidebarViewMode) -> ControlResponse {
        guard let store = library.activeStore else {
            return ControlResponse(ok: false, error: "no open window")
        }
        let want: SidebarMode
        switch mode {
        case .tree: want = .tree
        case .flagged: want = .flagged
        case .toggle: want = store.sidebarMode == .tree ? .flagged : .tree
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
