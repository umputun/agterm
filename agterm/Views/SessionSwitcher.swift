import agtermCore
import AppKit
import SwiftUI

/// The Ctrl-Tab "previously visited session" switcher (macOS app-switcher style). Hold Ctrl and
/// press Tab to walk a frozen most-recently-used list (Shift+Tab reverses); releasing Ctrl commits
/// the highlighted session. The order comes from `AppStore.sessionRecency`; the candidate list is
/// snapshotted on `begin()` so cycling never reorders it — only the commit does (via selection).
///
/// Keys are caught by app-wide `NSEvent` local monitors rather than SwiftUI shortcuts, because the
/// interaction needs Tab while a modifier is held plus the modifier-release ("commit") signal.
@Observable
@MainActor
final class SessionSwitcher {
    /// The window library; the switcher cycles the frontmost window's session recency. (A
    /// per-window switcher tracking each window's own MRU is a later concern — for now it follows
    /// the frontmost window, matching the single-window behavior.)
    private let library: WindowLibrary
    private let canSwitch: () -> Bool
    private var store: AppStore? { library.activeStore }
    private(set) var isActive = false
    private(set) var candidates: [UUID] = []
    private(set) var index = 0

    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var flagsMonitor: Any?

    private static let tabKey: UInt16 = 48
    private static let escapeKey: UInt16 = 53
    /// Cap on rows the Ctrl-Tab switcher shows: it's a quick most-recent jump, not a full session list
    /// (the ⌃P fuzzy palette covers everything). The recency STORE keeps its full 100-item history.
    /// Shared with the mouse-driven recent-sessions popover so the two list the same sessions.
    static let maxCandidates = 10

    init(library: WindowLibrary, canSwitch: @escaping () -> Bool) {
        self.library = library
        self.canSwitch = canSwitch
    }

    /// Install the local monitors once: `.keyDown` for Ctrl+Tab / Ctrl+Shift+Tab / Esc, and
    /// `.flagsChanged` to detect Ctrl being released (the commit).
    func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // returning nil consumes the event so the terminal never sees Ctrl-Tab.
            return self.handleKeyDown(event) ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == Self.tabKey, event.modifierFlags.contains(.control) {
            guard canSwitch() else {
                reset()
                return true
            }
            if isActive { advance(reverse: event.modifierFlags.contains(.shift)) } else { begin() }
            return true
        }
        if isActive, event.keyCode == Self.escapeKey {
            reset()
            return true
        }
        return false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard canSwitch() else {
            reset()
            return
        }
        if isActive, !event.modifierFlags.contains(.control) { commit() }
    }

    /// Snapshot the MRU order (live sessions only, capped at `maxCandidates`) and pre-select the previous
    /// session. No-op when there's nothing to switch to (fewer than two sessions). The candidate set is
    /// scoped to the VISIBLE/FILTERED sessions (`navigableSessions` — the flagged set in flagged mode, the
    /// focused workspace's sessions when focused, else all), so clearing the flag/focus restores the full MRU.
    private func begin() {
        guard let store else { return }
        let valid = Set(store.navigableSessions.map(\.id))
        let order = store.sessionRecency.top(Self.maxCandidates, in: valid)
        guard order.count > 1 else { return }
        candidates = order
        index = 1
        isActive = true
    }

    private func advance(reverse: Bool) {
        guard !candidates.isEmpty else { return }
        let count = candidates.count
        index = ((index + (reverse ? -1 : 1)) % count + count) % count
    }

    private func commit() {
        defer { reset() }
        guard candidates.indices.contains(index), let store else { return }
        // a Ctrl-Tab commit is a user-initiated selection: note activity so it buys the full idle grace
        // before auto-follow can pull the selection back.
        store.noteUserActivity()
        store.selectSession(candidates[index])
    }

    /// Abort an in-progress switch WITHOUT committing a selection — used when a modal overlay (the
    /// dashboard) opens over the window and must take the keyboard cleanly.
    func cancel() { reset() }

    private func reset() {
        isActive = false
        candidates = []
        index = 0
    }
}

/// The switcher overlay: a top-centered list of the frozen candidate sessions (name + workspace ·
/// cwd) with the current pick highlighted. Keyboard-driven (no controls to focus), so the terminal
/// keeps first responder and the global monitors drive selection.
struct SessionSwitcherOverlay: View {
    let switcher: SessionSwitcher
    let store: AppStore

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.opacity(0.2)
                panel
                    .frame(width: 460)
                    .padding(.top, geo.size.height * 0.12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            ForEach(Array(switcher.candidates.enumerated()), id: \.element) { position, id in
                row(id, selected: position == switcher.index)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
        .shadow(radius: 24)
        .accessibilityIdentifier("session-switcher")
    }

    @ViewBuilder private func row(_ id: UUID, selected: Bool) -> some View {
        if let session = store.session(withID: id) {
            SessionSwitcherRow(title: session.displayName,
                               subtitle: "\(store.workspace(forSession: id)?.name ?? "") · \(session.subtitleDetail)")
                .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// One session row for the switcher surfaces — the display name over a `workspace · cwd` subtitle.
/// Shared by the keyboard Ctrl-Tab overlay (`SessionSwitcherOverlay`) and the mouse-driven recent-sessions
/// popover (`WindowContentView.recentSessionsPopover`) so the two rows never drift; the caller supplies the
/// row's background (the overlay's keyboard highlight, the popover's button hover).
struct SessionSwitcherRow: View {
    let title: String
    let subtitle: String
    /// Optional themed foreground: nil renders the system label colors (the Ctrl-Tab overlay's look); a set
    /// color themes the title with it and the subtitle at 0.6 opacity (the recent-sessions popover's look).
    var foreground: Color?
    /// Optional leading agent-status glyph — the attention popover sets it; the Ctrl-Tab overlay and the
    /// recent-sessions popover leave it nil. `statusColorHex` is the per-call `session.status --color` tint.
    var status: AgentStatus?
    var statusColorHex: String?

    var body: some View {
        HStack {
            if let status { StatusGlyph(status: status, colorHex: statusColorHex) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(foreground ?? Color.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(foreground.map { $0.opacity(0.6) } ?? Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
