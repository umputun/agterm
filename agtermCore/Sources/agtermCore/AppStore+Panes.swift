import Foundation

// MARK: - Split, overlay, and scratch panes

extension AppStore {
    /// Toggles the one-level split for a session. The second pane's surface is created
    /// lazily by the detail pane on first show and kept alive when hidden, so this only
    /// flips the flag. The flag is persisted, so the split is restored on relaunch.
    public func toggleSplit(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.isSplit.toggle()
        // opening marks the session as having a split and moves focus to the new (right) pane; hiding
        // (toggling off) leaves `hasSplit` and `splitFocused` set so the split indicators persist and
        // the focused pane is the one shown maximized. Only `closeSplit` clears them.
        if session.isSplit {
            session.hasSplit = true
            session.splitFocused = true
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
        session.splitRatio = nil // tearing down the split clears its geometry too, so a fresh split opens even
        // a search bar pinned to the torn-down split surface would otherwise stay stuck (the weak
        // `searchSurface` zeroes but `searchActive` stays true), so reset search on the surviving session.
        session.clearSearch()
        save()
    }

    /// The primary pane's shell exited. If a split pane is alive it becomes the session's single
    /// (non-split) pane and the session survives; otherwise the session is closed. The survivor stays
    /// in the `splitSurface` slot, shown maximized via `splitFocused`, and its cwd is promoted to the
    /// session's so a restart restores the single session in the right directory. Called by the primary
    /// surface's `onExit`.
    public func closePrimaryPane(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        guard session.splitSurface != nil else {
            closeSession(sessionID)
            return
        }
        session.surface?.teardown()
        session.surface = nil
        session.isSplit = false
        session.hasSplit = false
        session.splitFocused = true
        session.splitRatio = nil // promoted to a single pane; a later split should open even, not stale
        // the command pane is gone — the promoted survivor is a plain shell, so drop the creation command
        // or a restart would resurrect the exited command instead of restoring the promoted shell.
        session.initialCommand = nil
        if let cwd = session.splitCwd { session.currentCwd = cwd }
        // the primary surface (possibly the search owner) is torn down while the session survives as the
        // promoted split, so reset search rather than leave a stuck bar pinned to the gone primary.
        session.clearSearch()
        save()
    }

    /// The split pane's shell exited. If the primary is alive the split collapses to it (`closeSplit`);
    /// otherwise the primary already exited, so this was the last pane and the session is closed. Called
    /// by the split surface's `onExit`.
    public func closeSplitPane(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        guard session.surface != nil else {
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
        scratch.teardown()
        session.scratchSurface = nil
        return true
    }
}
