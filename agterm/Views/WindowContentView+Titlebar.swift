import agtermCore
import AppKit
import SwiftUI

/// The custom title-bar row and its label/buttons, split out of `WindowContentView` for the file size limit.
/// Owns the title text (session / window name, gated by the Interface toggles), the row layout, and the
/// per-session chrome buttons; recent-sessions / attention / dashboard buttons live in their own extensions.
extension WindowContentView {
    /// The titlebar title (first line): the active session's display name, suffixed as "session — window" for
    /// a custom (user-set) window name; auto "window N" names are omitted, and "Agterm" when nothing is
    /// selected. Non-private: the body's `WindowAccessor` uses it as the OS window title, always the real
    /// name, regardless of the Interface toggles that gate only the on-screen `titleText`.
    var windowTitle: String {
        let session = store.activeSession?.displayName ?? "Agterm"
        guard let name = customWindowName else { return session }
        return "\(session) — \(name)"
    }

    /// The titlebar subtitle (second line): the session's `context` when one is set and shown, else the
    /// focused pane's `subtitleDetail` — the terminal title for a remote (SSH) session whose local cwd is
    /// stale, else its cwd. Normal mode only; compact/hidden drop it.
    private var windowSubtitle: String { composition.subtitle }

    /// Both title-bar lines, laid out host-free. The toggles are resolved into `Parts` here, so
    /// `TitlebarComposition` never sees the settings.
    private var composition: TitlebarComposition {
        TitlebarComposition.compose(
            TitlebarComposition.Parts(
                sessionName: shows(.sessionName) ? (store.activeSession?.displayName ?? "Agterm") : nil,
                windowName: shows(.windowName) ? customWindowName : nil,
                context: shows(.sessionContext) ? store.activeSession?.context : nil,
                detail: store.activeSession?.subtitleDetail ?? ""
            ),
            mode: toolbarMode
        )
    }

    /// The window's user-set name, or nil when it has none (an auto "window N" name). Feeds the optional
    /// window-name part of `titleText`.
    private var customWindowName: String? {
        guard let info = library.windows.first(where: { $0.id == windowID }), info.hasCustomName else { return nil }
        return info.name
    }

    /// The VISIBLE title-bar label. `windowTitle` above still feeds the OS title, so Mission Control and the
    /// Window menu stay labelled whatever the Interface toggles hide here.
    private var titleText: String { composition.title }

    /// The window title at the terminal's leading edge, laid out by `composition` above. Non-private so the
    /// zoom titlebar reuses it — a zoomed terminal shows the same title as the normal window.
    var titleLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !titleText.isEmpty {
                Text(titleText).fontWeight(.semibold)
            }
            if !windowSubtitle.isEmpty {
                Text(windowSubtitle)
                    .font(.caption)
                    .foregroundStyle(chromeText.opacity(0.6))
            }
        }
        // a caller-set context can run to 256 bytes, far past the row; tail truncation drops its end rather
        // than letting the label push the trailing button cluster off the bar.
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// The window chrome above the terminal: the full custom titlebar row, or in hidden mode an invisible ~3px
    /// top drag strip alone (no row; `WindowAppearance.sync` also drops the traffic lights), so the terminal
    /// runs full-bleed while staying movable + double-click-zoomable. Non-private, rendered above the overlays.
    @ViewBuilder var customTitlebar: some View {
        if toolbarMode == .hidden {
            // only the top ~3px loses click-through (the accepted cost), kept thin so it stays clear of the
            // terminal's first row (window-padding-y = 6) whose clicks it would swallow; `WindowControlArea`
            // still supplies the standard title-bar gestures.
            Color.clear
                .frame(height: 3)
                .frame(maxWidth: .infinity)
                // Color.clear is hit-testable in SwiftUI and would swallow the mouseDown before the
                // WindowControlArea behind it, so opt out and let drag/double-click-zoom reach the AppKit view.
                .allowsHitTesting(false)
                .background { WindowControlArea() }
        } else {
            titlebarRow
        }
    }

    /// Custom titlebar row replacing the system toolbar: the sidebar toggle pinned to the sidebar's trailing
    /// edge (by the divider), the title at the terminal's start, and the trailing cluster (recent-sessions /
    /// attention popovers, divider, scratch / split controls, divider, dashboard / quick terminal). Positions
    /// track `sidebarWidth`; the left inset clears the system traffic lights.
    private var titlebarRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 78).allowsHitTesting(false) // system traffic lights
            if store.sidebarVisible {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    // keep the sidebar-width frame even when the toggle is hidden, so the title still starts
                    // at the terminal's leading edge; the Spacer fills the freed space.
                    if shows(.sidebarToggle) {
                        sidebarToggleButton.labelStyle(.iconOnly)
                    }
                }
                .frame(width: max(40, CGFloat(store.sidebarWidth) - 78))
                Color.clear.frame(width: 11).allowsHitTesting(false) // 1px divider + gap to the title
            } else {
                if shows(.sidebarToggle) {
                    sidebarToggleButton.labelStyle(.iconOnly)
                }
                Spacer().frame(width: 12)
            }
            titleLabel
                // the title text falls through to the drag/zoom layer behind it, so double-click zooms and
                // drag moves the window; the rest of the row is non-hittable spacers plus the buttons.
                .allowsHitTesting(false)
            Spacer(minLength: 12)
            titlebarTrailingActions
        }
        .buttonStyle(.plain)
        // tint the title text and the toolbar buttons with the terminal theme's foreground so the
        // chrome tracks the theme (the cwd subtitle dims itself to 0.6 over this).
        .foregroundStyle(chromeText)
        // the row isn't drawn in hidden mode; imageScale hits the SF Symbols, not the title text.
        .imageScale(toolbarMode == .normal ? .large : .medium)
        .frame(height: titlebarHeight)
        .frame(maxWidth: .infinity)
        // make the header behave like a standard title bar: single-click drag moves the window, double-click
        // runs the user's configured title-bar action (zoom/minimize/none) — a custom titlebar gets no native
        // double-click handling. the layer sits BEHIND the row, so the buttons keep their clicks while the
        // spacers + title text opt out of hit-testing (above) and fall through to it.
        .background { WindowControlArea() }
    }

    /// The title bar's trailing action cluster, each button gated by its Interface toggle: recent-sessions /
    /// attention popovers, per-session scratch / split controls, window-overlay dashboard / quick terminal.
    /// A separator sits ONLY where two groups that each still show 2+ buttons meet, so a group reduced to one
    /// button flows in unbracketed and an empty group lets its neighbors meet directly.
    private var titlebarTrailingActions: some View {
        let showRecent = shows(.recentSessions)
        let showAttention = attentionButtonEnabled // the bell keeps its own separate Notifications setting
        let showScratch = shows(.scratch)
        let showSplit = shows(.split)
        let showDashboard = shows(.dashboard)
        let showQuick = shows(.quickTerminal)
        let countA = (showRecent ? 1 : 0) + (showAttention ? 1 : 0)
        let countB = (showScratch ? 1 : 0) + (showSplit ? 1 : 0)
        let countC = (showDashboard ? 1 : 0) + (showQuick ? 1 : 0)
        // a separator only between two 2+-button groups (the host-free rule, unit-tested in agtermCore).
        let dividers = InterfaceElement.titlebarGroupDividers(countA: countA, countB: countB, countC: countC)
        return HStack(spacing: 14) {
            if showRecent { recentSessionsButton.labelStyle(.iconOnly) }
            if showAttention { attentionButton.labelStyle(.iconOnly) }
            if dividers.afterA { titlebarDivider }
            if showScratch { scratchButton.labelStyle(.iconOnly) }
            if showSplit { splitButton.labelStyle(.iconOnly) }
            if dividers.afterB { titlebarDivider }
            if showDashboard { dashboardButton.labelStyle(.iconOnly) }
            if showQuick { quickTerminalButton.labelStyle(.iconOnly) }
        }
        .padding(.trailing, 14)
    }

    /// The 1px themed separator between two title-bar button groups.
    private var titlebarDivider: some View {
        Rectangle().fill(chromeText.opacity(0.25)).frame(width: 1, height: 16)
    }

    /// Our own sidebar show/hide toggle (the custom split has no system one). Animated collapse.
    private var sidebarToggleButton: some View {
        Button {
            actions.toggleSidebar()
        } label: {
            Label("Toggle Sidebar", systemImage: "sidebar.left")
        }
        .help(helpHint("Toggle Sidebar", .toggleSidebar))
        .accessibilityIdentifier("sidebar-toggle-button")
    }

    private var splitButton: some View {
        let isSplit = store.activeSession?.isSplit ?? false
        let hasSplit = store.activeSession?.hasSplit ?? false
        let splitFocused = store.activeSession?.splitFocused ?? false
        let axis = store.activeSession?.splitAxis ?? .leftRight
        let shortcutAction: BuiltinAction = axis == .topBottom ? .toggleHorizontalSplit : .toggleSplit
        // filled = pane visible, outline = hidden: no split is an empty two-pane outline, a shown split fills
        // both, and a collapsed one fills the visible leading or trailing half on the current axis.
        // `splitFocused` identifies that visible pane. `a11y` mirrors all seven states for XCUITest, which
        // cannot read the symbol name: none, both, both-horizontal, left, right, top, and bottom.
        let symbol: String
        let a11y: String
        if !hasSplit {
            symbol = "rectangle.split.2x1"; a11y = "none"
        } else if isSplit {
            symbol = axis == .topBottom ? "rectangle.split.1x2.fill" : "rectangle.split.2x1.fill"
            a11y = axis == .topBottom ? "both-horizontal" : "both"
        } else if splitFocused {
            symbol = axis == .topBottom ? "rectangle.bottomhalf.filled" : "rectangle.righthalf.filled"
            a11y = axis == .topBottom ? "bottom" : "right"
        } else {
            symbol = axis == .topBottom ? "rectangle.tophalf.filled" : "rectangle.lefthalf.filled"
            a11y = axis == .topBottom ? "top" : "left"
        }
        return Button {
            actions.toggleCurrentSplit()
        } label: {
            // a Label (icon + title) so the toolbar's "Icon and Text" mode has text; hidden in icon-only mode.
            Label("Split", systemImage: symbol)
        }
        .help(helpHint(isSplit ? "Hide split" : (hasSplit ? "Show split" : "Split right"), shortcutAction))
        .disabled(store.activeSession == nil)
        .accessibilityValue(a11y)
        .accessibilityIdentifier("split-toggle")
    }

    /// Toggles the active session's scratch terminal — a third, full-overlay login shell kept alive when
    /// hidden. 2-state glyph (filled while shown): no "hidden but exists" state, since its `exit` clears it.
    private var scratchButton: some View {
        let active = store.activeSession?.scratchActive ?? false
        return Button {
            actions.toggleScratch()
        } label: {
            Label("Scratch", systemImage: active ? "rectangle.inset.filled" : "rectangle")
        }
        .help(helpHint(active ? "Hide scratch terminal" : "Show scratch terminal", .toggleScratch))
        .disabled(store.activeSession == nil)
        .accessibilityIdentifier("scratch-toggle")
    }

    /// Toggles the quick terminal: one scratch terminal overlaid at 90% of the window, above the sidebar and
    /// terminal. Clicking it again or the surrounding margin hides it; the shell stays alive until quit.
    private var quickTerminalButton: some View {
        Button {
            actions.toggleQuickTerminal()
        } label: {
            Label("Quick Terminal", systemImage: "terminal")
        }
        .help(helpHint("Quick Terminal", .quickTerminal))
        .disabled(pick.pending != nil)
        .accessibilityIdentifier("quick-terminal-toggle")
    }
}
