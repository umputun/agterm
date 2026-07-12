import agtermCore
import AppKit
import SwiftUI

/// Session/pane focus mechanics for `AppActions`: moving first responder into the active session or a
/// split pane, revealing a blocked or notification-clicked session's waiting pane, and the modal guards
/// (terminal zoom and the dashboard overlay) that keep those focus moves off a hidden surface. Split out
/// of the main `AppActions` declaration to keep each file focused; an extension on the same type reaches
/// all of its members.
extension AppActions {
    // MARK: - Modal focus guards

    /// Whether the frontmost window's dashboard grid overlay is open. Like a zoom or an open palette, the
    /// dashboard is modal and its key-catcher owns first responder, so `focusActiveSession` must not grab
    /// the active session's surface while it is up (that surface is a view-only grid cell).
    private var dashboardActive: Bool {
        DashboardControllerRegistry.shared.controller(for: library.activeWindowID)?.isOpen == true
    }

    /// Whether terminal zoom is active in the window OWNING this session. The right gate for the
    /// session-addressed focus paths: control commands resolve sessions across ALL windows, so gating
    /// them on the FRONTMOST window's zoom would silently drop the focus step for an un-zoomed
    /// background window (and miss a zoomed non-frontmost one).
    private func terminalZoomActive(for session: Session) -> Bool {
        guard let windowID = library.windowID(forSession: session.id) else { return false }
        return TerminalZoomRegistry.shared.controller(for: windowID)?.target != nil
    }

    /// Whether the dashboard overlay is open in the window OWNING this session — the session-scoped twin of
    /// the frontmost `dashboardActive`, mirroring `terminalZoomActive(for:)`. The right gate for
    /// `focusSplitPane`, whose callers (⌃1/⌃2, ⌘D, the control `session.focus --pane`) can target a session
    /// in ANY window: while that window's dashboard is up its key-catcher owns first responder, and a
    /// NON-member deck surface behind the modal is NOT view-only, so grabbing first responder for it would
    /// steal keystrokes from the catcher into a hidden terminal. Gates on the session's window, not the
    /// frontmost one, for the same cross-window reason as `terminalZoomActive(for:)`.
    private func dashboardActive(for session: Session) -> Bool {
        guard let windowID = library.windowID(forSession: session.id) else { return false }
        return DashboardControllerRegistry.shared.controller(for: windowID)?.isOpen == true
    }

    // MARK: - Reveal & focus

    /// Reveal and focus the active session's blocked pane, reading its agent-status pane tag so navigation
    /// lands on the pane actually waiting for input rather than the session's plain focused pane. Called on
    /// every user-initiated selection — the auto-follow jump, attention navigation (⌃⌥↑/↓), plain session
    /// nav (⌥⌘↑/↓/first/last), the ⌃P / attention command palette, and a sidebar row click — so however you
    /// reach a blocked session you land on its waiting pane; it is a no-op (plain `focusActiveSession`) for an
    /// IDLE session (no status set), so ordinary selections are unaffected. `.right` — only WHEN the
    /// split surface exists
    /// (`splitSurface != nil`) — flips `splitFocused` then focuses the split surface via
    /// `focusSplitPane(wantSplit: true)` — a FIXED target, NOT the `splitFocused`-following
    /// `focusActiveSession`: a SHOWN (side-by-side) split's deck re-render churns first responder onto the
    /// main pane, whose `onFocusChange` writes `splitFocused = false`, and a follow-the-flag focus target
    /// then chases the wrong pane; re-asserting the split surface directly wins the race (its `onFocusChange`
    /// re-sets `splitFocused = true`). The gate is `splitSurface != nil` (NOT `hasSplit`), so a promoted
    /// split survivor (which `closePrimaryPane` moves into `surface` with `splitSurface == nil`, re-tagging a
    /// `.right` block to `.left`) falls through to `focusActiveSession` as the session's sole main pane, and
    /// a STALE `right` tag on a genuinely single-pane session (a manual `session.status --pane right`, or
    /// after the split collapsed) does the same, instead of setting `splitFocused = true` with no split
    /// surface (the `splitFocused` invariant is "true only while the split pane exists"). `.scratch` shows the
    /// scratch only when hidden (a show-if-hidden guard, never a bare toggle that could HIDE a shown one) so
    /// `topmostSurface` resolves to the scratch; `.left`/nil focus the session's current active surface via
    /// `focusActiveSession` (the main pane unless a split is focused — no forced flip). The retry loops
    /// cover a split/scratch surface that materializes a beat after the reveal.
    /// The INVERSE of the `.scratch` show-if-hidden guard: for a NON-scratch target (`left`/`right`/nil)
    /// with the scratch currently SHOWN, hide the covering scratch (keep-alive `toggleScratch`) FIRST so the
    /// requested pane becomes the visible/topmost surface — otherwise `focusSplitPane`/`focusActiveSession`
    /// both resolve to the covering scratch (`topmostSurface`) and nav never reaches the blocked pane. Only
    /// the scratch cover is dismissed; an active overlay is left alone (closing a running overlay would kill
    /// its program).
    func revealActiveBlockedPane() {
        guard let session = store?.activeSession else { focusActiveSession(); return }
        // reveal is a no-op for an IDLE session: with no status there is nothing to reveal, and the
        // scratch-hide / split-focus side effects below must never fire on plain navigation to a session
        // that merely has its (keep-alive) scratch shown. a non-idle block with no `--pane` tag is treated
        // as `left` and still reveals the main pane (hiding a covering scratch).
        guard session.agentIndicator.status != .idle else { focusActiveSession(); return }
        let pane = session.agentIndicator.statusPane
        // a shown scratch covers the panes and masks a non-scratch block; hide it first so the requested
        // pane is revealed. overlays are deliberately not touched — closing a running overlay is destructive.
        if pane != .scratch, session.scratchActive { store?.toggleScratch(session.id) }
        switch pane {
        case .right where session.splitSurface != nil:
            session.splitFocused = true
            focusSplitPane(session, wantSplit: true)
        case .scratch:
            if !session.scratchActive { store?.toggleScratch(session.id) }
            focusActiveSession()
        case .left, .right, .none:
            focusActiveSession()
        }
    }

    /// Move first responder back to the active session's topmost surface (used after the quick terminal
    /// or a palette/rename field closes). Targets `topmostSurface` (overlay > scratch > active pane) so a
    /// palette close re-focuses whatever is actually visible — the scratch or overlay if one is up, else
    /// the focused pane — never a pane hidden under a cover. Re-asserts briefly since the target view may
    /// not be on-window yet. Bails only for the quick terminal: it is a window-level cover that owns focus
    /// and re-focuses the session on its own hide, so don't fight it here.
    func focusActiveSession(attempt: Int = 0) {
        if terminalZoomActive { return }
        if dashboardActive { return }
        if renamePending { return }
        // never grab terminal focus while a command palette is open — the palette owns the keyboard.
        // this also kills the retry loop the instant a palette (re)opens, so the action-palette "Select
        // Theme…" launcher (which closes the action palette, then opens the .themes picker a tick later)
        // can't have its field focus stolen back by the close-restore's retry.
        if palette?.mode != nil { return }
        if frontmostQuickTerminal?.isVisible == true { return }
        if let view = store?.activeSession?.topmostSurface as? GhosttySurfaceView, let window = view.window {
            window.makeFirstResponder(view)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focusActiveSession(attempt: attempt + 1)
        }
    }

    /// Move first responder to the split (right) pane on open, or the primary on close.
    /// Re-asserts over a short window because the split surface materializes a beat after the
    /// toggle and the HSplitView collapse churns the primary view. While a full-coverage surface
    /// (scratch or overlay) is up, the requested pane is hidden beneath it, so keep first responder on
    /// the visible `topmostSurface` instead — the caller has already set `splitFocused`, so the correct
    /// pane shows once the cover is dismissed.
    func focusSplitPane(_ session: Session, wantSplit: Bool, attempt: Int = 0, generation: Int? = nil) {
        // each fresh call SUPERSEDES any in-flight retry loop in the SAME WINDOW. without this, two calls
        // with opposite targets (focus-left then focus-right) each run their own 12x30ms
        // `makeFirstResponder` loop concurrently and ping-pong first responder between the panes for
        // ~400ms - both surfaces redraw on every flip, the split-focus flicker. the counter is keyed by the
        // owning WINDOW: one NSWindow has one first responder, so a newer focus op anywhere in it supersedes
        // an older loop there (last-focus-wins), while different windows stay independent (never cancel each
        // other's still-materializing retries). the surviving loop still re-asserts through the
        // split-materialize / reparent churn (a lone loop's re-asserts are no-ops once its target is first
        // responder), so the retry keeps its original purpose.
        let gen: Int
        let scope = library.windowID(forSession: session.id) ?? session.id // fall back to session id when windowless
        if let generation {
            guard generation == focusGeneration[scope] else { return } // superseded by a newer op in this window
            gen = generation
        } else {
            gen = (focusGeneration[scope] ?? 0) + 1
            focusGeneration[scope] = gen
        }
        // gate on the SESSION's window, not the frontmost one: this path is cross-window (the control
        // channel focuses sessions in background windows), where the frontmost window's zoom is irrelevant.
        if terminalZoomActive(for: session) { return }
        // the dashboard grid overlay is modal too, and gated on the SESSION's window for the same cross-window
        // reason: while it's up its key-catcher owns first responder, and a NON-member deck surface behind it
        // is not view-only, so grabbing first responder here would leak keystrokes into a hidden terminal.
        if dashboardActive(for: session) { return }
        // the quick terminal is a window-level cover above the session; while it's up it owns focus, so
        // don't move first responder to a pane behind it (its own hide restores the session). The caller
        // has already set `splitFocused`, so the right pane shows once the quick terminal is dismissed.
        if frontmostQuickTerminal?.isVisible == true { return }
        let target: (any TerminalSurface)? = (session.overlayActive || session.scratchActive)
            ? session.topmostSurface
            : (wantSplit ? session.splitSurface : session.surface)
        if let view = target as? GhosttySurfaceView, let window = view.window {
            window.makeFirstResponder(view)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focusSplitPane(session, wantSplit: wantSplit, attempt: attempt + 1, generation: gen)
        }
    }

    /// Bring a session/pane to the foreground from a notification click: surface the owning window
    /// (reopening it when the banner was clicked after the window closed), select the session (which
    /// clears its unseen badge and derives its workspace), and focus the firing pane. Stale-safe: an
    /// unknown session in an open window resolves directly; an unknown window/session just leaves the
    /// app active (the caller has already activated it). A `.split` pane that is no longer split
    /// falls back to the primary.
    func reveal(windowID: UUID, sessionID: UUID, pane: PaneRole) {
        // window already open: select + focus right away.
        if let store = library.store(forSession: sessionID) {
            revealSession(sessionID, pane: pane, in: store)
            return
        }
        // window closed: reopen it, then select once its store has loaded (the surface materializes
        // a beat after the window appears, so retry like focusSplitPane does).
        guard library.windows.contains(where: { $0.id == windowID }) else { return }
        openWindow?(windowID)
        revealAfterOpen(windowID: windowID, sessionID: sessionID, pane: pane)
    }

    /// Polls for a reopened window's store to load, then reveals the session. Bounded so a stale id
    /// (the window never materializes) gives up instead of looping forever.
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

    /// Selects a session in its owning store and focuses the firing pane.
    private func revealSession(_ sessionID: UUID, pane: PaneRole, in store: AppStore) {
        guard let session = store.session(withID: sessionID) else { return }
        // a banner click is an explicit "take me there": if the owning window is zoomed, exit zoom
        // first so the reveal is visible — otherwise the selection change happens behind the opaque
        // zoom layer and the click looks dead (every other UI entry point is gated or exits zoom).
        if let windowID = library.windowID(forSession: session.id),
           let zoom = TerminalZoomRegistry.shared.controller(for: windowID), zoom.target != nil {
            zoom.clear()
        }
        // clicking a notification banner is a user-initiated selection: note activity on the SAME (owning)
        // store it selects into — reveal can cross windows — so it buys the full idle grace before
        // auto-follow can pull the selection away.
        store.noteUserActivity()
        store.selectSession(session.id)
        let wantSplit = pane == .split && session.hasSplit
        session.splitFocused = wantSplit
        focusSplitPane(session, wantSplit: wantSplit)
    }
}
