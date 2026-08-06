import agtermCore
import AppKit
import os
import SwiftUI

private let logger = Logger(subsystem: "com.umputun.agterm", category: "SettingsView")

/// The Settings window (Cmd+,): six tabs — General (mouse, sessions, ghostty config), Appearance
/// (font/theme + window translucency + mute), Interface (per-element title-bar and sidebar chrome
/// visibility), Notifications (banner / badge / attention toggles), Agent Status (sidebar glyph colors and
/// shapes + blocked sound + auto-follow), and Key Mapping (config directory + keymap diagnostics + Reload).
/// Throughout, a control's binding maps its DEFAULT value back to nil so `settings.json` stays minimal.
struct SettingsView: View {
    let model: SettingsModel

    /// Identifies each tab. The explicit selection binding keeps the window opening on General: without it
    /// SwiftUI's Settings scene persists the last tab to `selectedTabIndex` in defaults and restores it.
    private enum Tab: Hashable { case general, appearance, interface, notifications, agentStatus, keyMapping }
    @State private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            AppearanceSettingsView(model: model)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(Tab.appearance)
            InterfaceSettingsView(model: model)
                .tabItem { Label("Interface", systemImage: "macwindow") }
                .tag(Tab.interface)
            NotificationsSettingsView(model: model)
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(Tab.notifications)
            AgentStatusSettingsView(model: model)
                .tabItem { Label("Agent Status", systemImage: "smallcircle.filled.circle") }
                .tag(Tab.agentStatus)
            KeyMappingSettingsView(model: model)
                .tabItem { Label("Key Mapping", systemImage: "keyboard") }
                .tag(Tab.keyMapping)
        }
        .frame(width: 540, height: 640)
        // without this a process-launch reopen (see agtermApp's FB11763863 workaround) resurrects a stale
        // Settings window on its last tab, stealing key focus from the real launch window.
        .background(NonRestorableWindow())
    }
}

/// Marks its hosting `NSWindow` non-restorable so macOS doesn't persist/reopen it.
private struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView { Probe() }
    func updateNSView(_: NSView, context _: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isRestorable = false
            window.disableSnapshotRestoration()
        }
    }
}

/// A terse one-line caption under a control; only non-obvious controls carry one, so tabs fit unscrolled.
private struct SettingHint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

/// General tab: Mouse (scroll speed, right-click-pastes, workspace-row click), Sessions (new-session
/// directory, restore running commands) and the inherit-global-ghostty-config toggle; visual and
/// notification settings have their own tabs.
private struct GeneralSettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Mouse") {
                HStack {
                    Text("Scroll speed")
                    Slider(value: mouseScrollMultiplier, in: 1 ... 10, step: 1)
                        .accessibilityIdentifier("settings-scroll-speed")
                    Text("\(Int(model.settings.mouseScrollMultiplier ?? 3))x")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                Toggle("Right-click pastes", isOn: rightClickPaste)
                    .accessibilityIdentifier("settings-right-click-paste")
                Toggle("Click a workspace row to expand or collapse", isOn: workspaceRowClickExpands)
                    .accessibilityIdentifier("settings-workspace-row-click-expands")
            }

            Section("Sessions") {
                Picker("New sessions open in", selection: newSessionDirectory) {
                    Text("Home directory").tag(AppSettings.NewSessionDirectory.home)
                    Text("Current session's directory").tag(AppSettings.NewSessionDirectory.currentSession)
                    Text("Custom directory").tag(AppSettings.NewSessionDirectory.custom)
                }
                .accessibilityIdentifier("settings-new-session-directory")
                if newSessionDirectory.wrappedValue == .custom {
                    HStack {
                        Text(customDirectory ?? "Not set")
                            .font(.system(size: 12).monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .foregroundStyle(customDirectory == nil ? .secondary : .primary)
                            .accessibilityIdentifier("settings-new-session-custom-dir")
                        Spacer()
                        Button("Choose…") { chooseCustomDirectory() }
                            .accessibilityIdentifier("settings-new-session-choose")
                    }
                }
                Toggle("Restore running commands on restart", isOn: restoreRunningCommand)
                    .accessibilityIdentifier("settings-restore-running-command")
                Toggle("Confirm before closing a session", isOn: confirmCloseSession)
                    .accessibilityIdentifier("settings-confirm-close-session")
                Toggle("Allow undo after closing sessions and workspaces", isOn: closeGraceUndoEnabled)
                    .accessibilityIdentifier("settings-close-grace-undo")
            }

            Section("Ghostty Config") {
                Toggle("Use my global Ghostty config", isOn: inheritGlobalGhosttyConfig)
                    .accessibilityIdentifier("settings-inherit-global-ghostty")
                SettingHint("Also loads ~/.config/ghostty/config on top of agterm's own. Edit ~/.config/agterm/ghostty.conf to customize.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var restoreRunningCommand: Binding<Bool> {
        Binding(get: { model.settings.restoreRunningCommand ?? false },
                set: { model.setRestoreRunningCommand($0 ? true : nil) })
    }

    private var confirmCloseSession: Binding<Bool> {
        Binding(get: { model.settings.confirmCloseSession ?? false },
                set: { model.setConfirmCloseSession($0 ? true : nil) })
    }

    /// Default ON; turning it off stores false and makes GUI closes immediate.
    private var closeGraceUndoEnabled: Binding<Bool> {
        Binding(get: { model.settings.closeGraceUndoEnabled ?? true },
                set: { model.setCloseGraceUndoEnabled($0 ? nil : false) })
    }

    private var inheritGlobalGhosttyConfig: Binding<Bool> {
        Binding(get: { model.settings.inheritGlobalGhosttyConfig ?? false },
                set: { model.setInheritGlobalGhosttyConfig($0 ? true : nil) })
    }

    /// Default ON. Drives the ghostty `right-click-action` key (paste when on, ignore when off).
    private var rightClickPaste: Binding<Bool> {
        Binding(get: { model.settings.rightClickPaste ?? true },
                set: { model.setRightClickPaste($0 ? nil : false) })
    }

    /// Default ON; turning it off stores false and leaves only the disclosure triangle as the hit target.
    private var workspaceRowClickExpands: Binding<Bool> {
        Binding(get: { model.settings.workspaceRowClickExpands ?? true },
                set: { model.setWorkspaceRowClickExpands($0 ? nil : false) })
    }

    /// Default 3. The config emits 3 either way, so the default speed is effective regardless.
    private var mouseScrollMultiplier: Binding<Double> {
        Binding(get: { model.settings.mouseScrollMultiplier ?? 3 },
                set: { model.setMouseScrollMultiplier($0 == 3 ? nil : $0) })
    }

    /// The directory to display, treating nil OR empty as "unset" to match `resolveNewSessionCwd` (home for
    /// both), so a blank hand-edited `settings.json` value renders as "Not set", not a blank styled path.
    private var customDirectory: String? {
        let dir = model.settings.newSessionCustomDirectory
        return dir?.isEmpty == false ? dir : nil
    }

    /// The new-session directory mode; nil (the default) or an unknown stored value resolves to `.home`.
    private var newSessionDirectory: Binding<AppSettings.NewSessionDirectory> {
        Binding(get: { AppSettings.NewSessionDirectory(rawValue: model.settings.newSessionDirectory ?? "") ?? .home },
                set: { model.setNewSessionDirectory($0 == .home ? nil : $0.rawValue) })
    }

    /// Pick the `custom` new-session mode's fixed directory with the standard open panel (dirs only), persist.
    private func chooseCustomDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = DirectoryPanelDefaults.url(paths: customDirectory, model.activeSessionCwd)
        panel.prompt = "Choose"
        panel.message = "Choose a directory for new sessions"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setNewSessionCustomDirectory(url.path)
    }
}

/// Appearance tab: Terminal (font family, size, theme) and Window (toolbar mode, background opacity + blur,
/// sidebar tint + font size, pane/backdrop mute), each persisting and live-applying via `SettingsModel`.
private struct AppearanceSettingsView: View {
    let model: SettingsModel
    private let themes = SettingsCatalog.themeNames()
    private let fonts = SettingsCatalog.monospacedFontFamilies()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Font", selection: fontFamily) {
                    Text("Default").tag(String?.none)
                    ForEach(fonts, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .accessibilityIdentifier("settings-font-family")

                Stepper(value: fontSize, in: 8 ... 32, step: 1) {
                    Text("Default font size: \(Int(model.settings.fontSize ?? 13))")
                }
                .accessibilityIdentifier("settings-font-size")

                // the CURRENT appearance's theme; while following, the on-screen side. The "default ghostty"
                // row shows only when NOT following — a dual conditional needs two named themes.
                Picker("Theme", selection: themeForCurrentAppearance) {
                    if !following { Text("default ghostty").tag(String?.none) }
                    ForEach(themes, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .accessibilityIdentifier("settings-theme")

                Toggle("Follow system appearance", isOn: followSystemAppearance)
                    .accessibilityIdentifier("settings-follow-appearance")

                // only while following: the OTHER appearance's theme. ghostty resolves the active side at
                // runtime, so a light/dark flip rewrites no config.
                if following {
                    Picker(GhosttyApp.currentIsDark() ? "Light theme" : "Dark theme", selection: alternateTheme) {
                        ForEach(themes, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .accessibilityIdentifier("settings-theme-dark")
                    SettingHint("Used when macOS is in \(GhosttyApp.currentIsDark() ? "light" : "dark") mode.")
                }
            }

            Section("Window") {
                Picker("Toolbar", selection: toolbarMode) {
                    Text("Normal").tag(ToolbarMode.normal)
                    Text("Compact").tag(ToolbarMode.compact)
                    Text("Hidden").tag(ToolbarMode.hidden)
                }
                .accessibilityIdentifier("settings-toolbar-mode")

                HStack {
                    Text("Background Opacity")
                    Slider(value: backgroundOpacity, in: 0 ... 1,
                           onEditingChanged: { editing in if !editing { model.commitBackgroundSettings() } })
                        .accessibilityIdentifier("settings-bg-opacity")
                    Text("\(Int(((model.settings.backgroundOpacity ?? 1) * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }

                HStack {
                    Text("Background Blur")
                    Slider(value: backgroundBlur, in: 0 ... 100,
                           onEditingChanged: { editing in if !editing { model.commitBackgroundSettings() } })
                        .accessibilityIdentifier("settings-bg-blur")
                    Text("\(model.settings.backgroundBlur ?? 0)")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .disabled((model.settings.backgroundOpacity ?? 1) >= 1)
                if reduceTransparency {
                    SettingHint("Reduce Transparency is on; saved opacity and blur apply when it is off.")
                } else {
                    SettingHint("Blur needs opacity below 100%.")
                }

                HStack {
                    Text("Sidebar Tint")
                    Slider(value: sidebarBackgroundShift, in: 0 ... 10, step: 1)
                        .accessibilityIdentifier("settings-sidebar-shift")
                    Text(sidebarShiftLabel)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }

                Stepper(value: sidebarFontSize, in: AppSettings.sidebarFontSizeRange, step: 1) {
                    Text("Sidebar font size: \(Int(model.settings.effectiveSidebarFontSize))")
                }
                .accessibilityIdentifier("settings-sidebar-font-size")

                Stepper(value: interfaceFontSize, in: AppSettings.interfaceFontSizeRange, step: 1) {
                    Text("Palette and switcher font size: \(Int(model.settings.effectiveInterfaceFontSize))")
                }
                .accessibilityIdentifier("settings-interface-font-size")

                HStack {
                    Text("Inactive pane and backdrop mute")
                    Slider(value: inactivePaneMuteStrength, in: 0 ... 10, step: 1)
                        .accessibilityIdentifier("settings-inactive-pane-mute")
                    Text("\(model.settings.inactivePaneMuteStrength ?? AppSettings.defaultInactivePaneMuteStrength)")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var fontFamily: Binding<String?> {
        Binding(get: { model.settings.fontFamily }, set: { model.setFontFamily($0) })
    }

    private var fontSize: Binding<Double> {
        Binding(get: { model.settings.fontSize ?? 13 }, set: { model.setFontSize($0) })
    }

    /// The sidebar row-text size.
    private var sidebarFontSize: Binding<Double> {
        Binding(get: { model.settings.effectiveSidebarFontSize },
                set: { model.setSidebarFontSize($0 == AppSettings.defaultSidebarFontSize ? nil : $0) })
    }

    /// The palette, picker and session-switcher text size.
    private var interfaceFontSize: Binding<Double> {
        Binding(get: { model.settings.effectiveInterfaceFontSize },
                set: { model.setInterfaceFontSize($0 == AppSettings.defaultInterfaceFontSize ? nil : $0) })
    }

    /// Whether the terminal follows the macOS appearance — reveals the alternate picker.
    private var following: Bool { model.settings.followSystemAppearance == true }

    /// Picker 1: the CURRENT appearance's theme — the dark slot while following in dark mode, else `theme`.
    private var themeForCurrentAppearance: Binding<String?> {
        Binding(get: { model.settings.activeTheme(isDark: GhosttyApp.currentIsDark()) },
                set: { model.setThemeForCurrentAppearance($0) })
    }

    /// Picker 2, only while following: the OTHER appearance's theme — light slot in dark mode, dark in light.
    private var alternateTheme: Binding<String?> {
        Binding(get: { GhosttyApp.currentIsDark() ? model.settings.theme : model.settings.darkTheme },
                set: { model.setAlternateTheme($0) })
    }

    /// The "Follow system appearance" toggle — `setFollowSystemAppearance` seeds/collapses the two slots.
    private var followSystemAppearance: Binding<Bool> {
        Binding(get: { model.settings.followSystemAppearance == true },
                set: { model.setFollowSystemAppearance($0) })
    }

    /// PREVIEWS live (apply without save) per drag tick and debounces; `onEditingChanged` flushes on release.
    private var backgroundOpacity: Binding<Double> {
        Binding(get: { model.settings.backgroundOpacity ?? 1 },
                set: { model.previewBackgroundOpacity($0 >= 1 ? nil : $0) })
    }

    /// Previews and flushes like `backgroundOpacity`.
    private var backgroundBlur: Binding<Double> {
        Binding(get: { Double(model.settings.backgroundBlur ?? 0) },
                set: { model.previewBackgroundBlur($0 <= 0 ? nil : Int($0.rounded())) })
    }

    /// Neutral is 5.
    private var sidebarBackgroundShift: Binding<Double> {
        Binding(get: { Double(model.settings.sidebarBackgroundShift ?? AppSettings.defaultSidebarBackgroundShift) },
                set: { value in
                    let strength = Int(value.rounded())
                    model.setSidebarBackgroundShift(strength == AppSettings.defaultSidebarBackgroundShift ? nil : strength)
                })
    }

    /// "None" at the neutral center, else the direction and magnitude away from it (e.g. "Lighter 2").
    private var sidebarShiftLabel: String {
        let offset = (model.settings.sidebarBackgroundShift ?? AppSettings.defaultSidebarBackgroundShift)
            - AppSettings.defaultSidebarBackgroundShift
        if offset == 0 { return "None" }
        return offset < 0 ? "Lighter \(-offset)" : "Darker \(offset)"
    }

    /// `.compact` is the default; `.normal`/`.hidden` write an explicit mode.
    private var toolbarMode: Binding<ToolbarMode> {
        Binding(get: { model.settings.effectiveToolbarMode },
                set: { model.setToolbarMode($0 == .compact ? nil : $0) })
    }

    /// nil (the default) reads as `defaultInactivePaneMuteStrength`.
    private var inactivePaneMuteStrength: Binding<Double> {
        Binding(get: { Double(model.settings.inactivePaneMuteStrength ?? AppSettings.defaultInactivePaneMuteStrength) },
                set: { let v = Int($0.rounded()); model.setInactivePaneMuteStrength(v == AppSettings.defaultInactivePaneMuteStrength ? nil : v) })
    }
}

/// Interface tab: per-element title-bar and sidebar chrome visibility, grouped by surface, two toggles per
/// row so the tab keeps fitting the fixed 540×640 window as the element set grows. Everything shows by
/// default; a toggle off adds it to `AppSettings.hiddenInterfaceElements` and live-applies — title-bar and
/// footer elements re-gate in open windows on `.agtermAppearanceChanged`, the add-session "+" on hover.
private struct InterfaceSettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            twoColumnSection("Title Bar", elements: InterfaceElement.allCases.filter { $0.section == .titleBar })
            twoColumnSection("Sidebar", elements: InterfaceElement.allCases.filter { $0.section == .sidebar })
            Section("Multiple Windows") {
                Toggle("Show sidebar only in the active window", isOn: autoHideSidebarInactiveWindows)
                    .accessibilityIdentifier("settings-auto-hide-inactive-sidebars")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Default OFF; ON hides the sidebar on every non-frontmost window.
    private var autoHideSidebarInactiveWindows: Binding<Bool> {
        Binding(get: { model.settings.autoHideSidebarInactiveWindows ?? false },
                set: { model.setAutoHideSidebarInactiveWindows($0 ? true : nil) })
    }

    /// A section whose toggles lay out TWO per row, each filling half the row around a centered `Divider` so
    /// the columns read as EVEN and visibly separated; an odd final element pairs with an empty half.
    @ViewBuilder
    private func twoColumnSection(_ title: String, elements: [InterfaceElement]) -> some View {
        Section(title) {
            ForEach(Array(stride(from: 0, to: elements.count, by: 2)), id: \.self) { start in
                HStack(spacing: 16) {
                    toggle(for: elements[start]).frame(maxWidth: .infinity)
                    Divider()
                    if start + 1 < elements.count {
                        toggle(for: elements[start + 1]).frame(maxWidth: .infinity)
                    } else {
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    /// One element's show/hide toggle: ON = visible (the default), so hiding is the opt-in that writes.
    private func toggle(for element: InterfaceElement) -> some View {
        Toggle(element.displayName, isOn: binding(for: element))
            .accessibilityIdentifier("settings-interface-\(element.rawValue)")
    }

    private func binding(for element: InterfaceElement) -> Binding<Bool> {
        Binding(get: { !model.settings.isInterfaceElementHidden(element) },
                set: { model.setInterfaceElementVisible(element, visible: $0) })
    }
}

/// Notifications tab: the banner / badge / attention-indicator toggles plus the Dock-bounce and sound
/// pickers. All independent — the badge count keeps tracking and a bounce or sound can fire with banners off.
private struct NotificationsSettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Show notification banners", isOn: notificationsEnabled)
                    .accessibilityIdentifier("settings-notifications")

                Toggle("Show notification badges", isOn: notificationBadgeEnabled)
                    .accessibilityIdentifier("settings-notification-badges")

                Picker("Bounce Dock icon", selection: dockBounce) {
                    Text("None").tag(DockBounce.off)
                    Text("Once").tag(DockBounce.once)
                    Text("Until focused").tag(DockBounce.untilFocused)
                }
                .accessibilityIdentifier("settings-dock-bounce")

                Picker("Notification sound", selection: notificationSound) {
                    Text("None").tag("None")
                    ForEach(StatusSoundPlayer.standardNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .accessibilityIdentifier("settings-notification-sound")

                Toggle("Show attention indicator", isOn: attentionButtonEnabled)
                    .accessibilityIdentifier("settings-attention-button")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Default ON.
    private var notificationsEnabled: Binding<Bool> {
        Binding(get: { model.settings.notificationsEnabled ?? true },
                set: { model.setNotificationsEnabled($0 ? nil : false) })
    }

    /// Default ON.
    private var notificationBadgeEnabled: Binding<Bool> {
        Binding(get: { model.settings.notificationBadgeEnabled ?? true },
                set: { model.setNotificationBadgeEnabled($0 ? nil : false) })
    }

    /// Resolves nil (the default) to `.off`.
    private var dockBounce: Binding<DockBounce> {
        Binding(get: { model.settings.effectiveDockBounce },
                set: { model.setDockBounce($0 == .off ? nil : $0) })
    }

    // the sound played when a notification is delivered; selecting one previews it, like macOS sound settings
    private var notificationSound: Binding<String> {
        Binding(get: { model.settings.notificationSoundName ?? "None" },
                set: { name in
                    let value = name == "None" ? nil : name
                    model.setNotificationSoundName(value)
                    if let value { StatusSoundPlayer.shared.action(for: value)?() }
                })
    }

    private var attentionButtonEnabled: Binding<Bool> {
        Binding(get: { model.settings.attentionButtonEnabled ?? false },
                set: { model.setAttentionButtonEnabled($0 ? true : nil) })
    }
}

/// Agent Status tab: Colors and Shapes (a row per state — active/blocked/completed — with that glyph's color
/// well and shape picker), Sound, Auto-follow (idle timeout + stay-on-active), and a Reset clearing all three.
private struct AgentStatusSettingsView: View {
    /// Gap between a glyph row's color well and its shape picker.
    private static let controlSpacing: CGFloat = 8
    /// Column width every shape picker reserves: a menu button sizes to the glyph it shows and the six
    /// silhouettes differ by a few points, so without a fixed column the color wells jog between rows. Snug
    /// enough to read as spacing, not a hole, with room above the widest silhouette's button.
    private static let shapePickerWidth: CGFloat = 80

    let model: SettingsModel

    var body: some View {
        Form {
            Section("Colors and Shapes") {
                glyphRow(.active)
                glyphRow(.blocked)
                glyphRow(.completed)
            }

            Section("Sound") {
                Picker("Blocked sound", selection: blockedStatusSound) {
                    Text("None").tag("None")
                    ForEach(StatusSoundPlayer.standardNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .accessibilityIdentifier("settings-status-blocked-sound")
            }

            Section("Auto-follow") {
                Picker("Auto-follow blocked sessions", selection: autoFollowAttention) {
                    Text("Disabled").tag(AppSettings.AutoFollowAttention.off)
                    Text("5 sec idle").tag(AppSettings.AutoFollowAttention.s5)
                    Text("10 sec idle").tag(AppSettings.AutoFollowAttention.s10)
                    Text("30 sec idle").tag(AppSettings.AutoFollowAttention.s30)
                    Text("60 sec idle").tag(AppSettings.AutoFollowAttention.s60)
                    Text("5 min idle").tag(AppSettings.AutoFollowAttention.m5)
                }
                .accessibilityIdentifier("settings-auto-follow")
                Toggle("Auto-follow away from a running session", isOn: autoFollowAwayFromRunning)
                    .accessibilityIdentifier("settings-auto-follow-stay-active")
                    .disabled(autoFollowAttention.wrappedValue == .off)
                SettingHint("Only applies while auto-follow is on.")
            }

            Section {
                Button("Reset to defaults") { model.resetAgentStatus() }
                    .accessibilityIdentifier("settings-status-reset")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// One state's glyph row: the state name labels it, with the color well and shape picker trailing, both
    /// label-hidden so the state name is the row's only visible label. The shape picker draws at the TRAILING
    /// edge of its fixed-width column so the row ends flush with the tab's right margin — the column's default
    /// center alignment left it floating inboard. Both bindings and both accessibility ids derive from the
    /// state argument, so a row cannot label one status while driving another's setting.
    private func glyphRow(_ status: AgentStatus) -> some View {
        let color = statusColor(for: status)
        let shape = statusShape(for: status)
        return LabeledContent(status.rawValue.capitalized) {
            HStack(spacing: Self.controlSpacing) {
                ColorPicker("Color", selection: color, supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityIdentifier("settings-status-\(status.rawValue)")
                Picker("Shape", selection: shape) { shapeOptions(tint: NSColor(color.wrappedValue)) }
                    .labelsHidden()
                    .frame(width: Self.shapePickerWidth, alignment: .trailing)
                    .accessibilityIdentifier("settings-status-shape-\(status.rawValue)")
                    .accessibilityValue(shape.wrappedValue.displayName)
            }
        }
    }

    // binds to the resolved color (the user's hex or the system default); a pick stores the sRGB hex, and
    // "Reset to defaults" clears it back to nil, the system color.
    private func statusColor(for status: AgentStatus) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(agtermHex: storedColorHex(for: status)) ?? Self.defaultColor(for: status)) },
                set: { setColorHex(NSColor($0).agtermHexString, for: status) })
    }

    private func storedColorHex(for status: AgentStatus) -> String? {
        switch status {
        case .active: return model.settings.activeStatusColorHex
        case .blocked: return model.settings.blockedStatusColorHex
        case .completed: return model.settings.completedStatusColorHex
        case .idle: return nil
        }
    }

    private static func defaultColor(for status: AgentStatus) -> NSColor {
        switch status {
        case .active: return GhosttyApp.defaultActiveStatusColor
        case .blocked: return .systemOrange
        case .completed: return .systemGreen
        case .idle: return .clear
        }
    }

    private func setColorHex(_ hex: String?, for status: AgentStatus) {
        switch status {
        case .active: model.setActiveStatusColorHex(hex)
        case .blocked: model.setBlockedStatusColorHex(hex)
        case .completed: model.setCompletedStatusColorHex(hex)
        case .idle: break
        }
    }

    /// The options one shape picker shows: one per `StatusShape` from `allCases`, so it cannot drift from the
    /// enum. Each entry is the symbol ALONE (a name beside it crowds the row), with the shape name kept as its
    /// accessibility label for VoiceOver; `tint` is the row's live glyph color, so a color change redraws them.
    @ViewBuilder
    private func shapeOptions(tint: NSColor) -> some View {
        ForEach(StatusShape.allCases, id: \.self) { shape in
            Image(nsImage: Self.shapeImage(shape, tint: tint))
                .accessibilityLabel(shape.displayName)
                .tag(shape)
        }
    }

    /// One picker option's glyph, drawn like the sidebar's: the symbol at the sidebar glyph point size, tinted
    /// with the status's current color. NON-template — a menu recolors a template symbol to its own text color
    /// and would wash out the previewed tint.
    private static func shapeImage(_ shape: StatusShape, tint: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: StatusIconView.glyphPointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: shape.symbolName, accessibilityDescription: shape.displayName)?
            .withSymbolConfiguration(config) else {
            // a blank option row would silently offer an un-pickable-looking shape, so say which symbol failed
            logger.error("no SF Symbol for status shape \(shape.rawValue, privacy: .public)")
            return NSImage()
        }
        image.isTemplate = false
        return image
    }

    // the default plain circle maps back to nil; nil and `circle` render identically
    private func statusShape(for status: AgentStatus) -> Binding<StatusShape> {
        Binding(get: { model.settings.effectiveStatusShape(for: status) ?? .circle },
                set: { setShape($0 == .circle ? nil : $0, for: status) })
    }

    private func setShape(_ shape: StatusShape?, for status: AgentStatus) {
        switch status {
        case .active: model.setActiveStatusShape(shape)
        case .blocked: model.setBlockedStatusShape(shape)
        case .completed: model.setCompletedStatusShape(shape)
        case .idle: break
        }
    }

    // the sound played when a session enters `blocked`; selecting one previews it, like the notification sound
    private var blockedStatusSound: Binding<String> {
        Binding(get: { model.settings.blockedStatusSoundName ?? "None" },
                set: { name in
                    let value = name == "None" ? nil : name
                    model.setBlockedStatusSoundName(value)
                    if let value { StatusSoundPlayer.shared.action(for: value)?() }
                })
    }

    /// The auto-follow idle timeout; nil (the default) or an unknown stored value resolves to `.off`.
    private var autoFollowAttention: Binding<AppSettings.AutoFollowAttention> {
        Binding(get: { AppSettings.AutoFollowAttention(tolerant: model.settings.autoFollowAttention) },
                set: { model.setAutoFollowAttention($0 == .off ? nil : $0.rawValue) })
    }

    /// Inverted view of the stored `autoFollowStayOnActive` so the toggle reads forward — ON = do leave a
    /// running session — instead of a double negative. The nil default means "follow away", so it shows ON.
    private var autoFollowAwayFromRunning: Binding<Bool> {
        Binding(get: { !(model.settings.autoFollowStayOnActive ?? false) },
                set: { model.setAutoFollowStayOnActive($0 ? nil : true) })
    }
}

/// Key Mapping tab: the config directory holding `keymap.conf` (picker + "Use Default"), a read-only
/// parse-diagnostics list, and Reload. Both route through `SettingsModel`, which re-reads and re-parses the
/// keymap and posts the change, updating the menu shortcuts, custom-command runner and action palette.
private struct KeyMappingSettingsView: View {
    let model: SettingsModel

    /// The resolved config directory shown in the field: the explicit setting, else `AGTERM_STATE_DIR/config`
    /// under test isolation, else `~/.config/agterm` — matching `SettingsModel`'s own resolution.
    private var configDirectoryPath: String {
        ConfigPaths.configDirectory(
            setting: model.settings.configDirectory,
            stateDir: ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"],
            home: FileManager.default.homeDirectoryForCurrentUser).path
    }

    var body: some View {
        Form {
            Section("Config Directory") {
                HStack {
                    Text(configDirectoryPath)
                        .font(.system(size: 12).monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings-keymap-directory")
                    Spacer()
                    Button("Choose…") { chooseDirectory() }
                        .accessibilityIdentifier("settings-keymap-choose")
                    if model.settings.configDirectory != nil {
                        Button("Use Default") { model.setConfigDirectory(nil) }
                            .accessibilityIdentifier("settings-keymap-default")
                    }
                }
                Text("The directory holding keymap.conf. Changing it reloads the keymap.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                if model.keymapDiagnostics.isEmpty {
                    Text("No issues.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-keymap-diagnostics")
                        .accessibilityValue(diagnosticsSummary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.keymapDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text(diagnosticLine(diagnostic))
                                .font(.system(size: 12).monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings-keymap-diagnostics")
                    .accessibilityValue(diagnosticsSummary)
                }
                Button("Reload") { model.reloadKeymap() }
                    .accessibilityIdentifier("settings-keymap-reload")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// A diagnostic as one line, "line N: message"; a whole-file/cross-section one (line 0) shows the message.
    private func diagnosticLine(_ diagnostic: KeymapDiagnostic) -> String {
        diagnostic.line > 0 ? "line \(diagnostic.line): \(diagnostic.message)" : diagnostic.message
    }

    /// The diagnostics joined into one accessibility value, so a UI test reads the full content from the
    /// container without scrolling each row into view. "No issues." when empty.
    private var diagnosticsSummary: String {
        model.keymapDiagnostics.isEmpty ? "No issues." : model.keymapDiagnostics.map(diagnosticLine).joined(separator: " | ")
    }

    /// Pick a config directory with the standard open panel (directories only), then persist + reload.
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = DirectoryPanelDefaults.url(paths: configDirectoryPath, model.activeSessionCwd)
        panel.prompt = "Choose"
        panel.message = "Choose a directory for keymap.conf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setConfigDirectory(url.path)
    }
}
