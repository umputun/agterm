import Foundation

/// The window's custom titlebar row state: `normal` stacks the session name over the cwd subtitle,
/// `compact` is one short row, `hidden` drops the row and the traffic lights for a full-bleed terminal.
/// Raw-stored, resolved by `effectiveToolbarMode`. Top-level, unlike the nested sibling mode enums,
/// because the app target uses a bare `ToolbarMode`.
public enum ToolbarMode: String, Codable, Sendable, CaseIterable {
    case normal
    case compact
    case hidden
}

/// How a delivered notification bounces the Dock icon (`requestUserAttention`): `off`, `once` (one
/// `.informationalRequest`), or `untilFocused` (a `.criticalRequest` bouncing until agterm activates).
/// Raw-stored, resolved by `effectiveDockBounce`. Named `off`, not `none`, to dodge the `Optional.none`
/// collision at that call site (as `AutoFollowAttention.off`).
public enum DockBounce: String, Codable, Sendable, CaseIterable {
    case off
    case once
    case untilFocused
}

/// A toggleable title-bar or sidebar chrome element, persisted by raw name in
/// `AppSettings.hiddenInterfaceElements` (an unknown stored name is dropped, not fatal). Shown by
/// default; hiding adds its raw name.
public enum InterfaceElement: String, Codable, Sendable, CaseIterable {
    // title bar
    case sidebarToggle
    case sessionName
    case windowName
    case recentSessions
    case scratch
    case split
    case dashboard
    case quickTerminal
    // sidebar
    case newWorkspace
    case newSession
    case flaggedView
    case focusFilter
    case workspaceAddSession

    /// Which chrome surface the element belongs to — the Settings tab groups the toggles by this.
    public enum Section: Sendable { case titleBar, sidebar }

    /// The surface this element lives on; the title bar for everything not listed as sidebar.
    public var section: Section {
        switch self {
        case .newWorkspace, .newSession, .flaggedView, .focusFilter, .workspaceAddSession: return .sidebar
        default: return .titleBar
        }
    }

    /// The human-facing toggle label shown in the Interface settings tab.
    public var displayName: String {
        switch self {
        case .sidebarToggle: return "Sidebar toggle"
        case .sessionName: return "Session name"
        case .windowName: return "Window name"
        case .recentSessions: return "Recent sessions"
        case .scratch: return "Scratch terminal"
        case .split: return "Split view"
        case .dashboard: return "Dashboard"
        case .quickTerminal: return "Quick terminal"
        case .newWorkspace: return "New workspace"
        case .newSession: return "New session"
        case .flaggedView: return "Flagged view"
        case .focusFilter: return "Workspace filter"
        case .workspaceAddSession: return "Workspace add-session"
        }
    }

    /// Which of the two title-bar trailing-cluster separators to draw, from each group's visible button
    /// count (A = recent-sessions + attention, B = scratch + split, C = dashboard + quick-terminal): one
    /// sits ONLY where two groups that each still show 2+ buttons meet. Host-free so it is unit-testable.
    public static func titlebarGroupDividers(countA: Int, countB: Int, countC: Int) -> (afterA: Bool, afterB: Bool) {
        let afterA = countA >= 2 && countB >= 2
        let afterB = (countB >= 2 && countC >= 2) || (countA >= 2 && countC >= 2 && countB == 0)
        return (afterA, afterB)
    }
}

/// User-facing appearance settings, persisted independently of the workspace tree.
///
/// Every field is optional: nil means "use the default", and a file written before a field existed still
/// decodes. That optionality IS the forward-compat mechanism, so there is no version field — a bump would
/// only add a discard-on-mismatch path that wipes the user's settings. Enum-valued fields are raw strings
/// for the same reason, read back through an `effective…` accessor resolving an unknown (future-written)
/// value to the default rather than failing the whole decode. Only what `ghosttyConfigLines()` emits is a
/// ghostty key; every other field drives AppKit/SwiftUI chrome or app behavior.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Where a new (⌘T) session opens. `home` is both the default and the nil case, so picking it clears
    /// the stored field and keeps `settings.json` minimal.
    public enum NewSessionDirectory: String, CaseIterable, Sendable {
        case home
        case currentSession
        case custom
    }

    /// The terminal cursor shape, carrying ghostty's own `cursor-style` values as raw names. There is no
    /// case for nil, which is a state of its own: it emits nothing, leaving whatever `cursor-style` the
    /// config chain resolves — agterm's bundled block, or the user's own `ghostty.conf` — in charge.
    ///
    /// ghostty's `block_hollow` is deliberately absent. An unfocused surface is already marked by drawing
    /// its cursor hollow, so a hollow block chosen as the RESTING shape makes focused and unfocused panes
    /// identical and costs that signal. It stays reachable from `ghostty.conf` for anyone who wants it.
    public enum CursorStyle: String, CaseIterable, Sendable {
        case block
        case bar
        case underline
    }

    /// The user-idle timeout after which the window's selection auto-follows to the oldest blocked
    /// session. `off` is both the default and the nil case, so picking it clears the stored field.
    public enum AutoFollowAttention: String, CaseIterable, Sendable {
        case off
        case s5
        case s10
        case s30
        case s60
        case m5

        /// Tolerant lookup shared by the Settings binding and the store fan-out: unknown or nil is `off`.
        public init(tolerant raw: String?) {
            self = AutoFollowAttention(rawValue: raw ?? "") ?? .off
        }

        /// The idle grace in seconds before the auto-follow fires, or nil when `off` (disabled).
        public var timeout: TimeInterval? {
            switch self {
            case .off: return nil
            case .s5: return 5
            case .s10: return 10
            case .s30: return 30
            case .s60: return 60
            case .m5: return 300
            }
        }
    }

    /// The out-of-the-box bundled theme, seeded by `SettingsStore.load()` on a fresh install. Distinct
    /// from `theme == nil`, which means ghostty's own built-in default (the picker's "default ghostty").
    public static let defaultTheme = "agterm"

    /// The pane/backdrop mute strength (0...10, 0 = no mute) used when `inactivePaneMuteStrength` is nil.
    public static let defaultInactivePaneMuteStrength = 5

    /// The sidebar background shift used when `sidebarBackgroundShift` is nil; 5 is the neutral center,
    /// where the sidebar matches the terminal background.
    public static let defaultSidebarBackgroundShift = 5

    /// The sidebar row-text point size used when `sidebarFontSize` is nil; matches macOS `.body` (13pt).
    public static let defaultSidebarFontSize: Double = 13

    /// The Settings stepper bounds, kept modest so the fixed-size row icons and status glyphs stay
    /// visually balanced against the text at either end.
    public static let sidebarFontSizeRange: ClosedRange<Double> = 9 ... 20

    /// The palette/switcher text point size used when `interfaceFontSize` is nil; matches macOS `.body`
    /// (13pt), the size those surfaces rendered at before the setting existed.
    public static let defaultInterfaceFontSize: Double = 13

    /// The Settings stepper bounds for the palette/switcher size. Same span as the sidebar's, for the
    /// same reason: their fixed-size status glyphs stay balanced against the text at either end.
    public static let interfaceFontSizeRange: ClosedRange<Double> = 9 ... 20

    /// Terminal font family name (e.g. `SF Mono`), or nil for the ghostty default.
    public var fontFamily: String?
    /// Default terminal font size in points, or nil for the ghostty default.
    public var fontSize: Double?
    /// The ghostty `theme` value: a bundled name (e.g. `Adwaita Dark`), or nil for the ghostty default.
    /// With `followSystemAppearance` on this is the LIGHT slot, else the single theme for both appearances.
    public var theme: String?
    /// The DARK-appearance slot, used only when `followSystemAppearance` is on. With `theme` it emits
    /// ghostty's dual `theme = light:NAME,dark:NAME`, which libghostty resolves on a color-scheme change.
    public var darkTheme: String?
    /// Whether the terminal follows the macOS Light/Dark appearance; nil/false = off, emitting one `theme`.
    public var followSystemAppearance: Bool?
    /// The cursor shape, a `CursorStyle` raw value resolved by `effectiveCursorStyle`; nil emits nothing
    /// and leaves the config chain deciding. A picked shape wins over a `cursor-style` in the user's own
    /// `ghostty.conf`, because the settings conf loads last — that IS the difference between nil and an
    /// explicit `.block`, which otherwise render the same cursor.
    public var cursorStyle: String?
    /// Whether the cursor blinks, mirroring ghostty's own `?bool` for the key: nil emits nothing and is a
    /// third state rather than "off" — the cursor blinks AND DEC mode 12 can still change it. Either
    /// explicit value takes DEC mode 12 away (`DECSCUSR` still wins over both), so all three are named in
    /// the picker instead of collapsing to a toggle that could not say "always blink".
    public var cursorBlink: Bool?
    /// Window background opacity in 0...1, nil = opaque. Composited at the AppKit window level, NOT by the
    /// ghostty renderer, which `ghosttyConfigLines()` pins fully transparent below 1.
    public var backgroundOpacity: Double?
    /// Background blur radius (private CGS window blur, 0...100), nil = none; visible only when
    /// `backgroundOpacity` < 1. Applied in the app target.
    public var backgroundBlur: Int?
    /// Whether to post macOS notification banners for terminal desktop notifications; nil = on. Gates only
    /// the OS banner — the sidebar unseen-count badge tracks notifications either way.
    public var notificationsEnabled: Bool?
    /// Whether the sidebar shows the red unseen-count badge (the session-row pill and the
    /// collapsed-workspace roll-up); nil = on. Render-only — the count keeps tracking while hidden.
    public var notificationBadgeEnabled: Bool?
    /// The custom titlebar row state, a `ToolbarMode` raw string; nil = compact. Resolved through
    /// `effectiveToolbarMode`, which also maps the legacy `compactToolbar` — writing a mode nils that key.
    public var toolbarMode: String?
    /// Legacy decode shim for the pre-`toolbarMode` two-state toggle: false = normal bar, true/nil =
    /// compact. Read only by `effectiveToolbarMode` when `toolbarMode` is unset.
    public var compactToolbar: Bool?
    /// Hex colors (`#RRGGBB`) for the agent-status glyph's three states; nil each means the built-in
    /// default (active a muted lavender-grey `#DBD9E6`, blocked system amber, completed system green).
    public var activeStatusColorHex: String?
    public var blockedStatusColorHex: String?
    public var completedStatusColorHex: String?
    /// Silhouettes for the agent-status glyph's three states, `StatusShape` raw strings resolved by
    /// `effectiveStatusShape(for:)`; nil each means the default plain circle, which is also what the
    /// Settings picker stores for Circle. A per-call `session.status --shape` overrides these.
    public var activeStatusShape: String?
    public var blockedStatusShape: String?
    public var completedStatusShape: String?
    /// Directory holding the user-editable `keymap.conf`, nil for `~/.config/agterm`. Resolved by
    /// `ConfigPaths.configDirectory(setting:stateDir:home:)`.
    public var configDirectory: String?
    /// Ghostty `mouse-scroll-multiplier`; nil means agterm's default of 3, which is ALWAYS emitted, so it
    /// also overrides a `mouse-scroll-multiplier` in the user's own `~/.config/ghostty/config`.
    public var mouseScrollMultiplier: Double?
    /// How strongly muted text is, 0...10 — on the inactive split pane, and on the backdrop behind a
    /// floating overlay or the quick terminal; nil means `defaultInactivePaneMuteStrength`. A SwiftUI
    /// overlay opacity (`muteOpacity(strength:)`).
    public var inactivePaneMuteStrength: Int?
    /// How much darker or lighter the sidebar background is than the terminal background, 0...10 with 5
    /// neutral; nil means `defaultSidebarBackgroundShift`. A SwiftUI wash (`sidebarShiftAmount`).
    public var sidebarBackgroundShift: Int?
    /// Whether, on restart, each pane re-runs what it ran at the last clean quit (nil = off) — a captured
    /// `SessionSnapshot.foregroundCommand` plus a `session.new --command` session's `initialCommand`.
    public var restoreRunningCommand: Bool?
    /// Whether agterm also loads the user's GLOBAL `~/.config/ghostty/config` over its bundled defaults.
    /// nil = off, so a config written for the standalone Ghostty.app does NOT silently change agterm; opt
    /// in to share one config across both. The agterm-scoped `~/.config/agterm/ghostty.conf` is ALWAYS
    /// loaded and is the place for overrides. Gates which files `loadConfig` reads.
    public var inheritGlobalGhosttyConfig: Bool?
    /// Whether the title bar shows the attention bell (window-wide non-idle status at a glance); nil = off.
    public var attentionButtonEnabled: Bool?
    /// Dock-bounce mode for a delivered notification, a `DockBounce` raw value; nil = `off`.
    /// `NotificationManager` reads its mirror and issues the matching `requestUserAttention`, a no-op
    /// while agterm is frontmost.
    public var dockBounce: String?
    /// System sound attached to a delivered desktop notification, nil/empty for silent. Delivered as
    /// `UNNotificationSound(named:)` on the banner content (`.aiff` appended when the name has no suffix),
    /// so it RIDES the banner: gated by `notificationsEnabled` and the macOS notification authorization,
    /// silenced by Do Not Disturb, unlike the badge and the Dock bounce. Only Settings previews `NSSound`.
    public var notificationSoundName: String?
    /// System sound played when a session enters `blocked` (resolved by `NSSound(named:)`), nil/empty for
    /// silent. A per-call `session.status --sound` overrides this.
    public var blockedStatusSoundName: String?
    /// Whether a right-click pastes the clipboard (ghostty `right-click-action`); nil = on, since agterm
    /// forwards right-/middle-click to libghostty. agterm has no terminal context menu, so paste-or-off is
    /// the whole meaningful choice.
    public var rightClickPaste: Bool?
    /// Whether clicking anywhere on a workspace row expands or collapses it; nil = on. The disclosure
    /// triangle toggles regardless of this setting.
    public var workspaceRowClickExpands: Bool?
    /// Which directory a new (⌘T) session opens in, a `NewSessionDirectory` raw value; nil = `home`. Read
    /// by `AppActions.newSession()` through `resolveNewSessionCwd`.
    public var newSessionDirectory: String?
    /// The fixed directory used when `newSessionDirectory` is `custom`; nil/empty falls back to home.
    public var newSessionCustomDirectory: String?
    /// Whether a GUI session close (⌘W, the File/palette Close Session, the sidebar row's Close) confirms
    /// first; nil = off. Read on demand; the control channel's `session.close` never prompts.
    public var confirmCloseSession: Bool?
    /// Whether GUI closes keep a short undo grace period before final teardown; nil = on. When off they
    /// are immediate but still enter File > Open Recent.
    public var closeGraceUndoEnabled: Bool?
    /// The idle timeout that auto-follows the window's selection to the oldest blocked session, an
    /// `AutoFollowAttention` raw value; nil = `off`. Per-window, drives `AppStore`'s idle controller.
    public var autoFollowAttention: String?
    /// Whether auto-follow stays put on a running (`active`) session instead of pulling to a blocked one;
    /// nil/false = off. Only meaningful when `autoFollowAttention` is set.
    public var autoFollowStayOnActive: Bool?
    /// The sidebar row-text point size, nil for `defaultSidebarFontSize`; the row height scales with it
    /// (`sidebarRowHeight(fontSize:)`). Independent of `interfaceFontSize`.
    public var sidebarFontSize: Double?
    /// The palette, picker and session-switcher text point size, nil for `defaultInterfaceFontSize`.
    /// Panel widths scale with it (`InterfaceMetrics`). Independent of `sidebarFontSize`.
    public var interfaceFontSize: Double?
    /// The share of the focused screen the quick-terminal panel takes, as a percentage; nil keeps the
    /// built-in size. `QuickTerminalMetrics.panelSize` resolves and clamps it.
    public var quickTerminalSizePercent: Int?
    /// Raw names of the chrome elements the user has HIDDEN (see `InterfaceElement`); nil/empty shows
    /// everything. Unknown names are dropped by `resolvedHiddenInterfaceElements`.
    public var hiddenInterfaceElements: [String]?
    /// Whether, with more than one window open, only the frontmost shows its sidebar and every other
    /// collapses its own; nil = off. Visibility then follows window focus, so a manual per-window hide is
    /// transient — the frontmost window re-shows its sidebar on refocus.
    public var autoHideSidebarInactiveWindows: Bool?
    /// Whether the first-launch pointer at the Help menu extras has been shown; nil/false = not yet.
    /// Written once, by the launch that shows it. See `FirstRunWelcome`.
    public var welcomeShown: Bool?

    public init(fontFamily: String? = nil, fontSize: Double? = nil, theme: String? = nil,
                darkTheme: String? = nil, followSystemAppearance: Bool? = nil,
                cursorStyle: String? = nil, cursorBlink: Bool? = nil,
                backgroundOpacity: Double? = nil, backgroundBlur: Int? = nil, notificationsEnabled: Bool? = nil,
                toolbarMode: String? = nil, compactToolbar: Bool? = nil, notificationBadgeEnabled: Bool? = nil,
                activeStatusColorHex: String? = nil, blockedStatusColorHex: String? = nil,
                completedStatusColorHex: String? = nil, activeStatusShape: String? = nil,
                blockedStatusShape: String? = nil, completedStatusShape: String? = nil,
                configDirectory: String? = nil,
                mouseScrollMultiplier: Double? = nil, inactivePaneMuteStrength: Int? = nil,
                sidebarBackgroundShift: Int? = nil, restoreRunningCommand: Bool? = nil,
                inheritGlobalGhosttyConfig: Bool? = nil, attentionButtonEnabled: Bool? = nil,
                dockBounce: String? = nil, notificationSoundName: String? = nil,
                blockedStatusSoundName: String? = nil, rightClickPaste: Bool? = nil,
                workspaceRowClickExpands: Bool? = nil,
                newSessionDirectory: String? = nil, newSessionCustomDirectory: String? = nil,
                confirmCloseSession: Bool? = nil, closeGraceUndoEnabled: Bool? = nil,
                autoFollowAttention: String? = nil,
                autoFollowStayOnActive: Bool? = nil, sidebarFontSize: Double? = nil,
                interfaceFontSize: Double? = nil, quickTerminalSizePercent: Int? = nil,
                hiddenInterfaceElements: [String]? = nil,
                autoHideSidebarInactiveWindows: Bool? = nil, welcomeShown: Bool? = nil) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.theme = theme
        self.darkTheme = darkTheme
        self.followSystemAppearance = followSystemAppearance
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.notificationsEnabled = notificationsEnabled
        self.toolbarMode = toolbarMode
        self.compactToolbar = compactToolbar
        self.notificationBadgeEnabled = notificationBadgeEnabled
        self.activeStatusColorHex = activeStatusColorHex
        self.blockedStatusColorHex = blockedStatusColorHex
        self.completedStatusColorHex = completedStatusColorHex
        self.activeStatusShape = activeStatusShape
        self.blockedStatusShape = blockedStatusShape
        self.completedStatusShape = completedStatusShape
        self.configDirectory = configDirectory
        self.mouseScrollMultiplier = mouseScrollMultiplier
        self.inactivePaneMuteStrength = inactivePaneMuteStrength
        self.sidebarBackgroundShift = sidebarBackgroundShift
        self.restoreRunningCommand = restoreRunningCommand
        self.inheritGlobalGhosttyConfig = inheritGlobalGhosttyConfig
        self.attentionButtonEnabled = attentionButtonEnabled
        self.dockBounce = dockBounce
        self.notificationSoundName = notificationSoundName
        self.blockedStatusSoundName = blockedStatusSoundName
        self.rightClickPaste = rightClickPaste
        self.workspaceRowClickExpands = workspaceRowClickExpands
        self.newSessionDirectory = newSessionDirectory
        self.newSessionCustomDirectory = newSessionCustomDirectory
        self.confirmCloseSession = confirmCloseSession
        self.closeGraceUndoEnabled = closeGraceUndoEnabled
        self.autoFollowAttention = autoFollowAttention
        self.autoFollowStayOnActive = autoFollowStayOnActive
        self.sidebarFontSize = sidebarFontSize
        self.interfaceFontSize = interfaceFontSize
        self.quickTerminalSizePercent = quickTerminalSizePercent
        self.hiddenInterfaceElements = hiddenInterfaceElements
        self.autoHideSidebarInactiveWindows = autoHideSidebarInactiveWindows
        self.welcomeShown = welcomeShown
    }

    /// The hidden chrome elements, unknown (future-written) raw names dropped. The single read point.
    public var resolvedHiddenInterfaceElements: Set<InterfaceElement> {
        Set((hiddenInterfaceElements ?? []).compactMap(InterfaceElement.init(rawValue:)))
    }

    /// Whether a chrome element is hidden; anything absent from the persisted list reads as visible.
    public func isInterfaceElementHidden(_ element: InterfaceElement) -> Bool {
        resolvedHiddenInterfaceElements.contains(element)
    }

    /// The resolved titlebar row state: the explicit `toolbarMode` when a KNOWN raw value, else the legacy
    /// `compactToolbar` mapping. The single read point.
    public var effectiveToolbarMode: ToolbarMode {
        toolbarMode.flatMap(ToolbarMode.init(rawValue:)) ?? (compactToolbar == false ? .normal : .compact)
    }

    /// The resolved Dock-bounce mode: the explicit `dockBounce` when a KNOWN raw value, else `off`. The
    /// single read point.
    public var effectiveDockBounce: DockBounce {
        dockBounce.flatMap(DockBounce.init(rawValue:)) ?? .off
    }

    /// The resolved cursor shape, or nil when unset OR when the stored raw name is one this version does
    /// not offer — a future shape, or a `block_hollow` written by hand. The single read point, so an
    /// unoffered value falls back to the config chain rather than being emitted from here.
    public var effectiveCursorStyle: CursorStyle? {
        cursorStyle.flatMap(CursorStyle.init(rawValue:))
    }

    /// The resolved glyph silhouette for one agent status: the configured raw name when a KNOWN
    /// `StatusShape`, else nil (the default plain circle). `idle` renders no glyph and has no shape. The
    /// single read point.
    public func effectiveStatusShape(for status: AgentStatus) -> StatusShape? {
        let raw: String?
        switch status {
        case .active: raw = activeStatusShape
        case .blocked: raw = blockedStatusShape
        case .completed: raw = completedStatusShape
        case .idle: return nil
        }
        return raw.flatMap(StatusShape.init(rawValue:))
    }

    /// The working directory a new session opens in, resolving `newSessionDirectory` against the active
    /// session's focused-pane cwd and home. An unknown/nil mode, a blank `currentSessionCwd`, or a blank
    /// custom path all fall back to home. Host-free so `AppActions` and the tests share one resolution.
    public func resolveNewSessionCwd(currentSessionCwd: String?, home: String) -> String {
        switch NewSessionDirectory(rawValue: newSessionDirectory ?? "") ?? .home {
        case .home:
            return home
        case .currentSession:
            guard let cwd = currentSessionCwd, !cwd.isEmpty else { return home }
            return cwd
        case .custom:
            guard let dir = newSessionCustomDirectory, !dir.isEmpty else { return home }
            return dir
        }
    }

    /// The SwiftUI overlay opacity for an inactive-pane mute strength, clamped and scaled by 0.08 (the
    /// default 5 → 0.4). The overlay is the terminal background color, so a higher opacity blends the
    /// pane's text further toward the background while leaving background pixels unchanged.
    public static func muteOpacity(strength: Int) -> Double {
        Double(min(10, max(0, strength))) * 0.08
    }

    /// The signed sidebar background shift, clamped and measured from the neutral center 5, so the
    /// endpoints are -0.30 (full lighten) and +0.30 (full darken). Positive darkens with a black wash,
    /// negative lightens with a white one; the magnitude is the wash opacity, composited over the window
    /// background by `WindowContentView.sidebarTintWash`.
    public static func sidebarShiftAmount(strength: Int) -> Double {
        Double(min(10, max(0, strength)) - 5) * 0.06
    }

    /// Bounds a raw sidebar row-text point size to `sidebarFontSizeRange`, so a stray persisted or
    /// out-of-range value can't produce a degenerate row.
    public static func clampSidebarFontSize(_ size: Double) -> Double {
        min(sidebarFontSizeRange.upperBound, max(sidebarFontSizeRange.lowerBound, size))
    }

    /// Bounds a raw palette/switcher point size to `interfaceFontSizeRange`.
    public static func clampInterfaceFontSize(_ size: Double) -> Double {
        min(interfaceFontSizeRange.upperBound, max(interfaceFontSizeRange.lowerBound, size))
    }

    /// The resolved quick-terminal share, or nil for the built-in size. The single read point, and the one
    /// the Settings picker binds: a stored value outside `QuickTerminalMetrics.sizePercentChoices` — hand
    /// edited, or written by a later version offering more of them — resolves to nil rather than being
    /// applied, so the picker can never show blank while the panel uses a size it has no row for.
    /// `panelSize` clamps its own argument as well; that guards a direct caller, this owns the setting.
    public var effectiveQuickTerminalSizePercent: Int? {
        guard let quickTerminalSizePercent,
              QuickTerminalMetrics.sizePercentChoices.contains(quickTerminalSizePercent) else { return nil }
        return quickTerminalSizePercent
    }

    /// The resolved sidebar row-text size, clamped. The single read point.
    public var effectiveSidebarFontSize: Double {
        Self.clampSidebarFontSize(sidebarFontSize ?? Self.defaultSidebarFontSize)
    }

    /// The resolved palette/switcher text size, clamped. The single read point.
    public var effectiveInterfaceFontSize: Double {
        Self.clampInterfaceFontSize(interfaceFontSize ?? Self.defaultInterfaceFontSize)
    }

    /// The outline row height: the clamped point size plus a fixed 15pt of vertical padding, so the
    /// default 13pt maps to a 28pt row. The row icon and status glyph keep their fixed sizes.
    public static func sidebarRowHeight(fontSize: Double) -> Double {
        clampSidebarFontSize(fontSize).rounded() + 15
    }

    /// The theme name that renders for the given appearance, the dark slot falling back to `theme`. Used
    /// only by the theme-palette badge/selection — emission composes the raw dual and lets ghostty pick
    /// the side.
    public func activeTheme(isDark: Bool) -> String? {
        guard followSystemAppearance == true else { return theme }
        return isDark ? (darkTheme ?? theme) : theme
    }

    /// The `key = value` lines for the set fields, for a file loaded via `ghostty_config_load_file`; unset
    /// or blank fields are omitted. Values are written raw — ghostty takes the whole line remainder as the
    /// value, so names with spaces (`3024 Night`, `SF Mono`) are NOT quoted; quotes would become part of
    /// the value.
    public func ghosttyConfigLines() -> [String] {
        var lines: [String] = []
        if let fontFamily, !fontFamily.isEmpty { lines.append("font-family = \(fontFamily)") }
        if let fontSize { lines.append("font-size = \(Self.format(fontSize))") }
        // when following, emit ghostty's dual conditional RAW and let libghostty resolve the active side
        // on a color-scheme change (it records the new state and asks the host to re-feed the config,
        // which the reload path does). no appearance input here — ghostty owns the switch.
        let light = theme.flatMap { $0.isEmpty ? nil : $0 }
        let dark = darkTheme.flatMap { $0.isEmpty ? nil : $0 }
        if followSystemAppearance == true, let light, let dark {
            lines.append("theme = light:\(light),dark:\(dark)")
        } else if let single = light ?? dark {
            lines.append("theme = \(single)")
        }
        // emitted only when picked, so everyone who never opens the picker keeps the bundled block — and
        // their own ghostty.conf `cursor-style` — exactly as before.
        if let cursorStyle = effectiveCursorStyle { lines.append("cursor-style = \(cursorStyle.rawValue)") }
        // both explicit values are emitted; nil is the third state, which emits nothing and leaves DEC
        // mode 12 able to drive the blink.
        if let cursorBlink { lines.append("cursor-style-blink = \(cursorBlink)") }
        // a translucent window composites its tint at the AppKit level, so the renderer must draw fully
        // transparent or the surface and the window stack two tints. at full opacity (or unset) these are
        // omitted and ghostty paints its own background.
        if let backgroundOpacity, backgroundOpacity < 1 {
            lines.append("background-opacity = 0")
            lines.append("background-blur = 0")
        }
        // always emitted (nil = agterm's 3), so the default speed wins over ghostty's per-device defaults
        // (discrete 3 / precision 1). a bare value sets both the wheel and the trackpad.
        lines.append("mouse-scroll-multiplier = \(Self.format(mouseScrollMultiplier ?? 3))")
        // always emitted (nil = on); off emits `ignore` to hard-disable it. the settings conf loads last,
        // so this wins over a `right-click-action` in the user's own ghostty.conf.
        lines.append("right-click-action = \((rightClickPaste ?? true) ? "paste" : "ignore")")
        return lines
    }

    /// Integer sizes render without a trailing `.0` (`14`, not `14.0`); fractional sizes keep it.
    private static func format(_ size: Double) -> String {
        size == size.rounded() ? String(Int(size)) : String(size)
    }
}
