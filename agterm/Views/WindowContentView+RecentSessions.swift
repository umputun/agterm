import agtermCore
import AppKit
import SwiftUI

/// Title-bar "jump to a session" buttons, split out of `WindowContentView` to keep that file under the
/// 1000-line limit (the `+Dashboard`/`+Zoom` extension pattern): the recent-sessions popover — the mouse
/// equivalent of the Ctrl-Tab switcher — and the attention bell. Both open a session picker over the
/// frontmost window and are referenced from `WindowContentView.titlebarRow`.
extension WindowContentView {
    /// The frontmost window's most-recently-used sessions, EXCLUDING the current one (not a jump target —
    /// you're already there), scoped to the visible/filtered set and capped like the Ctrl-Tab switcher. The
    /// live refresh rides the OBSERVED `activeSession`/`navigableSessions` reads — every `sessionRecency`
    /// mutation co-occurs with one (a push on select changes `activeSession`, a prune on close changes
    /// `navigableSessions`); `sessionRecency` itself is `@ObservationIgnored` and registers no observation.
    private var recentSessions: [UUID] {
        store.navigableRecentSessions(limit: SessionSwitcher.maxCandidates)
    }

    /// Title-bar button opening the recent-sessions popover — the mouse equivalent of the Ctrl-Tab switcher.
    /// Lists the window's most-recently-used OTHER sessions; disabled/dimmed when there is nothing to switch to
    /// (only the current session). Opening a popover is interactive-only, so it is control-API keep-in-sync
    /// exempt, like the bell opening the attention palette.
    var recentSessionsButton: some View {
        let enabled = !recentSessions.isEmpty && !pick.modalPending
        return Button {
            guard !pick.modalPending else { return }
            recentSessionsShown.toggle()
        } label: {
            Label("Recent sessions", systemImage: "clock.arrow.circlepath")
        }
        .help("Recent sessions (⌃Tab)")
        // pin the tint to chromeText like the attention bell: a disabled plain button otherwise resolves the SF
        // Symbol to the system disabled color, near-invisible on the themed titlebar — the dimmed clock would
        // vanish instead of graying out like the bell.
        .foregroundStyle(chromeText)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityIdentifier("recent-sessions-button")
        .popover(isPresented: $recentSessionsShown, arrowEdge: .bottom) {
            recentSessionsPopover
        }
        .onChange(of: recentSessionsShown) { _, shown in
            // suppress this window's auto-follow while the popover is open so an armed idle jump can't reshuffle
            // the MRU rows under the pointer (the palette + dashboard bracket the same way); the counted
            // suppression stays balanced across open/close and with the attention popover.
            if shown { store.suppressAutoFollow() } else { store.resumeAutoFollow() }
        }
        .onChange(of: recentSessions.isEmpty) { _, empty in
            // the only listed session exiting on its own fires no outside-click dismiss, so close the popover
            // ourselves when the list empties — else an empty sliver lingers under a now-disabled button.
            if empty { recentSessionsShown = false }
        }
    }

    /// The recent-sessions popover body: the MRU OTHER sessions as full rows (the shared two-line
    /// `SessionSwitcherRow`). Each row highlights on hover and, on a click anywhere in the row, commits the
    /// switch (`noteUserActivity` + `selectSession` + focus, like the Ctrl-Tab release) then closes the popover
    /// — the palette-row feel. Tinted to the terminal theme (`terminalColor` panel, `chromeText` text,
    /// selection-color hover) so it matches the themed chrome rather than the system popover look.
    private var recentSessionsPopover: some View {
        // no `.accessibilityIdentifier` on this container: a SwiftUI identifier on a parent propagates to and
        // OVERRIDES its descendants', clobbering the per-row `recent-session-row` ids the tests read.
        VStack(spacing: 2) {
            ForEach(recentSessions, id: \.self) { id in
                recentSessionRow(id)
            }
        }
        .padding(6)
        .frame(width: GhosttyApp.shared.interfaceMetrics.scaled(320))
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
                statusShape: nil,
                foreground: chromeText,
                hoverColor: popoverHoverColor,
                accessibilityID: "recent-session-row"
            ) { selectRecent(id) }
        }
    }

    /// The hover-highlight color for a title-bar popover row: the terminal theme's selection background (the
    /// color the selected sidebar row uses), or a subtle wash of the foreground when the theme sets no
    /// selection color. Shared with the custom-commands popover.
    var popoverHoverColor: Color {
        if let sel = GhosttyApp.shared.terminalSelectionBackgroundColor {
            return Color(nsColor: sel).opacity(0.5)
        }
        return chromeText.opacity(0.2)
    }

    /// Commit a popover row click: note activity (so auto-follow can't pull the selection back), select the
    /// session, focus it, and close the popover — the mouse twin of the Ctrl-Tab release commit.
    private func selectRecent(_ id: UUID) {
        guard !pick.modalPending else { return }
        store.noteUserActivity()
        store.selectSession(id)
        actions.focusActiveSession()
        recentSessionsShown = false
    }

    /// Title-bar bell reflecting the attention state across every open window (opt-in, gated by the
    /// `attentionButtonEnabled` mirror): dimmed and disabled when empty, plain when nothing is blocked, filled
    /// in the blocked-status color otherwise. No count, no pulse. Click opens the attention popover (the
    /// mouse form; ⌃⇧I / the Navigate menu keep the searchable `.attention` palette). Reading the library
    /// list in the body registers the per-session `agentIndicator` observation and the open-set version, so
    /// the glyph re-renders live; `.accessibilityValue` (none|attention|blocked) exposes the
    /// otherwise-unobservable bell↔bell.fill state to XCUITest, mirroring `StatusIconView`.
    var attentionButton: some View {
        let entries = library.attentionAcrossWindows
        let blocked = entries.contains { $0.session.agentIndicator.status == .blocked }
        let empty = entries.isEmpty
        let enabled = !empty && !pick.modalPending
        return Button {
            guard !pick.modalPending else { return }
            attentionPopoverShown.toggle()
        } label: {
            Label("Attention", systemImage: blocked ? "bell.fill" : "bell")
        }
        .foregroundStyle(blocked ? Color(nsColor: GhosttyApp.shared.blockedStatusColor) : chromeText)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .help(helpHint(empty ? "No sessions need attention" : "Show sessions that need attention", .showAttention))
        .accessibilityIdentifier("attention-button")
        .accessibilityValue(empty ? "none" : (blocked ? "blocked" : "attention"))
        .popover(isPresented: $attentionPopoverShown, arrowEdge: .bottom) {
            attentionPopover
        }
        .onChange(of: attentionPopoverShown) { _, shown in
            // same as the recent popover: suppress auto-follow while open (counted, so it stays balanced).
            if shown { store.suppressAutoFollow() } else { store.resumeAutoFollow() }
        }
        .onChange(of: empty) { _, isEmpty in
            // the last attention session going idle fires no outside-click dismiss; close the popover so no
            // empty sliver lingers under the now-disabled bell.
            if isEmpty { attentionPopoverShown = false }
        }
    }

    /// The attention popover body: every open window's sessions needing attention as full-row
    /// `SessionPopoverRow`s with a leading status glyph — the mouse form of the ⌃⇧I attention palette. A row
    /// whose window sits under a cover renders disabled, as the palette's does, rather than dismissing into
    /// a no-op. The rows are measured so short lists stay compact and long lists scroll at
    /// `attentionRowsCap`, for the reason `measuredPanelHeight` gives.
    private var attentionPopover: some View {
        let metrics = GhosttyApp.shared.interfaceMetrics
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(library.attentionAcrossWindows) { entry in
                    SessionPopoverRow(
                        title: entry.session.displayName,
                        subtitle: library.attentionSubtitle(entry),
                        status: entry.session.agentIndicator.status,
                        statusColorHex: entry.session.agentIndicator.color,
                        statusShape: entry.session.agentIndicator.shape,
                        foreground: chromeText,
                        hoverColor: popoverHoverColor,
                        accessibilityID: "attention-session-row",
                        isEnabled: actions.canSelectAttention(windowID: entry.window.id, sessionID: entry.session.id)
                    ) { selectAttention(entry) }
                }
            }
            .background(
                GeometryReader { rows in
                    Color.clear.preference(key: RowsHeightKey.self, value: rows.size.height)
                }
            )
        }
        .frame(height: metrics.measuredPanelHeight(rowsHeight: attentionRowsHeight,
                                                   maxRowsHeight: metrics.scaled(Self.attentionRowsCap)).map { CGFloat($0) })
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(RowsHeightKey.self) { height in
            attentionRowsHeight = height
        }
        .padding(6)
        .frame(width: metrics.scaled(320))
        .background(terminalColor)
        .presentationBackground(terminalColor)
    }

    /// The attention popover's row-stack cap at the default interface size, about ten rows.
    static let attentionRowsCap: Double = 440

    /// Commit an attention popover row click. The popover closes first and the select runs on the next turn,
    /// so a raise of another window never competes with this popover's dismissal; the action rechecks the
    /// target then.
    private func selectAttention(_ entry: AttentionEntry) {
        let windowID = entry.window.id
        let sessionID = entry.session.id
        guard !pick.modalPending, actions.canSelectAttention(windowID: windowID, sessionID: sessionID) else { return }
        attentionPopoverShown = false
        DispatchQueue.main.async { actions.selectAttention(windowID: windowID, sessionID: sessionID) }
    }
}

/// One clickable session row for the title-bar popovers (recent-sessions and attention) — the shared two-line
/// `SessionSwitcherRow` tinted with the terminal theme (`foreground`), with an optional leading status glyph
/// (`status` plus its per-call `statusColorHex`/`statusShape` overrides, set only by the attention popover so
/// the row matches the sidebar glyph), a pointer-hover highlight (`hoverColor`) and a full-row hit area
/// (`.contentShape`), so the WHOLE row selects on click, not just the text. Kept a `Button` so it reads as an
/// actionable control to VoiceOver; `accessibilityID` distinguishes the two popovers' rows for the tests.
/// `isEnabled` false renders the row dimmed and inert, for an attention row whose window is under a cover.
private struct SessionPopoverRow: View {
    let title: String
    let subtitle: String
    let status: AgentStatus?
    let statusColorHex: String?
    let statusShape: StatusShape?
    let foreground: Color
    let hoverColor: Color
    let accessibilityID: String
    var isEnabled = true
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            SessionSwitcherRow(title: title, subtitle: subtitle, foreground: foreground,
                               status: status, statusColorHex: statusColorHex, statusShape: statusShape)
                .background(hovering && isEnabled ? hoverColor : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .accessibilityIdentifier(accessibilityID)
    }
}
