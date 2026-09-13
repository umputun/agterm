import agtermCore
import AppKit

/// `AppActions` navigation: stepping the selection, the current workspace, and the open windows, plus the
/// attention-only session walk. Split out for the swiftlint size limit. Each level delegates its arithmetic
/// to the host-free step its control twin also calls, so menu, palette and `agtermctl` cannot drift.
extension AppActions {
    /// Step the selection prev/next/first/last in the sidebar's flattened visual order, through shared
    /// `navigateSession` so GUI, palette and control can't drift, then `selectSession`
    /// (recency/badge/persist/workspace) and first responder into the moved-to session's focused pane. Notes
    /// the manual nav as user activity for the full idle grace against auto-follow; control `session.go`
    /// drives `navigateSession` directly and stays silent. A step landing on the ALREADY-selected session only
    /// re-focuses (next/previous wrap inside the filtered set, first/last repeat at that end): `selectSession`
    /// still returns an indicator for a same-target select, and revealing on it would clear `splitFocused` and
    /// yank first responder onto the primary pane, off the split being typed in. Attention nav DOES reveal.
    private func navigatePlain(_ direction: SessionNavigation) {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        let before = store?.selectedSessionID
        // no live-indicator fallback (unlike attention nav): a plain direction returns nil only when
        // `navigableSessions` is EMPTY, and then nothing was selected, which the moved-check below catches.
        let indicator = store?.navigateSession(direction)
        guard store?.selectedSessionID != before else { focusActiveSession(); return }
        revealActiveBlockedPane(captured: indicator)
    }

    func selectNextSession() { navigatePlain(.next) }
    func selectPreviousSession() { navigatePlain(.previous) }
    func selectFirstSession() { navigatePlain(.first) }
    func selectLastSession() { navigatePlain(.last) }

    /// Step the CURRENT workspace prev/next through the sidebar's visible order and select its first session,
    /// through shared `navigateWorkspace` so the menu, the palette and `workspace.go` can't drift. Notes the
    /// step as user activity like session nav, then routes pane reveal off the step's captured indicator —
    /// the same treatment plain session nav gives, so where focus lands does not depend on which keystroke
    /// got you there. A step with nowhere to go (flagged mode, one visible workspace) leaves focus alone.
    private func navigateWorkspace(_ direction: WorkspaceNavigation) {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        guard let step = store?.navigateWorkspace(direction) else { return }
        revealActiveBlockedPane(captured: step.indicator)
    }

    func selectNextWorkspace() { navigateWorkspace(.next) }
    func selectPreviousWorkspace() { navigateWorkspace(.previous) }

    /// Step to the next/previous OPEN window in library order and raise it, through shared
    /// `library.navigateWindow` so the menu, the palette and `window.go` can't drift. `WindowRegistry.raise`,
    /// never the `openWindow` hub: on a failed raise that hub enqueues a claim and opens a fresh scene, and
    /// the failure here is an open window still attaching, which would give one store two scenes. The step is
    /// dropped in that sub-second gap instead.
    private func navigateWindow(_ direction: WorkspaceNavigation) {
        guard uiActionsEnabled else { return }
        guard let target = library.navigateWindow(direction), WindowRegistry.shared.raise(target) else { return }
        takeFrontmost(target)
    }

    func selectNextWindow() { navigateWindow(.next) }
    func selectPreviousWindow() { navigateWindow(.previous) }

    /// Publish `id` as frontmost after an imperative raise, since `WindowAccessor.reportFrontmost` fires on
    /// `didBecomeKey` and a step from the quick terminal raises with agterm INACTIVE — leaving the id stale,
    /// so every later step recomputes from the same origin. The control twin omits the post below, its
    /// dispatch refreshing that cache inline.
    func takeFrontmost(_ id: WindowInfo.ID) {
        guard library.frontmostWindowID != id else { return }
        library.frontmostWindowID = id
        library.saveIndex()
        if GhosttyApp.shared.autoHideSidebarInactiveWindows { library.applyInactiveWindowSidebarHiding() }
        NotificationCenter.default.post(name: .agtermWindowFrontmostChanged, object: nil)
    }

    /// Step to the next/previous session needing attention (`blocked`/`completed`), wrapping and skipping
    /// idle/active, through `navigateSession` shared with the palette and `session.go next-attention|prev-attention`.
    /// Notes user activity like plain nav, then `revealActiveBlockedPane` focuses the split/scratch pane that
    /// SET the status. Unlike plain nav this DOES reveal on a selection no-op, and only the
    /// `?? activeSession?.agentIndicator` fallback makes it: `attentionTarget` EXCLUDES the current session,
    /// so when the sole session needing attention is the selected one, `navigateSession` selects nothing.
    /// Without the fallback the reveal degrades to plain `focusActiveSession` and ⌃⌥↑/↓ stops landing on that
    /// session's tagged pane — constant for an agent, since a pane-scoped block is not cleared by typing in
    /// the OTHER pane. Keep it.
    func selectNextAttentionSession() {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        let indicator = store?.navigateSession(.nextAttention) ?? store?.activeSession?.agentIndicator
        revealActiveBlockedPane(captured: indicator)
    }
    func selectPreviousAttentionSession() {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        let indicator = store?.navigateSession(.previousAttention) ?? store?.activeSession?.agentIndicator
        revealActiveBlockedPane(captured: indicator)
    }
}
