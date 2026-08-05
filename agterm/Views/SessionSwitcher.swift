import agtermCore
import AppKit
import SwiftUI

/// The Ctrl-Tab "previously visited session" switcher (macOS app-switcher style): hold Ctrl and press Tab to
/// walk a frozen most-recently-used list (Shift+Tab reverses), release Ctrl to commit the highlighted
/// session. The order comes from `AppStore.sessionRecency`, snapshotted on `begin()` so cycling never
/// reorders it — only the commit does, via selection. Keys come from app-wide `NSEvent` local monitors, not
/// SwiftUI shortcuts, because the interaction needs Tab-while-held plus the modifier-release commit signal.
@Observable
@MainActor
final class SessionSwitcher {
    /// The window library; the switcher cycles the FRONTMOST window's session recency (a per-window
    /// switcher tracking each window's own MRU is a later concern).
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
    /// Cap on rows shown: a quick most-recent jump, not a full session list (the ⌃P fuzzy palette covers
    /// everything); the recency STORE keeps its full 100-item history. Shared with the mouse-driven
    /// recent-sessions popover so the two list the same sessions.
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
    /// session; no-op with fewer than two sessions. Scoped to the VISIBLE/FILTERED set (`navigableSessions`
    /// — the flagged set in flagged mode, the MARKED workspaces' sessions while the filter applies, else
    /// all), so clearing the flag or suspending the filter restores the full MRU.
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

/// The switcher overlay: a top-centered list of the frozen candidates (name + workspace · cwd), current pick
/// highlighted. Keyboard-driven with no focusable control, so the terminal keeps first responder and the
/// global monitors drive selection.
struct SessionSwitcherOverlay: View {
    let switcher: SessionSwitcher
    let store: AppStore
    /// Where the terminal area starts inside the window (sidebar plus divider, 0 when hidden). The panel
    /// shifts by half of it so it centers over the terminal rather than the whole window.
    let terminalAreaInset: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The chrome text sizes, read from the non-observable `GhosttyApp` — the overlay mounts fresh on each
    /// Ctrl-Tab, so it never renders a stale size.
    private let metrics = SessionSwitcherOverlay.resolvedMetrics()

    /// The measured height of the row stack, so the panel hugs its rows until they outgrow the window.
    @State private var rowsHeight: Double = 0

    /// The panel width at the 13pt default, scaled by `metrics` and then fitted to the window.
    private static let panelWidthAtDefaultFontSize: Double = 460
    /// How far down the window the panel starts.
    private static let topInsetFraction: Double = 0.12
    /// Inset between the panel's rounded background and its rows.
    private static let panelPadding: Double = 6

    private static func resolvedMetrics() -> InterfaceMetrics {
        GhosttyApp.shared.interfaceMetrics
    }

    var body: some View {
        GeometryReader { geo in
            let width = metrics.fittedPanelWidth(idealAtDefault: Self.panelWidthAtDefaultFontSize,
                                                 windowWidth: geo.size.width,
                                                 terminalAreaInset: terminalAreaInset)
            ZStack(alignment: .top) {
                Color.black.opacity(0.2)
                panel(maxRowsHeight: metrics.fittedPanelHeight(windowHeight: geo.size.height,
                                                               topFraction: Self.topInsetFraction) - Self.panelPadding * 2)
                    .frame(width: width)
                    .padding(.top, geo.size.height * Self.topInsetFraction)
                    .offset(x: metrics.panelOffset(width: width, windowWidth: geo.size.width,
                                                   terminalAreaInset: terminalAreaInset))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// The rows scroll rather than overflow: ten candidates at a large interface size want more height than
    /// a short window has, and the stack has no other way to give. `scrollTo` keeps the cycling selection
    /// visible, which is the whole point of the overlay.
    ///
    /// The height is MEASURED and then capped, never proposed: a `ScrollView` takes whatever height it is
    /// offered instead of sizing to its content, so handing `maxRowsHeight` straight to `.frame(maxHeight:)`
    /// makes every panel that tall — three rows in a tall window drew a panel of mostly empty material.
    /// `rowsHeight` starts at 0, where the frame stays unconstrained for the one layout pass before the
    /// preference lands.
    private func panel(maxRowsHeight: Double) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(switcher.candidates.enumerated()), id: \.element) { position, id in
                        row(id, selected: position == switcher.index)
                            .id(position)
                    }
                }
                .background(
                    GeometryReader { rows in
                        Color.clear.preference(key: RowsHeightKey.self, value: rows.size.height)
                    }
                )
            }
            .frame(height: metrics.measuredPanelHeight(rowsHeight: rowsHeight,
                                                       maxRowsHeight: maxRowsHeight).map { CGFloat($0) })
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(RowsHeightKey.self) { height in
                rowsHeight = height
            }
            .onChange(of: switcher.index) { _, index in proxy.scrollTo(index) }
        }
        .padding(Self.panelPadding)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
        .shadow(radius: 24)
        .accessibilityIdentifier("session-switcher")
    }

    private var panelBackground: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
            : AnyShapeStyle(.regularMaterial)
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

/// Carries the measured row-stack height out of the scroll content, so the panel can size to its rows
/// instead of to the height it is offered.
private struct RowsHeightKey: PreferenceKey {
    static let defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = max(value, nextValue()) }
}

/// One session row for the switcher surfaces — the display name over a `workspace · cwd` subtitle. Shared by
/// the Ctrl-Tab overlay (`SessionSwitcherOverlay`) and the recent-sessions popover
/// (`WindowContentView.recentSessionsPopover`) so the two never drift; the caller supplies the row's
/// background (the overlay's keyboard highlight, the popover's button hover).
struct SessionSwitcherRow: View {
    let title: String
    let subtitle: String
    /// Optional themed foreground: nil renders the system label colors (the Ctrl-Tab overlay's look); a set
    /// color themes the title with it and the subtitle at 0.6 opacity (the recent-sessions popover's look).
    var foreground: Color?
    /// Optional leading agent-status glyph — the attention popover sets it; the Ctrl-Tab overlay and the
    /// recent-sessions popover leave it nil. `statusColorHex` is the per-call `session.status --color` tint,
    /// `statusShape` its per-call `--shape` silhouette.
    var status: AgentStatus?
    var statusColorHex: String?
    var statusShape: StatusShape?

    /// Read from the non-observable `GhosttyApp` — both the Ctrl-Tab overlay and the popovers mount fresh
    /// on every open, so neither renders a stale size.
    private let metrics = SessionSwitcherRow.resolvedMetrics()

    private static func resolvedMetrics() -> InterfaceMetrics {
        GhosttyApp.shared.interfaceMetrics
    }

    var body: some View {
        HStack {
            if let status { StatusGlyph(status: status, colorHex: statusColorHex, shape: statusShape) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: metrics.base))
                    .foregroundStyle(foreground ?? Color.primary)
                Text(subtitle)
                    .font(.system(size: metrics.secondary))
                    .foregroundStyle(foreground.map { $0.opacity(0.6) } ?? Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.scaled(12))
        .padding(.vertical, metrics.scaled(6))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
