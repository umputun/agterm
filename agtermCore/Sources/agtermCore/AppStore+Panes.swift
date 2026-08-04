import Foundation

// MARK: - Split, overlay, and scratch panes

/// Why `openPaneOverlay` refused. Typed rather than a bare `false` so the control arm maps each case to
/// its own error string instead of guessing which rejection fired.
public enum PaneOverlayOpenFailure: Equatable, Sendable {
    case unknownSession
    case alreadyOpen
    case paneNotVisible
}

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
        // hiding the split un-renders a pane, so an overlay opened on it that has not realized yet would sit
        // active with no surface and no program forever.
        session.dropUnrealizedPaneOverlays()
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
        // the right pane is gone, so its overlay has nothing left to cover and nobody left to read its status.
        session.teardownPaneOverlay(.right)
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
        // the pane overlays follow their panes: the exiting primary's dies with it, the survivor's moves into
        // the left slot WITH its exit code, so `session.overlay.result --pane left` still answers afterwards.
        session.teardownPaneOverlay(.left)
        session.promotePaneOverlay()
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
    /// when the program exits. False for an unknown session or one already showing a caller's PROGRAM — a
    /// HUD instead yields the slot, since it is a message about work in flight and nothing is lost by
    /// replacing it. NOT persisted.
    /// - `sizePercent` (clamped to 1...100) requests a *floating* overlay: an opaque framed panel at that
    ///   percent of the pane with the session visible behind it; nil gives the full-pane overlay that hides it.
    /// - `backgroundColor` (`#rrggbb`) gives the overlay pane its own solid background, independent of the
    ///   session's; nil leaves the default theme background. Read by the overlay factory at creation.
    @discardableResult public func openOverlay(_ sessionID: UUID, command: String, cwd: String? = nil,
                                               wait: Bool = false, sizePercent: Int? = nil,
                                               backgroundColor: String? = nil) -> Bool {
        guard let session = session(withID: sessionID) else { return false }
        if session.hudActive { closeOverlay(sessionID) }
        guard !session.overlayActive else { return false }
        session.overlaySlotGeneration += 1
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
    /// open overlay. A HUD in the slot takes the narrower `HudLayout.clampSizePercent` bound instead, so no
    /// resize path can grow a message until it covers the session it is about, and the percent reaches its
    /// WIDTH alone: its height stays measured from the message, which a resize does not change (the text
    /// wraps at `HudLayout.maxColumns`, not at the panel).
    @discardableResult public func resizeOverlay(_ sessionID: UUID, sizePercent: Int?) -> Bool {
        guard let session = session(withID: sessionID), session.overlayActive else { return false }
        let hud = session.hudActive
        session.overlaySizePercent = sizePercent.map { hud ? HudLayout.clampSizePercent($0) : min(100, max(1, $0)) }
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
        // every teardown routes through here — explicit close, ⌘W, the program's own exit, a replacement —
        // so discarding the HUD here is what keeps `hudActive` and its body file from outliving the slot they
        // describe, including for a HUD whose surface never realized and so never tore itself down.
        session.discardHudBody()
        return true
    }

    /// Opens a HUD in the session's overlay slot: a passive message panel rendered by the app's bundled
    /// helper, which `command` runs and which re-reads `file` every tick. Always FLOATING and always within
    /// `HudLayout.clampSizePercent` — the app's measurement or the caller's `spec.sizePercent`, whichever
    /// applies, bounded — because a HUD must never cover the session it is a message about.
    ///
    /// A live HUD is REPLACED (torn down and re-opened, so the helper picks up the new file), a live
    /// PROGRAM overlay refuses. False for an unknown session or an occupied program slot. NOT persisted.
    @discardableResult public func openHud(_ sessionID: UUID, command: String, spec: HudSpec, file: String,
                                           size: HudPanelSize) -> Bool {
        guard openOverlay(sessionID, command: command,
                          sizePercent: HudLayout.clampSizePercent(size.widthPercent),
                          backgroundColor: spec.backgroundColor),
              let session = session(withID: sessionID) else { return false }
        session.hudSpec = spec
        session.hudFile = file
        session.hudHeightPercent = size.heightPercent
        return true
    }

    /// Rewrites a live HUD's message and size in place: the surface stays mounted and the helper re-reads
    /// its body file on the next tick, so the panel changes with no re-spawn and no blink. The file path is
    /// not an argument — an update rewrites the path `openHud` already gave the running helper, per
    /// `HudLayout.renderedBody`. The background color is not an argument either in practice: the factory
    /// reads it at creation, so the LIVE panel's color is carried into the stored spec and `spec`'s own is
    /// dropped. Only a replacing `openHud` changes the color, and the read-back keeps naming what the panel
    /// actually paints. False with no HUD up, which is the only failure: `resizeOverlay` refuses an empty
    /// slot alone, and a live HUD occupies one.
    @discardableResult public func updateHud(_ sessionID: UUID, spec: HudSpec, size: HudPanelSize) -> Bool {
        guard let session = session(withID: sessionID), let live = session.hudSpec,
              session.hudActive else { return false }
        session.hudSpec = spec.withBackgroundColor(live.backgroundColor)
        session.hudHeightPercent = size.heightPercent
        resizeOverlay(sessionID, sizePercent: size.widthPercent)
        return true
    }

    /// Closes a HUD through the ordinary overlay teardown. Refused when the slot holds a caller's PROGRAM,
    /// so `session.hud.close` can never kill a running overlay. False with no HUD up.
    @discardableResult public func closeHud(_ sessionID: UUID) -> Bool {
        guard let session = session(withID: sessionID), session.hudActive else { return false }
        return closeOverlay(sessionID)
    }

    /// Opens a pane-scoped overlay covering `pane` only, leaving the sibling pane live and interactive.
    /// Behaves like `openOverlay` in every respect but geometry and scope: the surface is created lazily by
    /// the pane, `wait` holds it after the command exits, and `backgroundColor`/`cwd` are per-overlay, so
    /// two open at once carry their own. Always full-pane — no size percent. Returns nil on success, else
    /// the reason, so the control arm can pick its error string. NOT persisted.
    public func openPaneOverlay(_ sessionID: UUID, pane: OverlayPane, command: String, cwd: String? = nil,
                                wait: Bool = false,
                                backgroundColor: String? = nil) -> PaneOverlayOpenFailure? {
        guard let session = session(withID: sessionID) else { return .unknownSession }
        guard session.paneOverlay(pane) == nil else { return .alreadyOpen }
        // an unrendered pane never gets a nonzero backing size, so its surface would never be created and
        // the slot would sit active with no program — reject instead of opening a dead overlay.
        guard session.rendersPane(pane) else { return .paneNotVisible }
        session.setPaneOverlayExitCode(nil, pane: pane)
        session.setPaneOverlay(PaneOverlay(command: command, cwd: cwd, backgroundColor: backgroundColor,
                                           wait: wait), pane: pane)
        return nil
    }

    /// Records a pane overlay program's exit status so `session.overlay.result --pane` can report it after
    /// the overlay closes. No-op for an unknown id.
    public func recordPaneOverlayExit(_ sessionID: UUID, pane: OverlayPane, code: Int) {
        session(withID: sessionID)?.setPaneOverlayExitCode(code, pane: pane)
    }

    /// Closes a pane overlay: clears the slot AND tears down its surface — ephemeral like the session-wide
    /// overlay, never kept alive. The exit code SURVIVES, cleared only by the next open on that pane. Used
    /// on explicit close and when the program exits. No-op (false) with no overlay on that pane.
    @discardableResult public func closePaneOverlay(_ sessionID: UUID, pane: OverlayPane) -> Bool {
        guard let session = session(withID: sessionID), session.paneOverlay(pane) != nil else { return false }
        session.setPaneOverlay(nil, pane: pane)
        session.paneOverlaySurface(pane)?.teardown()
        session.setPaneOverlaySurface(nil, pane: pane)
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
