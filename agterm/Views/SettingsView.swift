import agtermCore
import AppKit
import SwiftUI

/// The Settings window (Cmd+,): three tabs — General (notifications), Appearance (font/theme +
/// window translucency), and Key Mapping (the config directory + keymap diagnostics + Reload).
struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView(model: model)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            KeyMappingSettingsView(model: model)
                .tabItem { Label("Key Mapping", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 560)
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

/// General tab: the macOS notification-banner toggle and the sidebar unseen-count badge toggle (both
/// default on). The two are independent — the count keeps tracking notifications whether or not
/// banners are shown, and hiding the count badge is render-only (it reappears with the current count
/// when re-enabled) and never affects the agent-status glyph.
private struct GeneralSettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Show notification banners", isOn: notificationsEnabled)
                    .accessibilityIdentifier("settings-notifications")
                Text("Terminal desktop notifications (OSC 9 / 777) appear in macOS Notification Center. The sidebar badge tracks them either way.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Toggle("Show notification badges", isOn: notificationBadgeEnabled)
                    .accessibilityIdentifier("settings-notification-badges")
                Text("The red unseen-count pill on sidebar rows. The count keeps tracking either way, so it reappears with the current count when turned back on.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Scrolling") {
                HStack {
                    Text("Scroll speed")
                    Slider(value: mouseScrollMultiplier, in: 1 ... 10, step: 1)
                        .accessibilityIdentifier("settings-scroll-speed")
                    Text("\(Int(model.settings.mouseScrollMultiplier ?? 3))x")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                Text("Mouse-wheel and trackpad scroll-speed multiplier. Higher is faster; the default is 3.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Panes") {
                HStack {
                    Text("Inactive pane mute")
                    Slider(value: inactivePaneMuteStrength, in: 0 ... 10, step: 1)
                        .accessibilityIdentifier("settings-inactive-pane-mute")
                    Text("\(model.settings.inactivePaneMuteStrength ?? AppSettings.defaultInactivePaneMuteStrength)")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                Text("How much the inactive split pane's text is dimmed (0 = off, 10 = extreme). The background is left unchanged.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

    /// nil (the default) reads as 3; stepping back to 3 stores nil so settings.json stays minimal. The
    /// config always emits 3 either way, so the default speed is effective regardless.
    private var mouseScrollMultiplier: Binding<Double> {
        Binding(get: { model.settings.mouseScrollMultiplier ?? 3 },
                set: { model.setMouseScrollMultiplier($0 == 3 ? nil : $0) })
    }

    /// nil (the default) reads as `defaultInactivePaneMuteStrength`; sliding back to it stores nil so
    /// settings.json stays minimal. The slider is integer-stepped, so the Double is rounded to an Int.
    private var inactivePaneMuteStrength: Binding<Double> {
        Binding(get: { Double(model.settings.inactivePaneMuteStrength ?? AppSettings.defaultInactivePaneMuteStrength) },
                set: { let v = Int($0.rounded()); model.setInactivePaneMuteStrength(v == AppSettings.defaultInactivePaneMuteStrength ? nil : v) })
    }
}

/// Appearance tab: a Terminal section (font family, default font size, theme), a Window section
/// (compact toolbar, background opacity + blur, sidebar tint), and an Agent Status section (the three
/// sidebar glyph colors). Each control persists and live-applies through `SettingsModel`.
private struct AppearanceSettingsView: View {
    let model: SettingsModel
    private let themes = SettingsCatalog.themeNames()
    private let fonts = SettingsCatalog.monospacedFontFamilies()

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

                Picker("Theme", selection: theme) {
                    Text("Default").tag(String?.none)
                    ForEach(themes, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .accessibilityIdentifier("settings-theme")
            }

            Section("Window") {
                Toggle("Compact toolbar", isOn: compactToolbar)
                    .accessibilityIdentifier("settings-compact-toolbar")
                Text("A shorter title bar with smaller icons; hides the working-directory subtitle.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

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

                Text("Blur only takes effect when opacity is below 100%.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Sidebar Tint")
                    Slider(value: sidebarBackgroundShift, in: 0 ... 10, step: 1)
                        .accessibilityIdentifier("settings-sidebar-shift")
                    Text(sidebarShiftLabel)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }

                Text("Tints the sidebar background lighter or darker than the terminal. Center is no change.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Agent Status") {
                ColorPicker("Active", selection: activeStatusColor, supportsOpacity: false)
                    .accessibilityIdentifier("settings-status-active")
                ColorPicker("Blocked", selection: blockedStatusColor, supportsOpacity: false)
                    .accessibilityIdentifier("settings-status-blocked")
                ColorPicker("Completed", selection: completedStatusColor, supportsOpacity: false)
                    .accessibilityIdentifier("settings-status-completed")
                Button("Reset to defaults") { model.resetStatusColors() }
                    .accessibilityIdentifier("settings-status-reset")
                Text("Colors for the per-session agent-status glyph in the sidebar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

    private var theme: Binding<String?> {
        Binding(get: { model.settings.theme }, set: { model.setTheme($0) })
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

    /// off (the default) maps to nil so settings.json stays minimal, matching the other appearance
    /// controls' "unset = default" convention.
    private var compactToolbar: Binding<Bool> {
        Binding(get: { model.settings.compactToolbar ?? false },
                set: { model.setCompactToolbar($0 ? true : nil) })
    }

    // each ColorPicker binds to the resolved color (the user's hex or the system default); a pick
    // stores the sRGB hex, and "Reset to defaults" clears the hex back to nil (the system color).
    private var activeStatusColor: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(agtermHex: model.settings.activeStatusColorHex) ?? .systemBlue) },
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
        panel.prompt = "Choose"
        panel.message = "Choose a directory for keymap.conf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setConfigDirectory(url.path)
    }
}
