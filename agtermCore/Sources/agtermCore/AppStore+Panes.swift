import Foundation

// MARK: - Split, overlay, and scratch panes

extension AppStore {
    /// Toggles the one-level split for a session. The second pane's surface is created
    /// lazily by the detail pane on first show and kept alive when hidden, so this only
    /// flips the flag. The flag is persisted, so the split is restored on relaunch.
    public func toggleSplit(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.isSplit.toggle()
        // opening a NEW split marks the session as having one and moves focus to the new (right) pane;
        // RE-showing a hidden split preserves whichever pane was focused before it was hidden (so a
        // hide/show round-trip, e.g. the tmux-style zoom script, doesn't jerk focus to the right pane).
        // hiding (toggling off) leaves `hasSplit` and `splitFocused` set so the split indicators persist
        // and the focused pane is the one shown maximized. Only `closeSplit` clears them.
        if session.isSplit {
            let isNewSplit = !session.hasSplit
            session.hasSplit = true
            if isNewSplit { session.splitFocused = true }
        }
        save()
    }

    /// Sets a session's split-divider left-pane fraction to `ratio`, clamped to the bounds, and persists.
    /// Returns the applied (clamped) fraction, or nil when the id is unknown. Moving the LIVE divider is
    /// driven separately by the caller (`session.resize` posts `.agtermApplySplitRatio` to the pane view) —
    /// this is control-native, so there is no GUI surface that goes through `AppActions`.
    @discardableResult
    public func applySplitRatio(_ ratio: Double, forSession id: UUID) -> Double? {
        guard let session = session(withID: id) else { return nil }
        let applied = AppStore.clampSplitRatio(ratio)
        session.splitRatio = applied
        save()
        return applied
    }

    /// Clear the agent-status indicator when the pane that OWNED it is being torn down, so a pane-tagged
    /// block (`session.status --pane`) can't strand a glyph no surviving surface can keystroke-clear
    /// (`AgentIndicator.clearedBy` requires the typing pane to match `statusPane`). `owner` is the pane
    /// whose surface is going away; a nil tag counts as `.left` (main), matching the clear-decision default.
    /// Mirrors the `clearSearch()` reconcile on these same teardown paths.
    private func clearIndicatorOwnedByPane(_ owner: StatusPane, of session: Session) {
        guard session.agentIndicator.status != .idle,
              (session.agentIndicator.statusPane ?? .left) == owner else { return }
        setAgentIndicator(AgentIndicator(), forSession: session.id)
    }

    /// Closes the split pane: hides it AND tears down its surface, so a subsequent split
    /// starts a fresh shell. Used when the split shell exits on its own; resets the focus flag so a
    /// stale `splitFocused` doesn't point the collapsed view at the gone pane.
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
        // the right pane is gone, so its restore-command override describes nothing: drop both the
        // persisted pin and any payload still armed for this launch (a fresh split must be a plain shell).
        session.splitRestoreCommand = nil
        session.pendingSplitRestoreCommand = nil
        session.splitRatio = nil // tearing down the split clears its geometry too, so a fresh split opens even
        // a search bar pinned to the torn-down split surface would otherwise stay stuck (the weak
        // `searchSurface` zeroes but `searchActive` stays true), so reset search on the surviving session.
        session.clearSearch()
        // the split (right) pane owned any `.right`-tagged block; with it gone the surviving main pane can
        // never keystroke-clear that tag, so clear it here (mirrors the search reset above).
        clearIndicatorOwnedByPane(.right, of: session)
        save()
    }

    /// The primary pane's shell exited. If a split pane is alive it is PROMOTED into the primary slot
    /// and the session survives as a single (non-split) pane; otherwise the session is closed. The
    /// survivor MOVES from `splitSurface` into `surface` (its surface, cwd, title, and foreground command
    /// migrate to the main fields, and its split-role reporting is turned off via `promoteToPrimaryPane`),
    /// so the session becomes indistinguishable from a fresh single pane: `surface != nil`,
    /// `splitSurface == nil`, `hasSplit == false`, `splitFocused == false`. That is what makes the
    /// promoted pane addressable as the MAIN/left pane everywhere — `session.type`/`session.text --pane
    /// left` (and omitted) reach it, `{AGT_PANE}` reports `left`, and a later `session.split` opens a
    /// fresh RIGHT pane instead of displacing the survivor. Called by the primary surface's `onExit`.
    public func closePrimaryPane(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        guard let survivor = session.splitSurface else {
            closeSession(sessionID)
            return
        }
        let priorPrimary = session.surface // the exiting pane, torn down below; scopes the search reset
        priorPrimary?.teardown()
        // promote the surviving split pane into the primary slot. `promoteToPrimaryPane` flips the
        // surface's split-role flag so its future pwd/title reports write to the main fields.
        survivor.promoteToPrimaryPane()
        session.surface = survivor
        session.splitSurface = nil
        session.isSplit = false
        session.hasSplit = false
        session.splitFocused = false
        session.splitRatio = nil // promoted to a single pane; a later split should open even, not stale
        // the command pane is gone — the promoted survivor is a plain shell, so drop the creation command
        // (and its held-open flag) together or a restart would resurrect the exited command instead of the
        // promoted shell, and a snapshot would persist commandWait with no initialCommand.
        session.initialCommand = nil
        session.commandWait = false
        // migrate the split pane's live/persisted metadata up to the session (main) fields, then clear the
        // now-meaningless split fields so nothing still describes a pane that no longer exists.
        // cwd prefers the split's live PWD, then its restore-seed (`initialSplitCwd`, set for a restored
        // split whose shell hasn't emitted OSC yet), and only falls back to the exited primary's cwd when
        // the split has none at all (a fresh split seeds its cwd from the primary anyway). title is replaced
        // OUTRIGHT from the split's (nil clears it) so the dead primary's title can never linger on the
        // survivor — likewise foregroundCommand, so the exited primary's captured command can't either.
        session.currentCwd = session.splitCwd ?? session.initialSplitCwd ?? session.currentCwd
        session.oscTitle = session.splitTitle
        session.foregroundCommand = session.splitForegroundCommand
        // the restore-command override follows the survivor into the main slot the same way, BOTH halves:
        // the persisted pin (so the next launch restores the promoted pane's command, not the dead
        // primary's) and any payload still armed for this launch (so a surface built after promotion
        // still runs it).
        session.restoreCommand = session.splitRestoreCommand
        session.pendingRestoreCommand = session.pendingSplitRestoreCommand
        session.splitCwd = nil
        session.splitTitle = nil
        session.initialSplitCwd = nil
        session.splitForegroundCommand = nil
        session.splitRestoreCommand = nil
        session.pendingSplitRestoreCommand = nil
        // reset search only if the torn-down primary owned the bar (or the weak ref already dangled), so a
        // search owned by the SURVIVING pane stays valid across promotion — matching closeScratch's
        // identity guard rather than clearing unconditionally and dropping a still-valid search.
        if session.searchSurface == nil || session.searchSurface === priorPrimary {
            session.clearSearch()
        }
        // migrate the agent-status identity like the cwd/title above: the exited primary owned any
        // `.left`/nil-tagged block, which dies with it (clear); a `.right`-tagged block belonged to the
        // promoted survivor and FOLLOWS it into the main slot — re-tag to `.left` so the `tree` (which now
        // reports `split:false`) and the survivor's now-`.left`-role-aware keystroke-clear agree, instead of
        // a self-contradictory `split:false` + `statusPane:"right"`. A `.scratch` block is untouched.
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

    /// The split pane's shell exited. It collapses to the primary (`closeSplit`) ONLY when a genuine
    /// two-pane split is live — BOTH `surface` and `splitSurface` set. Otherwise this was the session's
    /// last pane and the session is closed: the surface has been PROMOTED into the primary slot
    /// (`splitSurface == nil`) — a promoted survivor keeps the split pane's `onExit`, so its own exit still
    /// routes here, and closing (not collapsing a split that no longer exists) is what keeps it from
    /// leaving a zombie session. (The `surface == nil` half of the guard is defensive: `closePrimaryPane`
    /// now always promotes the survivor INTO `surface`, so a live `splitSurface` implies a live `surface`.)
    /// Called by the split surface's `onExit`.
    public func closeSplitPane(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        guard session.surface != nil, session.splitSurface != nil else {
            closeSession(sessionID)
            return
        }
        closeSplit(sessionID)
    }

    /// Opens an ephemeral overlay terminal on a session running `command` (e.g. a TUI). The overlay
    /// surface is created lazily by the detail pane and runs the command as its process; when the
    /// program exits, `closeOverlay` tears it down. No-op (returns false) when the session is unknown
    /// or already has an overlay open. NOT persisted — the overlay never survives a relaunch.
    ///
    /// `sizePercent` (clamped to 1...100) requests a *floating* overlay: an opaque, framed panel sized
    /// to that percent of the pane, with the session still visible behind it. nil gives the default
    /// full-pane overlay that hides the session.
    ///
    /// `backgroundColor` (`#rrggbb`) gives the overlay pane its own solid background, independent of the
    /// session's; nil leaves the default theme background. Read by the overlay surface factory at creation.
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

    /// Resizes an already-open overlay in place. `sizePercent` (clamped to 1...100) switches it to a
    /// *floating* opaque framed panel at that percent of the pane with the session visible behind it;
    /// nil switches it to the full-pane overlay that hides the session and draws translucent. The overlay
    /// surface stays mounted (the detail pane hosts both variants in one place), so this only re-flows the
    /// layout — the program keeps running, never re-spawns. No-op (returns false) with no overlay open.
    @discardableResult public func resizeOverlay(_ sessionID: UUID, sizePercent: Int?) -> Bool {
        guard let session = session(withID: sessionID), session.overlayActive else { return false }
        session.overlaySizePercent = sizePercent.map { min(100, max(1, $0)) }
        return true
    }

    /// Records the overlay program's exit status (parsed app-side from the wrapper's temp file on the
    /// surface's teardown) so `session.overlay.result` can report it after the overlay closes. No-op
    /// for an unknown session.
    public func recordOverlayExit(_ sessionID: UUID, code: Int) {
        session(withID: sessionID)?.overlayExitCode = code
    }

    /// Closes the overlay terminal: hides it AND tears down its surface (unlike the split, the overlay
    /// is never kept alive — it is ephemeral). Used both on explicit close and when the overlay's
    /// program exits on its own. No-op (returns false) when there is no overlay.
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

    /// Toggles the scratch terminal for a session — a third, full-overlay login shell. The scratch
    /// surface is created lazily by the detail pane on first show and, like the split, kept alive when
    /// hidden (this only flips `scratchActive`), so a re-show reuses the same shell. Not persisted, so
    /// no `save()`. No-op for an unknown session.
    public func toggleScratch(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.scratchActive.toggle()
    }

    /// Closes the scratch terminal: hides it AND tears down its surface (so a subsequent show starts a
    /// fresh shell). Used on the scratch shell's own `exit` and on session/workspace/window teardown.
    /// No-op (returns false) when there is no scratch surface.
    @discardableResult public func closeScratch(_ sessionID: UUID) -> Bool {
        guard let session = session(withID: sessionID), let scratch = session.scratchSurface else { return false }
        session.scratchActive = false
        // if the open search bar is pinned to the scratch being torn down, reset search rather than leave a
        // stuck, no-op bar (the weak `searchSurface` zeroes but `searchActive` stays true) — mirrors the
        // closeSplit/closePrimaryPane handling. Guarded on identity so a search owned by the main/split pane
        // (the scratch can cover a session whose pane opened search) survives the scratch teardown.
        if session.searchSurface === scratch { session.clearSearch() }
        // a `.scratch`-tagged block loses its owning surface here; clear it so it can't strand a glyph the
        // surviving main/split panes can never keystroke-clear (a main/split tag survives — the helper guards).
        clearIndicatorOwnedByPane(.scratch, of: session)
        scratch.teardown()
        session.scratchSurface = nil
        return true
    }
}
