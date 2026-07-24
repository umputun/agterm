import agtermCore
import AppKit
import SwiftUI

/// The Settings window (Cmd+,): six tabs — General (mouse, sessions, ghostty config),
/// Appearance (font/theme + window translucency + pane dimming), Interface (per-element title-bar and
/// sidebar chrome visibility), Notifications (banner / badge / attention toggles), Agent Status
/// (the sidebar glyph colors + blocked sound + auto-follow), and Key Mapping (the config directory +
/// keymap diagnostics + Reload).
struct SettingsView: View {
    let model: SettingsModel

    /// Identifies each tab. An explicit selection binding is what keeps the window opening on General:
    /// without it, SwiftUI's Settings scene auto-persists the last tab to `selectedTabIndex` in user
    /// defaults and restores it next launch, which we don't want for a settings window.
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
        .frame(width: 540, height: 590)
        // keep macOS from saving/restoring the Settings window across launches. Otherwise a
        // process-launch reopen (see agtermApp's FB11763863 workaround) resurrects a stale Settings
        // window on whatever tab it was last on, which steals key focus from the real launch window.
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

/// A terse one-line caption shown under a control. Kept short on purpose: only non-obvious controls
/// carry one, so the tabs stay short enough to fit without scrolling.
private struct SettingHint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

/// General tab: a Mouse section (scroll speed + right-click-pastes toggle), a Sessions section (the
/// new-session directory picker + restore-running-commands toggle), and the inherit-global-ghostty-config
/// toggle. The visual and notification settings live on their own tabs.
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

    /// 1:1 with the toggle; nil (the default) reads as OFF, so on → true / off → nil keeps settings.json
    /// minimal until the user opts in.
    private var restoreRunningCommand: Binding<Bool> {
        Binding(get: { model.settings.restoreRunningCommand ?? false },
                set: { model.setRestoreRunningCommand($0 ? true : nil) })
    }

    /// 1:1 with the toggle; nil (the default) reads as OFF, so on → true / off → nil keeps settings.json
    /// minimal until the user opts into the close confirmation.
    private var confirmCloseSession: Binding<Bool> {
        Binding(get: { model.settings.confirmCloseSession ?? false },
                set: { model.setConfirmCloseSession($0 ? true : nil) })
    }

    /// nil (the default) reads as ON; turning it off stores false and makes GUI closes immediate.
    private var closeGraceUndoEnabled: Binding<Bool> {
        Binding(get: { model.settings.closeGraceUndoEnabled ?? true },
                set: { model.setCloseGraceUndoEnabled($0 ? nil : false) })
    }

    /// 1:1 with the toggle; nil (the default) reads as OFF, so on → true / off → nil keeps settings.json
    /// minimal until the user opts into inheriting the global ghostty config.
    private var inheritGlobalGhosttyConfig: Binding<Bool> {
        Binding(get: { model.settings.inheritGlobalGhosttyConfig ?? false },
                set: { model.setInheritGlobalGhosttyConfig($0 ? true : nil) })
    }

    /// 1:1 with the toggle; nil (the default) reads as ON, so off → false / on → nil keeps settings.json
    /// minimal. Drives the ghostty `right-click-action` key (paste when on, ignore when off).
    private var rightClickPaste: Binding<Bool> {
        Binding(get: { model.settings.rightClickPaste ?? true },
                set: { model.setRightClickPaste($0 ? nil : false) })
    }

    /// nil (the default) reads as 3; stepping back to 3 stores nil so settings.json stays minimal. The
    /// config always emits 3 either way, so the default speed is effective regardless.
    private var mouseScrollMultiplier: Binding<Double> {
        Binding(get: { model.settings.mouseScrollMultiplier ?? 3 },
                set: { model.setMouseScrollMultiplier($0 == 3 ? nil : $0) })
    }

    /// The custom directory to display, treating nil OR empty as "unset" (nil) to match
    /// `resolveNewSessionCwd`, which falls back to home for both. So a blank value from a hand-edited
    /// `settings.json` renders as "Not set" rather than a blank primary-styled path.
    private var customDirectory: String? {
        let dir = model.settings.newSessionCustomDirectory
        return dir?.isEmpty == false ? dir : nil
    }

    /// The new-session directory mode; nil (the default) reads as `.home`, and picking `.home` stores nil
    /// so settings.json stays minimal. An unknown stored value also resolves to `.home`.
    private var newSessionDirectory: Binding<AppSettings.NewSessionDirectory> {
        Binding(get: { AppSettings.NewSessionDirectory(rawValue: model.settings.newSessionDirectory ?? "") ?? .home },
                set: { model.setNewSessionDirectory($0 == .home ? nil : $0.rawValue) })
    }

    /// Pick the fixed directory for the `custom` new-session mode with the standard open panel
    /// (directories only), then persist it.
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

/// Appearance tab: a Terminal section (font family, default font size, theme) and a Window section
/// (toolbar mode — Normal/Compact/Hidden, background opacity + blur, sidebar tint, sidebar font size,
/// inactive-pane dimming). Each control persists and live-applies through `SettingsModel`.
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

                // the theme for the CURRENT appearance. While following, this edits the on-screen side
                // (dark in dark mode, light in light mode); the "default ghostty" row is offered only
                // when NOT following, since a dual conditional needs two named themes.
                Picker("Theme", selection: themeForCurrentAppearance) {
                    if !following { Text("default ghostty").tag(String?.none) }
                    ForEach(themes, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .accessibilityIdentifier("settings-theme")

                Toggle("Follow system appearance", isOn: followSystemAppearance)
                    .accessibilityIdentifier("settings-follow-appearance")

                // revealed only when following: the theme for the OTHER appearance. ghostty resolves the
                // active side at runtime, so no config rewrite happens on a light/dark flip.
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
                    Text("Sidebar font size: \(Int(model.settings.sidebarFontSize ?? AppSettings.defaultSidebarFontSize))")
                }
                .accessibilityIdentifier("settings-sidebar-font-size")

                HStack {
                    Text("Inactive pane mute")
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

    /// The sidebar row-text size; the default maps back to nil so `settings.json` stays minimal.
    private var sidebarFontSize: Binding<Double> {
        Binding(get: { model.settings.sidebarFontSize ?? AppSettings.defaultSidebarFontSize },
                set: { model.setSidebarFontSize($0 == AppSettings.defaultSidebarFontSize ? nil : $0) })
    }

    /// Whether the terminal follows the macOS appearance — reveals the alternate picker.
    private var following: Bool { model.settings.followSystemAppearance == true }

    /// Picker 1: the theme for the CURRENT appearance (dark slot while following in dark mode, else
    /// `theme`). Drives `SettingsModel.setThemeForCurrentAppearance`.
    private var themeForCurrentAppearance: Binding<String?> {
        Binding(get: { model.settings.activeTheme(isDark: GhosttyApp.currentIsDark()) },
                set: { model.setThemeForCurrentAppearance($0) })
    }

    /// Picker 2 (shown only while following): the OTHER appearance's theme — the light slot in dark mode,
    /// the dark slot in light mode. Drives `SettingsModel.setAlternateTheme`.
    private var alternateTheme: Binding<String?> {
        Binding(get: { GhosttyApp.currentIsDark() ? model.settings.theme : model.settings.darkTheme },
                set: { model.setAlternateTheme($0) })
    }

    /// The "Follow system appearance" toggle — seeds/collapses the two slots via
    /// `SettingsModel.setFollowSystemAppearance`.
    private var followSystemAppearance: Binding<Bool> {
        Binding(get: { model.settings.followSystemAppearance == true },
                set: { model.setFollowSystemAppearance($0) })
    }

    /// 1.0 maps to nil (the opaque default) so settings.json stays minimal and the "unset = default"
    /// convention matches the font/theme controls. The setter PREVIEWS live (apply without save) on
    /// every drag tick and debounces the write; the slider's `onEditingChanged` flushes it on release.
    private var backgroundOpacity: Binding<Double> {
        Binding(get: { model.settings.backgroundOpacity ?? 1 },
                set: { model.previewBackgroundOpacity($0 >= 1 ? nil : $0) })
    }

    /// PREVIEWS live (apply without save) on every drag tick and debounces the write; the slider's
    /// `onEditingChanged` flushes it on release.
    private var backgroundBlur: Binding<Double> {
        Binding(get: { Double(model.settings.backgroundBlur ?? 0) },
                set: { model.previewBackgroundBlur($0 <= 0 ? nil : Int($0.rounded())) })
    }

    /// neutral (5) maps to nil so settings.json stays minimal, matching the other appearance controls'
    /// "unset = default" convention.
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

    /// `.compact` (the default) maps back to nil so settings.json stays minimal, matching the other
    /// appearance controls' "unset = default" convention; `.normal`/`.hidden` write an explicit mode.
    private var toolbarMode: Binding<ToolbarMode> {
        Binding(get: { model.settings.effectiveToolbarMode },
                set: { model.setToolbarMode($0 == .compact ? nil : $0) })
    }

    /// nil (the default) reads as `defaultInactivePaneMuteStrength`; sliding back to it stores nil so
    /// settings.json stays minimal. The slider is integer-stepped, so the Double is rounded to an Int.
    private var inactivePaneMuteStrength: Binding<Double> {
        Binding(get: { Double(model.settings.inactivePaneMuteStrength ?? AppSettings.defaultInactivePaneMuteStrength) },
                set: { let v = Int($0.rounded()); model.setInactivePaneMuteStrength(v == AppSettings.defaultInactivePaneMuteStrength ? nil : v) })
    }
}

/// Interface tab: per-element visibility of the window's title-bar and sidebar chrome, grouped by
/// surface (Title Bar / Sidebar) and laid out two toggles per row so the tab keeps fitting the fixed
/// 540×590 Settings window without scrolling as the element set grows. Every element is shown by default;
/// a toggle off adds it to `AppSettings.hiddenInterfaceElements`. Each toggle live-applies through
/// `SettingsModel`; the title-bar and footer elements re-gate in every open window via
/// `.agtermAppearanceChanged`, while the hover-only workspace add-session "+" re-gates on its next hover.
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

    /// Default-OFF binding: ON hides the sidebar on every non-frontmost window (writes true), OFF maps back
    /// to nil to keep `settings.json` minimal — the default-off idiom shared with the other opt-in toggles.
    private var autoHideSidebarInactiveWindows: Binding<Bool> {
        Binding(get: { model.settings.autoHideSidebarInactiveWindows ?? false },
                set: { model.setAutoHideSidebarInactiveWindows($0 ? true : nil) })
    }

    /// A section whose toggles lay out TWO per row, so the tab keeps fitting the fixed Settings window
    /// without scrolling as the `InterfaceElement` set grows. Each toggle fills half the row around a
    /// centered `Divider`, so the two columns read as EVEN and visibly separated (each column's switch
    /// trails at its own right edge); an odd final element pairs with an empty half.
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

    /// A show/hide toggle for one element: ON = visible (the default), so hiding it is the opt-in that
    /// writes to `hiddenInterfaceElements`.
    private func toggle(for element: InterfaceElement) -> some View {
        Toggle(element.displayName, isOn: binding(for: element))
            .accessibilityIdentifier("settings-interface-\(element.rawValue)")
    }

    private func binding(for element: InterfaceElement) -> Binding<Bool> {
        Binding(get: { !model.settings.isInterfaceElementHidden(element) },
                set: { model.setInterfaceElementVisible(element, visible: $0) })
    }
}

/// Notifications tab: the banner / badge / attention-indicator toggles plus the Dock-bounce mode and
/// notification-sound pickers, all default-driven through `SettingsModel`. The controls are independent —
/// the badge count keeps tracking whether or not banners are shown, and a Dock bounce or a sound can
/// fire whether or not banners are shown.
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

    /// 1:1 with the toggle; nil (the default) reads as on, so settings.json stays minimal until the
    /// user turns banners off.
    private var notificationsEnabled: Binding<Bool> {
        Binding(get: { model.settings.notificationsEnabled ?? true },
                set: { model.setNotificationsEnabled($0 ? nil : false) })
    }

    /// 1:1 with the toggle; nil (the default) reads as on, so settings.json stays minimal until the
    /// user hides the count badges.
    private var notificationBadgeEnabled: Binding<Bool> {
        Binding(get: { model.settings.notificationBadgeEnabled ?? true },
                set: { model.setNotificationBadgeEnabled($0 ? nil : false) })
    }

    /// Resolves nil (the default) to `.off`; selecting None maps back to nil so settings.json stays
    /// minimal until the user picks a bounce mode. Mirrors the toolbar-mode picker binding.
    private var dockBounce: Binding<DockBounce> {
        Binding(get: { model.settings.effectiveDockBounce },
                set: { model.setDockBounce($0 == .off ? nil : $0) })
    }

    // the system sound played when a notification is delivered; "None" maps to nil. Selecting a sound
    // previews it so you hear the choice, the way macOS sound settings do.
    private var notificationSound: Binding<String> {
        Binding(get: { model.settings.notificationSoundName ?? "None" },
                set: { name in
                    let value = name == "None" ? nil : name
                    model.setNotificationSoundName(value)
                    if let value { StatusSoundPlayer.shared.action(for: value)?() }
                })
    }

    /// 1:1 with the toggle; nil (the default) reads as OFF, so on → true / off → nil keeps settings.json
    /// minimal until the user opts into the title-bar attention bell.
    private var attentionButtonEnabled: Binding<Bool> {
        Binding(get: { model.settings.attentionButtonEnabled ?? false },
                set: { model.setAttentionButtonEnabled($0 ? true : nil) })
    }
}

/// Agent Status tab: a Colors section (the three sidebar glyph colors — active / blocked /
/// completed), a Sound section (the blocked sound), an Auto-follow section (the idle-timeout picker +
/// stay-on-active toggle), and a trailing Reset that clears the colors and sound back to their defaults.
private struct AgentStatusSettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Colors") {
                ColorPicker("Active", selection: activeStatusColor, supportsOpacity: false)
                    .accessibilityIdentifier("settings-status-active")
                ColorPicker("Blocked", selection: blockedStatusColor, supportsOpacity: false)
                    .accessibilityIdentifier("settings-status-blocked")
                ColorPicker("Completed", selection: completedStatusColor, supportsOpacity: false)
                    .accessibilityIdentifier("settings-status-completed")
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

    // each ColorPicker binds to the resolved color (the user's hex or the system default); a pick
    // stores the sRGB hex, and "Reset to defaults" clears the hex back to nil (the system color).
    private var activeStatusColor: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(agtermHex: model.settings.activeStatusColorHex) ?? GhosttyApp.defaultActiveStatusColor) },
                set: { model.setActiveStatusColorHex(NSColor($0).agtermHexString) })
    }

    private var blockedStatusColor: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(agtermHex: model.settings.blockedStatusColorHex) ?? .systemOrange) },
                set: { model.setBlockedStatusColorHex(NSColor($0).agtermHexString) })
    }

    private var completedStatusColor: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(agtermHex: model.settings.completedStatusColorHex) ?? .systemGreen) },
                set: { model.setCompletedStatusColorHex(NSColor($0).agtermHexString) })
    }

    // the system sound played when a session enters `blocked`; "None" maps to nil. Selecting a sound
    // previews it so you hear the choice, the way macOS sound settings do.
    private var blockedStatusSound: Binding<String> {
        Binding(get: { model.settings.blockedStatusSoundName ?? "None" },
                set: { name in
                    let value = name == "None" ? nil : name
                    model.setBlockedStatusSoundName(value)
                    if let value { StatusSoundPlayer.shared.action(for: value)?() }
                })
    }

    /// The auto-follow idle timeout; nil (the default) reads as `.off`, and picking `.off` stores nil so
    /// settings.json stays minimal. An unknown stored value also resolves to `.off`.
    private var autoFollowAttention: Binding<AppSettings.AutoFollowAttention> {
        Binding(get: { AppSettings.AutoFollowAttention(tolerant: model.settings.autoFollowAttention) },
                set: { model.setAutoFollowAttention($0 == .off ? nil : $0.rawValue) })
    }

    /// Inverted view of the stored `autoFollowStayOnActive` so the toggle reads forward ("auto-follow away"
    /// ON = do leave a running session) instead of a double negative. The stored default nil means "follow
    /// away", so the toggle shows ON by default; opting to STAY (toggle OFF) stores `true`, and toggling back
    /// to the follow-away default stores nil to keep settings.json minimal.
    private var autoFollowAwayFromRunning: Binding<Bool> {
        Binding(get: { !(model.settings.autoFollowStayOnActive ?? false) },
                set: { model.setAutoFollowStayOnActive($0 ? nil : true) })
    }
}

/// Key Mapping tab: the config directory holding `keymap.conf` (with a directory picker + "Use
/// Default"), a read-only list of parse diagnostics, and a Reload button. The directory and Reload
/// route through `SettingsModel`, which re-reads + re-parses the keymap and posts the change so the
/// data-driven menu shortcuts, the custom-command runner, and the action palette all update.
private struct KeyMappingSettingsView: View {
    let model: SettingsModel

    /// The resolved config directory shown in the field: the explicit setting when set, else the
    /// default location (`AGTERM_STATE_DIR/config` under test isolation, else `~/.config/agterm`),
    /// matching `SettingsModel`'s own resolution.
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

    /// A diagnostic as one line: "line N: message". A whole-file/cross-section diagnostic (line 0)
    /// drops the line number, showing just the message.
    private func diagnosticLine(_ diagnostic: KeymapDiagnostic) -> String {
        diagnostic.line > 0 ? "line \(diagnostic.line): \(diagnostic.message)" : diagnostic.message
    }

    /// The diagnostics exposed as one accessibility value (each line joined), so a UI test can read
    /// the full content from the container without scrolling each row into view. "No issues." when empty.
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
