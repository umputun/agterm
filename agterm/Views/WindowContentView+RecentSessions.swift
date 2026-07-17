import agtermCore
import AppKit
import SwiftUI

/// Title-bar "jump to a session" buttons, split out of `WindowContentView` to keep that file under the
/// 1000-line limit (the `+Dashboard`/`+Zoom` extension pattern): the recent-sessions popover — the mouse
/// equivalent of the Ctrl-Tab switcher — and the attention bell. Both open a session picker over the
/// frontmost window and are referenced from `WindowContentView.titlebarRow`.
extension WindowContentView {
    /// The frontmost window's most-recently-used sessions, EXCLUDING the current one (it's not a jump target —
    /// you're already there), scoped to the visible/filtered set and capped like the Ctrl-Tab switcher.
    /// The live refresh rides the OBSERVED `activeSession`/`navigableSessions` reads — every `sessionRecency`
    /// mutation co-occurs with one of them (a push on select changes `activeSession`, a prune on close changes
    /// `navigableSessions`); `sessionRecency` itself is `@ObservationIgnored`, read for its value, not for
    /// observation, so it registers none on its own.
    private var recentSessions: [UUID] {
        var valid = Set(store.navigableSessions.map(\.id))
        if let activeID = store.activeSession?.id { valid.remove(activeID) }
        return store.sessionRecency.top(SessionSwitcher.maxCandidates, in: valid)
    }

    /// Title-bar button that opens the recent-sessions popover — the mouse equivalent of the Ctrl-Tab
    /// switcher. Lists the window's most-recently-used OTHER sessions; disabled/dimmed when there's nothing
    /// to switch to (only the current session). Opening a popover is interactive-only, so it's control-API
    /// keep-in-sync exempt (like the bell opening the attention palette).
    var recentSessionsButton: some View {
        let enabled = !recentSessions.isEmpty
        return Button {
            recentSessionsShown.toggle()
        } label: {
            Label("Recent sessions", systemImage: "clock.arrow.circlepath")
        }
        .help("Recent sessions (⌃Tab)")
        // pin the tint to chromeText like the attention bell: without it a disabled plain button resolves
        // the SF Symbol to the system disabled color, which is near-invisible on the themed titlebar (the
        // dimmed clock would vanish instead of graying out like the bell).
        .foregroundStyle(chromeText)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityIdentifier("recent-sessions-button")
        .popover(isPresented: $recentSessionsShown, arrowEdge: .bottom) {
            recentSessionsPopover
        }
        .onChange(of: recentSessionsShown) { _, shown in
            // suppress this window's auto-follow while the popover is open so an armed idle jump can't
            // reshuffle the MRU rows under the pointer (the command palette + dashboard bracket the same way);
            // the counted suppression stays balanced across open/close and with the attention popover.
            if shown { store.suppressAutoFollow() } else { store.resumeAutoFollow() }
        }
        .onChange(of: recentSessions.isEmpty) { _, empty in
            // the only listed session exiting on its own fires no outside-click dismiss, so close the popover
            // ourselves when the list empties — else an empty sliver lingers under a now-disabled button.
            if empty { recentSessionsShown = false }
        }
    }

    /// The recent-sessions popover body: the MRU OTHER sessions as full-row `RecentSessionRow`s (the shared
    /// two-line `SessionSwitcherRow`) — the current session is omitted since it isn't a jump target. Each row
    /// highlights on hover and, on click anywhere in the row, commits the switch (`noteUserActivity` +
    /// `selectSession` + focus, like the Ctrl-Tab release) then closes the popover — the palette-row feel.
    /// Tinted to the terminal theme (`terminalColor` panel, `chromeText` text, selection-color hover) so it
    /// matches the themed sidebar/titlebar chrome rather than the system popover look.
    private var recentSessionsPopover: some View {
        // no `.accessibilityIdentifier` on this container: a SwiftUI accessibility identifier on a parent
        // propagates to and OVERRIDES its descendants' identifiers, which would clobber the per-row
        // `recent-session-row` ids the tests read. The rows carry their own ids.
        VStack(spacing: 2) {
            ForEach(recentSessions, id: \.self) { id in
                recentSessionRow(id)
            }
        }
        .padding(6)
        .frame(width: 320)
        .background(terminalColor)
        .presentationBackground(terminalColor)
    }

    @ViewBuilder private func recentSessionRow(_ id: UUID) -> some View {
        if let session = store.session(withID: id) {
            SessionPopoverRow(
                title: session.displayName,
                subtitle: "\(store.workspace(forSession: id)?.name ?? "") · \(session.subtitleDetail)",
                status: nil,
                statusColorHex: nil,
                foreground: chromeText,
                hoverColor: recentSelectionColor,
                accessibilityID: "recent-session-row"
            ) { selectRecent(id) }
        }
    }

    /// The hover-highlight color for a popover row: the terminal theme's selection background (the color the
    /// selected sidebar row uses), or a subtle wash of the foreground when the theme sets no selection color.
    private var recentSelectionColor: Color {
        if let sel = GhosttyApp.shared.terminalSelectionBackgroundColor {
            return Color(nsColor: sel).opacity(0.5)
        }
        return chromeText.opacity(0.2)
    }

    /// Commit a popover row click: note activity (so auto-follow can't pull the selection back), select the
    /// session, focus it, and close the popover — the mouse twin of the Ctrl-Tab release commit.
    private func selectRecent(_ id: UUID) {
        store.noteUserActivity()
        store.selectSession(id)
        actions.focusActiveSession()
        recentSessionsShown = false
    }

    /// Title-bar bell reflecting the window's attention state at a glance (opt-in, gated by the
    /// `attentionButtonEnabled` mirror). Three states from `store.attentionSessions`: empty → a dimmed
    /// disabled outline bell; non-empty with nothing blocked → a plain enabled bell in `chromeText`; any
    /// blocked session → a filled bell tinted the blocked-status color. No count, no pulse. Click opens the
    /// attention popover (the mouse form; ⌃⇧I / the Navigate menu keep the searchable `.attention` palette).
    /// Reading `store.attentionSessions` in the body registers the per-session `agentIndicator` observation,
    /// so the glyph re-renders live as a status changes. `.accessibilityValue` (none|attention|blocked)
    /// exposes the otherwise-unobservable bell↔bell.fill state to XCUITest, mirroring `StatusIconView`.
    var attentionButton: some View {
        let sessions = store.attentionSessions
        let blocked = sessions.contains { $0.agentIndicator.status == .blocked }
        let empty = sessions.isEmpty
        return Button {
            attentionPopoverShown.toggle()
        } label: {
            Label("Attention", systemImage: blocked ? "bell.fill" : "bell")
        }
        .foregroundStyle(blocked ? Color(nsColor: GhosttyApp.shared.blockedStatusColor) : chromeText)
        .opacity(empty ? 0.35 : 1)
        .disabled(empty)
        .help(helpHint(empty ? "No sessions need attention" : "Show sessions that need attention", .showAttention))
        .accessibilityIdentifier("attention-button")
        .accessibilityValue(empty ? "none" : (blocked ? "blocked" : "attention"))
        .popover(isPresented: $attentionPopoverShown, arrowEdge: .bottom) {
            attentionPopover
        }
        .onChange(of: attentionPopoverShown) { _, shown in
            // same as the recent popover: suppress auto-follow while open so an armed idle jump can't
            // reshuffle the listed attention sessions under the pointer; counted, so it stays balanced.
            if shown { store.suppressAutoFollow() } else { store.resumeAutoFollow() }
        }
        .onChange(of: empty) { _, isEmpty in
            // the last attention session going idle fires no outside-click dismiss; close the popover so no
            // empty sliver lingers under the now-disabled bell.
            if isEmpty { attentionPopoverShown = false }
        }
    }

    /// The attention popover body: the window's sessions needing attention (`store.attentionSessions`, sorted
    /// blocked→active→completed) as full-row `SessionPopoverRow`s with a leading status glyph — the mouse form
    /// of the ⌃⇧I attention palette, themed and hover-highlighted like the recent-sessions popover. Clicking a
    /// row selects the session and reveals its blocked pane. Same tint (`terminalColor`/`chromeText`/selection).
    private var attentionPopover: some View {
        VStack(spacing: 2) {
            ForEach(store.attentionSessions) { session in
                SessionPopoverRow(
                    title: session.displayName,
                    subtitle: "\(store.workspace(forSession: session.id)?.name ?? "") · \(session.subtitleDetail)",
                    status: session.agentIndicator.status,
                    statusColorHex: session.agentIndicator.color,
                    foreground: chromeText,
                    hoverColor: recentSelectionColor,
                    accessibilityID: "attention-session-row"
                ) { selectAttention(session.id) }
            }
        }
        .padding(6)
        .frame(width: 320)
        .background(terminalColor)
        .presentationBackground(terminalColor)
    }

    /// Commit an attention popover row click: select the session and reveal its blocked pane (the pane that
    /// set the status), then close the popover — the mouse twin of the ⌃⇧I palette's select-and-reveal.
    private func selectAttention(_ id: UUID) {
        store.noteUserActivity()
        store.selectSession(id)
        actions.revealActiveBlockedPane()
        attentionPopoverShown = false
    }
}

/// One clickable session row for the title-bar popovers (recent-sessions and attention) — the shared two-line
/// `SessionSwitcherRow` tinted with the terminal theme (`foreground`), with an optional leading status glyph
/// (`status`, set only by the attention popover), a pointer-hover highlight (`hoverColor`) and a full-row hit
/// area (`.contentShape`), so the WHOLE row selects on click, not just the text (the command-palette-row
/// feel). Kept a `Button` so it reads as an actionable control to VoiceOver; `accessibilityID` distinguishes
/// the two popovers' rows for the tests.
private struct SessionPopoverRow: View {
    let title: String
    let subtitle: String
    let status: AgentStatus?
    let statusColorHex: String?
    let foreground: Color
    let hoverColor: Color
    let accessibilityID: String
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            SessionSwitcherRow(title: title, subtitle: subtitle, foreground: foreground,
                               status: status, statusColorHex: statusColorHex)
                .background(hovering ? hoverColor : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier(accessibilityID)
    }
}
