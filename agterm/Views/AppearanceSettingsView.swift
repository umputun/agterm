import agtermCore
import SwiftUI

/// Appearance tab: Terminal (font family, size, cursor, theme) and Window (toolbar mode, background opacity + blur,
/// sidebar tint + font size, pane/backdrop mute), each persisting and live-applying via `SettingsModel`.
struct AppearanceSettingsView: View {
    let model: SettingsModel
    private let themes = SettingsCatalog.themeNames()
    private let fonts = SettingsCatalog.monospacedFontFamilies()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Form {
            Section("Terminal") {
                HStack(spacing: 16) {
                    Picker("Font name", selection: fontFamily) {
                        Text("Default").tag(String?.none)
                        ForEach(fonts, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .accessibilityIdentifier("settings-font-family")
                    .frame(maxWidth: .infinity)

                    Divider()

                    Stepper(value: fontSize, in: 8 ... 32, step: 1) {
                        Text("Font size: \(Int(model.settings.fontSize ?? 13))")
                    }
                    .accessibilityIdentifier("settings-font-size")
                    .frame(maxWidth: .infinity)
                }

                HStack(spacing: 16) {
                    // "Default" is a state, not a synonym for Block: it emits no `cursor-style`, so the
                    // config chain still picks the shape, where Block writes an override that beats it.
                    Picker("Cursor shape", selection: cursorStyle) {
                        Text("Default").tag(AppSettings.CursorStyle?.none)
                        Text("Block").tag(AppSettings.CursorStyle?.some(.block))
                        Text("Bar").tag(AppSettings.CursorStyle?.some(.bar))
                        Text("Underline").tag(AppSettings.CursorStyle?.some(.underline))
                    }
                    .accessibilityIdentifier("settings-cursor-style")
                    .frame(maxWidth: .infinity)

                    Divider()

                    // three rows, not a toggle: Default emits nothing, which is the only state that leaves
                    // DEC mode 12 able to drive the blink.
                    Picker("Cursor blink", selection: cursorBlink) {
                        Text("Default").tag(Bool?.none)
                        Text("Blink").tag(Bool?.some(true))
                        Text("Steady").tag(Bool?.some(false))
                    }
                    .accessibilityIdentifier("settings-cursor-blink")
                    .frame(maxWidth: .infinity)
                }

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
                Toggle("Ignore Reduce Transparency", isOn: ignoreReduceTransparency)
                    .accessibilityIdentifier("settings-ignore-reduce-transparency")
                if AppSettings.windowReducesTransparency(system: reduceTransparency,
                                                         ignoring: model.settings.ignoreReduceTransparency == true) {
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

                Picker("Sidebar density", selection: sidebarDensity) {
                    ForEach(SidebarDensity.allCases, id: \.self) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                .accessibilityIdentifier("settings-sidebar-density")

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

    /// nil is the From config row; a shape this version does not offer (a future one, or a hand-written
    /// `block_hollow`) resolves to nil too, so the picker shows From config rather than a blank selection.
    private var cursorStyle: Binding<AppSettings.CursorStyle?> {
        Binding(get: { model.settings.effectiveCursorStyle }, set: { model.setCursorStyle($0) })
    }

    /// Passed through as ghostty's own three states; nil is Program controlled (see `AppSettings.cursorBlink`).
    private var cursorBlink: Binding<Bool?> {
        Binding(get: { model.settings.cursorBlink }, set: { model.setCursorBlink($0) })
    }

    /// The sidebar row-text size.
    private var sidebarFontSize: Binding<Double> {
        Binding(get: { model.settings.effectiveSidebarFontSize },
                set: { model.setSidebarFontSize($0 == AppSettings.defaultSidebarFontSize ? nil : $0) })
    }

    private var sidebarDensity: Binding<SidebarDensity> {
        Binding(get: { model.settings.effectiveSidebarDensity }, set: { model.setSidebarDensity($0) })
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

    private var ignoreReduceTransparency: Binding<Bool> {
        Binding(get: { model.settings.ignoreReduceTransparency == true },
                set: { model.setIgnoreReduceTransparency($0 ? true : nil) })
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
