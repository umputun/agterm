import Foundation

// MARK: - Split, overlay, and scratch panes

extension AppStore {
    /// Toggles the one-level split. The second pane's surface is created lazily by the detail pane and kept
    /// alive when hidden, so this only flips the persisted flag.
    public func toggleSplit(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.isSplit.toggle()
        // a NEW split focuses the new (right) pane; RE-showing a hidden one keeps the pane focused before
        // hiding, so a hide/show round-trip (the tmux-style zoom script) doesn't jerk focus right. hiding
        // leaves `hasSplit`/`splitFocused` set — indicators persist, the focused pane shows maximized — and
        // only `closeSplit` clears them.
        if session.isSplit {
            let isNewSplit = !session.hasSplit
            session.hasSplit = true
            if isNewSplit { session.splitFocused = true }
        }
        save()
    }

    /// Sets a session's split-divider left-pane fraction, clamped and persisted; returns the applied
    /// fraction, nil for an unknown id. Moving the LIVE divider is the caller's job (`session.resize` posts
    /// `.agtermApplySplitRatio` to the pane view): control-native, no GUI path through `AppActions`.
    @discardableResult
    public func applySplitRatio(_ ratio: Double, forSession id: UUID) -> Double? {
        guard let session = session(withID: id) else { return nil }
        let applied = AppStore.clampSplitRatio(ratio)
        session.splitRatio = applied
        save()
        return applied
    }

    /// Clear the agent-status indicator when the pane that OWNED it is torn down, so a pane-tagged block
    /// can't strand a glyph no surviving surface can keystroke-clear (`AgentIndicator.clearedBy` requires the
    /// typing pane to match `statusPane`). `owner` is the departing pane; a nil tag counts as `.left`,
    /// matching the clear-decision default. Mirrors `clearSearch()` on these same teardown paths.
    private func clearIndicatorOwnedByPane(_ owner: StatusPane, of session: Session) {
        guard session.agentIndicator.status != .idle,
              (session.agentIndicator.statusPane ?? .left) == owner else { return }
        setAgentIndicator(AgentIndicator(), forSession: session.id)
    }

    /// Closes the split pane: hides it AND tears down its surface, so a later split starts a fresh shell.
    /// Used on the split shell's own exit; resets `splitFocused`, else it points the collapsed view at the
    /// gone pane.
    public func closeSplit(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.isSplit = false
        session.hasSplit = false
        session.splitFocused = false
        session.splitSurface?.teardown()
        session.splitSurface = nil
        session.splitCwd = nil
        session.splitTitle = nil
        session.initialSplitCwd = nil
        // the right pane is gone: drop both the persisted pin and any payload still armed for this launch,
        // so a fresh split is a plain shell.
        session.splitRestoreCommand = nil
        session.pendingSplitRestoreCommand = nil
        session.splitRatio = nil // tearing down the split clears its geometry too, so a fresh split opens even
        // a search bar pinned to the torn-down split surface would stay stuck (the weak `searchSurface`
        // zeroes but `searchActive` stays true), so reset search on the surviving session.
        session.clearSearch()
        // the departing right pane owned any `.right`-tagged block, which no survivor can keystroke-clear.
        clearIndicatorOwnedByPane(.right, of: session)
        save()
    }

    /// The primary pane's shell exited: a live split is PROMOTED into the primary slot and the session
    /// survives as a single pane, otherwise the session closes. The survivor MOVES from `splitSurface` into
    /// `surface` (cwd, title and foreground command migrate too, and `promoteToPrimaryPane` turns off its
    /// split-role reporting so future pwd/title reports write to the main fields), leaving `surface != nil`,
    /// `splitSurface == nil`, `hasSplit == false`, `splitFocused == false` — so the promoted pane is
    /// addressable as the MAIN/left pane everywhere: `session.type`/`session.text --pane left` (and omitted)
    /// reach it, `{AGT_PANE}` reports `left`, and a later `session.split` opens a fresh RIGHT pane instead of
    /// displacing it. Called by the primary surface's `onExit`.
    public func closePrimaryPane(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        guard let survivor = session.splitSurface else {
            closeSession(sessionID)
            return
        }
        let priorPrimary = session.surface // the exiting pane, torn down below; scopes the search reset
        priorPrimary?.teardown()
        survivor.promoteToPrimaryPane()
        session.surface = survivor
        session.splitSurface = nil
        session.isSplit = false
        session.hasSplit = false
        session.splitFocused = false
        session.splitRatio = nil // promoted to a single pane; a later split should open even, not stale
        // the promoted survivor is a plain shell: drop the creation command and its held-open flag together,
        // or a restart resurrects the exited command and a snapshot persists commandWait with no initialCommand.
        session.initialCommand = nil
        session.commandWait = false
        // migrate the split's metadata up, then clear the split fields so nothing describes a gone pane. cwd
        // prefers the split's live PWD, then `initialSplitCwd` (a restored split whose shell hasn't emitted
        // OSC yet), falling back to the exited primary's only when the split has none. title is replaced
        // OUTRIGHT (nil clears it) so the dead primary's can't linger, likewise foregroundCommand.
        session.currentCwd = session.splitCwd ?? session.initialSplitCwd ?? session.currentCwd
        session.oscTitle = session.splitTitle
        session.foregroundCommand = session.splitForegroundCommand
        // the restore-command override follows the survivor, BOTH halves: the persisted pin (so the next
        // launch restores the promoted pane's command, not the dead primary's) and the payload still armed
        // for this launch (so a surface built after promotion still runs it).
        session.restoreCommand = session.splitRestoreCommand
        session.pendingRestoreCommand = session.pendingSplitRestoreCommand
        session.splitCwd = nil
        session.splitTitle = nil
        session.initialSplitCwd = nil
        session.splitForegroundCommand = nil
        session.splitRestoreCommand = nil
        session.pendingSplitRestoreCommand = nil
        // reset search only if the torn-down primary owned the bar (or the weak ref already dangled), so a
        // search owned by the SURVIVING pane stays valid across promotion — `closeScratch`'s identity guard.
        if session.searchSurface == nil || session.searchSurface === priorPrimary {
            session.clearSearch()
        }
        // the exited primary owned any `.left`/nil tag, which dies with it; a `.right` tag belonged to the
        // survivor and FOLLOWS it, re-tagged `.left` so `tree` (now `split:false`) and the survivor's
        // `.left`-role keystroke-clear agree instead of contradicting. `.scratch` is untouched.
        if session.agentIndicator.status != .idle {
            switch session.agentIndicator.statusPane ?? .left {
            case .left: setAgentIndicator(AgentIndicator(), forSession: session.id)
            case .right:
                var promoted = session.agentIndicator
                promoted.statusPane = .left
                setAgentIndicator(promoted, forSession: session.id)
            case .scratch: break
            }
        }
        save()
    }

    /// The split pane's shell exited: collapses to the primary (`closeSplit`) ONLY when a genuine two-pane
    /// split is live, BOTH `surface` and `splitSurface` set. Otherwise this was the session's last pane —
    /// promoted into the primary slot (`splitSurface == nil`) while keeping the split pane's `onExit`, so its
    /// exit routes here — and closing rather than collapsing a gone split is what avoids a zombie session.
    /// The `surface == nil` half of the guard is defensive: `closePrimaryPane` always promotes the survivor
    /// INTO `surface`. Called by the split surface's `onExit`.
    public func closeSplitPane(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        guard session.surface != nil, session.splitSurface != nil else {
            closeSession(sessionID)
            return
        }
        closeSplit(sessionID)
    }

    /// Opens an ephemeral overlay terminal on a session running `command` (e.g. a TUI). The surface is
    /// created lazily by the detail pane and runs the command as its process; `closeOverlay` tears it down
    /// when the program exits. False for an unknown session or one already showing an overlay. NOT persisted.
    /// - `sizePercent` (clamped to 1...100) requests a *floating* overlay: an opaque framed panel at that
    ///   percent of the pane with the session visible behind it; nil gives the full-pane overlay that hides it.
    /// - `backgroundColor` (`#rrggbb`) gives the overlay pane its own solid background, independent of the
    ///   session's; nil leaves the default theme background. Read by the overlay factory at creation.
    @discardableResult public func openOverlay(_ sessionID: UUID, command: String, cwd: String? = nil,
                                               wait: Bool = false, sizePercent: Int? = nil,
                                               backgroundColor: String? = nil) -> Bool {
        guard let session = session(withID: sessionID), !session.overlayActive else { return false }
        session.overlayCommand = command
        session.overlayCwd = cwd
        session.overlayWait = wait
        session.overlayExitCode = nil
        session.overlaySizePercent = sizePercent.map { min(100, max(1, $0)) }
        session.overlayBackgroundColor = backgroundColor
        session.overlayActive = true
        return true
    }

    /// Resizes an already-open overlay in place: `sizePercent` (clamped to 1...100) switches it to floating,
    /// nil to the translucent full-pane overlay, as in `openOverlay`. The surface stays mounted (the detail
    /// pane hosts both variants), so only the layout re-flows and the program never re-spawns. False with no
    /// open overlay.
    @discardableResult public func resizeOverlay(_ sessionID: UUID, sizePercent: Int?) -> Bool {
        guard let session = session(withID: sessionID), session.overlayActive else { return false }
        session.overlaySizePercent = sizePercent.map { min(100, max(1, $0)) }
        return true
    }

    /// Records the overlay program's exit status (parsed app-side from the wrapper's temp file at surface
    /// teardown) so `session.overlay.result` can report it after the overlay closes. No-op for an unknown id.
    public func recordOverlayExit(_ sessionID: UUID, code: Int) {
        session(withID: sessionID)?.overlayExitCode = code
    }

    /// Closes the overlay terminal: hides it AND tears down its surface — unlike the split it is ephemeral,
    /// never kept alive. Used on explicit close and when the program exits. No-op (false) with no overlay.
    @discardableResult public func closeOverlay(_ sessionID: UUID) -> Bool {
        guard let session = session(withID: sessionID), session.overlayActive else { return false }
        session.overlayActive = false
        session.overlaySurface?.teardown()
        session.overlaySurface = nil
        session.overlayCommand = nil
        session.overlayCwd = nil
        session.overlayWait = false
        session.overlaySizePercent = nil
        session.overlayBackgroundColor = nil
        return true
    }

    /// Toggles the scratch terminal — a third, full-overlay login shell. Its surface is created lazily by the
    /// detail pane and, like the split, kept alive when hidden, so a re-show reuses the same shell. Not
    /// persisted, so no `save()`.
    public func toggleScratch(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.scratchActive.toggle()
    }

    /// Closes the scratch terminal: hides it AND tears down its surface, so a later show starts a fresh
    /// shell. Used on the scratch shell's own `exit` and on session/workspace/window teardown; false with no
    /// scratch surface.
    @discardableResult public func closeScratch(_ sessionID: UUID) -> Bool {
        guard let session = session(withID: sessionID), let scratch = session.scratchSurface else { return false }
        session.scratchActive = false
        // a search bar pinned to the scratch being torn down would stay stuck; guarded on identity so a
        // search owned by the main/split pane survives.
        if session.searchSurface === scratch { session.clearSearch() }
        // the `.scratch`-tagged block loses its owning surface here; a main/split tag survives (helper guards).
        clearIndicatorOwnedByPane(.scratch, of: session)
        scratch.teardown()
        session.scratchSurface = nil
        return true
    }
}
