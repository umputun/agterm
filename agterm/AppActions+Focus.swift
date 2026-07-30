import agtermCore
import AppKit
import SwiftUI

/// Session/pane focus mechanics split out of the main `AppActions` declaration: moving first responder into
/// the active session or a split pane, revealing a blocked or notification-clicked session's waiting pane,
/// and the modal guards (terminal zoom, dashboard overlay) that keep those moves off a hidden surface.
extension AppActions {
    // MARK: - Notification bridges

    /// Bridge for `.agtermAutoFollowed`: an idle auto-follow has moved some window's selection to a blocked
    /// session. Selection alone does NOT move first responder (the eager deck keeps the prior surface), so
    /// pull focus into the newly selected session, but ONLY when the firing window is key — a non-key window
    /// keeps just the selection and focuses when it next becomes key. `revealActiveBlockedPane` targets the
    /// frontmost (= key) store, the firing window given that gate, and reveals the pane that set the status
    /// (split/scratch), so the jump lands on the waiting pane, not the session's plain focused pane.
    func autoFollowed(_ sessionID: UUID?, indicator: AgentIndicator?) {
        guard let sessionID, let windowID = library.windowID(forSession: sessionID),
              WindowRegistry.shared.isKeyWindow(windowID) else { return }
        // never reveal behind the zoom layer: the reveal mutates scratch visibility / splitFocused,
        // exactly the hidden-state writes zoom forbids. The auto-follow SELECTION stands (the user
        // lands on the blocked session when they exit zoom); only the pane reveal is skipped.
        guard TerminalZoomRegistry.shared.controller(for: windowID)?.target == nil else { return }
        revealActiveBlockedPane(captured: indicator)
    }

    // MARK: - Modal focus guards

    /// Whether the frontmost window's dashboard grid overlay is open. Like a zoom or an open palette, the
    /// dashboard is modal and its key-catcher owns first responder, so `focusActiveSession` must not grab
    /// the active session's surface while it is up (that surface is a view-only grid cell).
    private var dashboardActive: Bool {
        DashboardControllerRegistry.shared.controller(for: library.activeWindowID)?.isOpen == true
    }

    /// Whether the specified window has a native control picker pending. Kept as one window-scoped
    /// predicate so both frontmost and session-addressed focus paths use the same modal invariant.
    func pickActive(for windowID: WindowInfo.ID?) -> Bool {
        PickRegistry.shared.controller(for: windowID)?.pending != nil
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
    /// the frontmost `dashboardActive`, mirroring `terminalZoomActive(for:)` and gating on the session's
    /// window for the same cross-window reason. `focusSplitPane`'s callers (⌃1/⌃2, ⌘D, the control
    /// `session.focus --pane`) can target ANY window, and while that window's dashboard is up its
    /// key-catcher owns first responder while a NON-member deck surface behind the modal is NOT view-only,
    /// so grabbing first responder for it would steal keystrokes into a hidden terminal.
    private func dashboardActive(for session: Session) -> Bool {
        guard let windowID = library.windowID(forSession: session.id) else { return false }
        return DashboardControllerRegistry.shared.controller(for: windowID)?.isOpen == true
    }

    /// Whether the quick terminal is showing in the window OWNING this session — the session-scoped twin of
    /// `frontmostQuickTerminal`, completing the set with `terminalZoomActive(for:)`/`dashboardActive(for:)`.
    /// Each window owns its own controller, so the FRONTMOST one is the wrong question for `focusSplitPane`:
    /// a cover in the frontmost window would drop the focus step for a `session.focus --pane` aimed at a
    /// BACKGROUND one (leaving that window's `splitFocused` and its real first responder disagreeing), while
    /// a cover actually showing there — the one that does own its focus — would be missed.
    private func quickTerminalActive(for session: Session) -> Bool {
        guard let windowID = library.windowID(forSession: session.id) else { return false }
        return QuickTerminalRegistry.shared.controller(for: windowID)?.isVisible == true
    }

    // MARK: - Reveal & focus

    /// Reveal and focus the active session's blocked pane, reading its agent-status pane tag so navigation
    /// lands on the pane actually waiting for input rather than the session's plain focused pane. Called on
    /// every user-initiated selection — the auto-follow jump, attention nav (⌃⌥↑/↓), plain session nav
    /// (⌥⌘↑/↓/first/last), the ⌃P / attention palette, a sidebar row click, a title-bar bell popover row, a
    /// Dock-menu session row — and a no-op (plain `focusActiveSession`) for an idle or active session, so
    /// ordinary selections and a working agent's informational pane tag never move the pane selection.
    /// `.right`, only when `splitSurface != nil`, flips `splitFocused` then focuses the split surface via
    /// `focusSplitPane(wantSplit: true)` — a FIXED target, NOT the `splitFocused`-following
    /// `focusActiveSession`: a SHOWN (side-by-side) split's deck re-render churns first responder onto the
    /// main pane, whose `onFocusChange` writes `splitFocused = false`, so a follow-the-flag target chases the
    /// wrong pane while re-asserting the split surface wins the race (its `onFocusChange` re-sets true). The
    /// gate is `splitSurface != nil`, NOT `hasSplit`, so a promoted split survivor (`closePrimaryPane` moves
    /// it into `surface` with `splitSurface == nil`, re-tagging a `.right` block to `.left`) and a STALE
    /// `right` tag on a genuinely single-pane session (a manual `session.status --pane right`, or a collapsed
    /// split) both target the sole main pane instead of setting `splitFocused = true` with no split surface —
    /// the invariant is "true only while the split pane exists". `.scratch` shows the scratch only when
    /// hidden (a show-if-hidden guard, never a bare toggle that could HIDE a shown one) so `topmostSurface`
    /// resolves to it; `.left`/nil clear `splitFocused` and target the primary surface even when the right
    /// pane held focus before selection, and the retry loops cover a split/scratch surface materializing a
    /// beat later. Inversely, a NON-scratch target (`left`/`right`/nil) with the scratch SHOWN hides the
    /// covering scratch (keep-alive `toggleScratch`) FIRST, or `focusSplitPane`/`focusActiveSession` both
    /// resolve to it as `topmostSurface` and nav never reaches the blocked pane; only the scratch cover is
    /// dismissed, since closing a running overlay would kill its program. Selection callers pass the
    /// indicator from `AppStore.selectSession`/`navigateSession`, captured before either clears an
    /// `autoReset` status, so pane routing is identical across the Dock, nav, palettes, clicks, and auto-follow.
    func revealActiveBlockedPane(captured indicator: AgentIndicator?) {
        guard let indicator else { focusActiveSession(); return }
        guard let session = store?.activeSession else { focusActiveSession(); return }
        // a no-op unless the status needs attention: the scratch-hide / split-focus side effects must never
        // fire on plain navigation to a session merely showing its keep-alive scratch, or still active. a
        // needs-attention status with no `--pane` tag counts as `left` and still reveals the main pane.
        guard indicator.status.needsAttention else { focusActiveSession(); return }
        let pane = indicator.statusPane
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
            session.splitFocused = false
            focusSplitPane(session, wantSplit: false)
        }
    }

    /// Move first responder back to the active session's topmost surface (after the quick terminal or a
    /// palette/rename field closes). Targets `topmostSurface` (overlay > scratch > active pane), so a close
    /// re-focuses whatever is actually visible — the scratch or overlay if one is up, else the focused pane
    /// — never a pane hidden under a cover, and re-asserts briefly since the target view may not be
    /// on-window yet. Bails only for the quick terminal: a window-level cover that owns focus and re-focuses
    /// the session on its own hide.
    func focusActiveSession(attempt: Int = 0) {
        if terminalZoomActive { return }
        if dashboardActive { return }
        if renamePending { return }
        // never grab terminal focus while a command palette is open — it owns the keyboard. this also kills
        // the retry loop the instant a palette (re)opens, so the action-palette "Select Theme…" launcher
        // (which closes that palette, then opens the .themes picker a tick later) keeps its field focus.
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
    /// collapse churns the primary view. Under a full-coverage surface (scratch or overlay) the requested
    /// pane is hidden, so keep first responder on the visible `topmostSurface` — the caller has already set
    /// `splitFocused`, so the correct pane shows once the cover is dismissed.
    func focusSplitPane(_ session: Session, wantSplit: Bool, attempt: Int = 0, generation: Int? = nil) {
        // each fresh call SUPERSEDES any in-flight retry loop in the SAME WINDOW: without this, two calls
        // with opposite targets each run their own 12x30ms `makeFirstResponder` loop, ping-ponging first
        // responder between the panes for ~400ms and redrawing both surfaces per flip (the split-focus
        // flicker). the counter is keyed by the owning WINDOW — one NSWindow has one first responder, so a
        // newer focus op there supersedes an older loop (last-focus-wins) while other windows stay
        // independent and never cancel each other's still-materializing retries. the surviving loop still
        // re-asserts through the split-materialize / reparent churn, its re-asserts being no-ops once its
        // target holds focus.
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
        // the inline rename field and an open palette own the keyboard, as in `focusActiveSession`, which
        // re-checks both on every retry; this loop needs it because the `.left`/nil reveal routes here (a
        // plain `session status blocked` with no `--pane`), so a sidebar row click followed inside the
        // ~360ms retry window by ⌘R or a palette open would pull first responder off the field and type the
        // name into the terminal. SCOPED to the session's own window like the two gates above, for the same
        // cross-window reason: both flags are app-GLOBAL (one `renamePending`, one `PaletteController`
        // shared by every window), so unscoped a frontmost palette would silently skip the responder move
        // for a `session.focus` aimed at a background window, leaving its `splitFocused` and real first
        // responder disagreeing while the control command still reports ok. scoping costs nothing — only
        // the KEY window receives keystrokes, so the race guarded here (a retry stealing the field being
        // typed into) is frontmost-only. a BACKGROUND window can still hold an inline editor, since rename
        // notifications fan out to every window's sidebar coordinator, but nobody types into it and that
        // fan-out is a separate, older defect.
        if library.windowID(forSession: session.id) == library.activeWindowID {
            if renamePending { return }
            if palette?.mode != nil { return }
        }
        // the quick terminal is a window-level cover above the session; while it's up it owns focus, so
        // don't move first responder to a pane behind it (its own hide restores the session). The caller
        // has already set `splitFocused`, so the right pane shows once the quick terminal is dismissed.
        if quickTerminalActive(for: session) { return }
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
    /// (reopening it when the banner was clicked after the window closed), select the session (clearing its
    /// unseen badge and deriving its workspace), and focus the firing pane. Stale-safe: an unknown session
    /// in an open window resolves directly, an unknown window/session leaves the app active (the caller has
    /// activated it), and a `.split` pane that is no longer split falls back to the primary.
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
        let windowID = library.windowID(forSession: session.id)
        // a banner click is an explicit "take me there": if the owning window is zoomed, exit zoom
        // first so the reveal is visible — otherwise the selection change happens behind the opaque
        // zoom layer and the click looks dead (every other UI entry point is gated or exits zoom).
        if let windowID, let zoom = TerminalZoomRegistry.shared.controller(for: windowID), zoom.target != nil {
            zoom.clear()
        }
        // raise the owning window, which `makeFirstResponder` alone does not do: `NSApp.activate` in the
        // notification handler brings the APP forward, not a window minimized to the Dock or behind another,
        // so the selection would change invisibly. the closed-window branch already raises via `openWindow`.
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
