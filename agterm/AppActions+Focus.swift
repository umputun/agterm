import agtermCore
import AppKit
import SwiftUI

/// Session/pane focus mechanics split out of the main `AppActions` declaration: moving first responder into
/// the active session or a split pane, revealing a blocked or notification-clicked session's waiting pane,
/// and the modal guards (terminal zoom, dashboard overlay) that keep those moves off a hidden surface.
extension AppActions {
    // MARK: - Notification bridges

    /// Bridge for `.agtermAutoFollowed`: an idle auto-follow moved some window's selection to a blocked
    /// session. Selection alone does NOT move first responder (the eager deck keeps the prior surface), so
    /// pull focus in, but ONLY when the firing window is key — a non-key window keeps just the selection and
    /// focuses when it next becomes key, which is also what makes `revealActiveBlockedPane`'s frontmost (=
    /// key) store the firing window. It reveals the pane that set the status (split/scratch), so the jump
    /// lands on the waiting pane, not the plain focused one.
    func autoFollowed(_ sessionID: UUID?, indicator: AgentIndicator?) {
        guard let sessionID, let windowID = library.windowID(forSession: sessionID),
              WindowRegistry.shared.isKeyWindow(windowID) else { return }
        // never reveal behind the zoom layer: the reveal mutates scratch visibility / splitFocused, exactly
        // the hidden-state writes zoom forbids. the auto-follow SELECTION stands (the user lands on the
        // blocked session when they exit zoom); only the pane reveal is skipped.
        guard TerminalZoomRegistry.shared.controller(for: windowID)?.target == nil else { return }
        revealActiveBlockedPane(captured: indicator)
    }

    // MARK: - Modal focus guards

    /// Whether the frontmost window's dashboard grid overlay is open. Like a zoom or an open palette it is
    /// modal and its key-catcher owns first responder, so `focusActiveSession` must not grab the active
    /// session's surface while it is up (that surface is a view-only grid cell).
    private var dashboardActive: Bool {
        DashboardControllerRegistry.shared.controller(for: library.activeWindowID)?.isOpen == true
    }

    /// Whether the specified window has a native control picker pending. Kept as one window-scoped
    /// predicate so both frontmost and session-addressed focus paths use the same modal invariant.
    func pickActive(for windowID: WindowInfo.ID?) -> Bool {
        PickRegistry.shared.controller(for: windowID)?.pending != nil
    }

    /// Whether terminal zoom is active in the window OWNING this session — the right gate for the
    /// session-addressed focus paths, since control commands resolve sessions across ALL windows: gating on
    /// the FRONTMOST window's zoom would silently drop the focus step for an un-zoomed background window,
    /// and miss a zoomed non-frontmost one.
    private func terminalZoomActive(for session: Session) -> Bool {
        guard let windowID = library.windowID(forSession: session.id) else { return false }
        return TerminalZoomRegistry.shared.controller(for: windowID)?.target != nil
    }

    /// Whether the dashboard overlay is open in the window OWNING this session — the session-scoped twin of
    /// the frontmost `dashboardActive`, window-scoped for the same cross-window reason as
    /// `terminalZoomActive(for:)` (`focusSplitPane`'s callers can target ANY window). Unlike the frontmost
    /// case's grid cell, a NON-member deck surface behind the modal is NOT view-only, so grabbing first
    /// responder for it would steal keystrokes into a hidden terminal.
    private func dashboardActive(for session: Session) -> Bool {
        guard let windowID = library.windowID(forSession: session.id) else { return false }
        return DashboardControllerRegistry.shared.controller(for: windowID)?.isOpen == true
    }

    /// Whether `session` is selected in its OWN window. The deck mounts every session and only hides the
    /// unselected ones, so their surfaces still accept first responder and focusing one types into a
    /// terminal the user cannot see. Control reaches here on background targets; GUI callers select first.
    /// Unresolvable ownership does not block, like the window-scoped gates below.
    func sessionIsSelected(_ session: Session) -> Bool {
        guard let owner = library.store(forSession: session.id) else { return true }
        return owner.selectedSessionID == session.id
    }

    /// Whether the quick terminal is showing in the window OWNING this session — the session-scoped twin of
    /// `frontmostQuickTerminal`, window-scoped like `terminalZoomActive(for:)` since each window owns its own
    /// controller: gating on the frontmost would both drop the focus step for a background target (leaving
    /// its `splitFocused` and real first responder disagreeing) and miss a cover actually showing there.
    private func quickTerminalActive(for session: Session) -> Bool {
        guard let windowID = library.windowID(forSession: session.id) else { return false }
        return QuickTerminalRegistry.shared.controller(for: windowID)?.isVisible == true
    }

    // MARK: - Reveal & focus

    /// Reveal and focus the active session's blocked pane, reading its agent-status pane tag so navigation
    /// lands on the pane actually waiting for input, not the plain focused pane. Called on every user-initiated
    /// selection — auto-follow, attention nav (⌃⌥↑/↓), session nav (⌥⌘↑/↓/first/last), the ⌃P/attention
    /// palettes, a sidebar row click, a title-bar bell popover row, a Dock-menu session row — and a no-op
    /// (plain `focusActiveSession`) for an idle or active session, so ordinary selections and a working agent's
    /// informational pane tag never move the pane selection. `.right`, only when `splitSurface != nil`, flips
    /// `splitFocused` then focuses the split surface via `focusSplitPane(wantSplit: true)` — a FIXED target,
    /// NOT the `splitFocused`-following `focusActiveSession`: a SHOWN split's deck re-render churns first
    /// responder onto the main pane, whose `onFocusChange` writes `splitFocused = false`, so a follow-the-flag
    /// target chases the wrong pane while re-asserting the split surface wins the race (its `onFocusChange`
    /// re-sets true). The gate is `splitSurface != nil`, NOT `hasSplit`, so a promoted split survivor
    /// (`closePrimaryPane` re-tags its `.right` block to `.left`) and a STALE `right` tag on a single-pane
    /// session (a manual `session.status --pane right`, or a collapsed split) both target the sole main pane
    /// instead of setting `splitFocused = true` with no split surface — true only while the split pane exists.
    /// `.scratch` shows the scratch only when hidden (never a bare toggle, which could HIDE a shown one) so
    /// `topmostSurface` resolves to it; `.left`/nil clear `splitFocused` and target the primary even when the
    /// right pane held focus before selection, the retry loops covering a surface materializing a beat later.
    /// Inversely, a NON-scratch target with the scratch SHOWN hides it (keep-alive `toggleScratch`) FIRST, or
    /// both focus paths resolve to it as `topmostSurface` and nav never reaches the blocked pane; only the
    /// scratch cover is dismissed — closing a running overlay would kill its program. Callers pass the
    /// indicator from `AppStore.selectSession`/`navigateSession`, captured before either clears an `autoReset`
    /// status, so pane routing is identical across every entry point.
    func revealActiveBlockedPane(captured indicator: AgentIndicator?) {
        guard let indicator else { focusActiveSession(); return }
        guard let session = store?.activeSession else { focusActiveSession(); return }
        // a no-op unless the status needs attention: the scratch-hide / split-focus side effects must never
        // fire on plain navigation to a still-active session, or one merely showing its keep-alive scratch.
        guard indicator.status.needsAttention else { focusActiveSession(); return }
        let pane = indicator.statusPane
        // a shown scratch masks a non-scratch block; overlays are deliberately left alone.
        if pane != .scratch, session.scratchActive { store?.toggleScratch(session.id) }
        switch pane {
        case .right where session.splitSurface != nil:
            session.splitFocused = true
            focusSplitPane(session, wantSplit: true)
        case .scratch:
            if !session.scratchActive { store?.toggleScratch(session.id) }
            focusActiveSession()
        case .left, .right, .none:
            session.splitFocused = false
            focusSplitPane(session, wantSplit: false)
        }
    }

    /// Move first responder back to the active session's topmost surface (after the quick terminal or a
    /// palette/rename field closes). Targets `topmostSurface` (overlay > scratch > active pane), so a close
    /// re-focuses whatever is actually visible and never a pane hidden under a cover, and re-asserts briefly
    /// since the target view may not be on-window yet. Bails only for the quick terminal: a window-level
    /// cover that owns focus and re-focuses the session on its own hide.
    func focusActiveSession(attempt: Int = 0) {
        if terminalZoomActive { return }
        if dashboardActive { return }
        if renamePending { return }
        // never grab terminal focus while a palette is open — it owns the keyboard. this also kills the retry
        // loop the instant a palette (re)opens, so the "Select Theme…" launcher (which closes the action
        // palette, then opens the .themes picker a tick later) keeps its field focus.
        if palette?.mode != nil { return }
        if pickActive(for: library.activeWindowID) { return }
        if frontmostQuickTerminal?.isVisible == true { return }
        if let view = store?.activeSession?.topmostSurface as? GhosttySurfaceView, let window = view.window {
            window.makeFirstResponder(view)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focusActiveSession(attempt: attempt + 1)
        }
    }

    /// Move first responder to the split (right) pane on open, or the primary on close, re-asserting over a
    /// short window because the split surface materializes a beat after the toggle and the HSplitView
    /// collapse churns the primary view. `Session.focusTarget(wantSplit:)` owns the cover routing: a
    /// full-coverage scratch/overlay keeps focus on the visible `topmostSurface`, and a pane overlay takes it
    /// for the pane it covers. Either way the caller's `splitFocused` stands, so the right pane shows once
    /// the cover is gone.
    func focusSplitPane(_ session: Session, wantSplit: Bool, attempt: Int = 0, generation: Int? = nil) {
        // each fresh call SUPERSEDES any in-flight retry loop in the SAME WINDOW: otherwise two calls with
        // opposite targets each run their own 12x30ms `makeFirstResponder` loop, ping-ponging first responder
        // between the panes for ~400ms and redrawing both surfaces per flip (the split-focus flicker). keyed
        // by the owning WINDOW — one NSWindow has one first responder, so a newer focus op supersedes an
        // older loop (last-focus-wins) while other windows never cancel each other's still-materializing
        // retries. the survivor still re-asserts through the split-materialize / reparent churn, a no-op
        // once its target holds focus.
        let gen: Int
        let scope = library.windowID(forSession: session.id) ?? session.id // fall back to session id when windowless
        if let generation {
            guard generation == focusGeneration[scope] else { return } // superseded by a newer op in this window
            gen = generation
        } else {
            gen = (focusGeneration[scope] ?? 0) + 1
            focusGeneration[scope] = gen
        }
        if terminalZoomActive(for: session) { return }
        if dashboardActive(for: session) { return }
        if pickActive(for: library.windowID(forSession: session.id)) { return }
        if !sessionIsSelected(session) { return }
        // the inline rename field and an open palette own the keyboard. this loop needs the gate because the
        // `.left`/nil reveal routes here (a plain `session status blocked` with no `--pane`), so a sidebar
        // row click followed inside the ~360ms retry window by ⌘R or a palette open would pull first
        // responder off the field and type the name into the terminal. SCOPED to the session's own window
        // like the two gates above: both flags are app-GLOBAL (one `renamePending`, one `PaletteController`
        // shared by every window), so unscoped a frontmost palette would silently skip the responder move
        // for a `session.focus` aimed at a background window, leaving its `splitFocused` and real first
        // responder disagreeing while the control command still reports ok. scoping is safe because only the
        // KEY window receives keystrokes — a background window can still hold an inline editor (rename
        // notifications fan out to every sidebar coordinator), but nobody types into it, a separate defect.
        if library.windowID(forSession: session.id) == library.activeWindowID {
            if renamePending { return }
            if palette?.mode != nil { return }
        }
        // the quick terminal is a window-level cover that owns focus; its own hide restores the session.
        if quickTerminalActive(for: session) { return }
        if let view = session.focusTarget(wantSplit: wantSplit) as? GhosttySurfaceView, let window = view.window {
            window.makeFirstResponder(view)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focusSplitPane(session, wantSplit: wantSplit, attempt: attempt + 1, generation: gen)
        }
    }

    /// Bring a session/pane to the foreground from a notification click: surface the owning window (reopening
    /// a closed one), select the session (clearing its unseen badge and deriving its workspace), and focus
    /// the firing pane. Stale-safe: a session in an open window resolves directly, an unknown window/session
    /// leaves the app active (the caller has activated it), and a `.split` pane that is no longer split falls
    /// back to the primary.
    func reveal(windowID: UUID, sessionID: UUID, pane: PaneRole) {
        if let store = library.store(forSession: sessionID) {
            revealSession(sessionID, pane: pane, in: store)
            return
        }
        // window closed: reopen it, then select once its store has loaded (the surface materializes a beat
        // after the window appears, so retry like `focusSplitPane` does).
        guard library.windows.contains(where: { $0.id == windowID }) else { return }
        openWindow?(windowID)
        revealAfterOpen(windowID: windowID, sessionID: sessionID, pane: pane)
    }

    /// Polls for a reopened window's store to load, then reveals the session. Bounded, so a stale id (the
    /// window never materializes) gives up instead of looping forever.
    private func revealAfterOpen(windowID: UUID, sessionID: UUID, pane: PaneRole, attempt: Int = 0) {
        if let store = library.store(for: windowID), store.session(withID: sessionID) != nil {
            revealSession(sessionID, pane: pane, in: store)
            return
        }
        guard attempt < 30 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.revealAfterOpen(windowID: windowID, sessionID: sessionID, pane: pane, attempt: attempt + 1)
        }
    }

    private func revealSession(_ sessionID: UUID, pane: PaneRole, in store: AppStore) {
        guard let session = store.session(withID: sessionID) else { return }
        let windowID = library.windowID(forSession: session.id)
        // a banner click is an explicit "take me there", so exit a zoomed owning window first, or the
        // selection changes behind the opaque zoom layer and the click looks dead (every other UI entry point
        // is gated or exits zoom).
        if let windowID, let zoom = TerminalZoomRegistry.shared.controller(for: windowID), zoom.target != nil {
            zoom.clear()
        }
        // raise the owning window, which `makeFirstResponder` does not: `NSApp.activate` in the notification
        // handler brings the APP forward, not a window minimized to the Dock or behind another, so the
        // selection would change invisibly. the closed-window branch already raises via `openWindow`.
        if let windowID { WindowRegistry.shared.raise(windowID) }
        // a banner click is a user-initiated selection: note activity on the SAME (owning) store it selects
        // into — reveal can cross windows — so it buys the full idle grace before auto-follow pulls away.
        store.noteUserActivity()
        store.selectSession(session.id)
        let wantSplit = pane == .split && session.hasSplit
        session.splitFocused = wantSplit
        focusSplitPane(session, wantSplit: wantSplit)
    }
}
