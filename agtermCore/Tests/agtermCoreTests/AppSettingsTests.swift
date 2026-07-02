import Foundation
import Testing
@testable import agtermCore

struct AppSettingsTests {
    @Test func jsonRoundTrips() throws {
        let original = AppSettings(fontFamily: "SF Mono", fontSize: 14, theme: "Adwaita Dark")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test func fileMissingAFieldStillDecodes() throws {
        // a settings.json written before `theme` existed: only font-size present.
        let json = #"{ "fontSize": 16 }"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.fontSize == 16)
        #expect(decoded.fontFamily == nil)
        #expect(decoded.theme == nil)
    }

    @Test func emptySettingsEmitOnlyAlwaysOnDefaults() {
        // every other field is unset (omitted); only the two always-on keys emit — mouse-scroll-multiplier
        // at its default of 3 and right-click-action at its default of paste.
        #expect(AppSettings().ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func configLinesCoverSetFieldsRawNoQuoting() {
        let settings = AppSettings(fontFamily: "SF Mono", fontSize: 14, theme: "3024 Night")
        let lines = settings.ghosttyConfigLines()
        // raw values — names with spaces are NOT quoted (ghostty takes the line remainder).
        #expect(lines.contains("font-family = SF Mono"))
        #expect(lines.contains("theme = 3024 Night"))
        #expect(lines.contains("font-size = 14")) // integer renders without ".0"
    }

    @Test func configLinesOmitUnsetFields() {
        let lines = AppSettings(theme: "Alabaster").ghosttyConfigLines()
        // theme is set; font lines omitted; the always-on defaults (scroll + right-click) trail.
        #expect(lines == ["theme = Alabaster", "mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func fractionalFontSizeKeepsDecimal() {
        let lines = AppSettings(fontSize: 13.5).ghosttyConfigLines()
        #expect(lines == ["font-size = 13.5", "mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func backgroundFieldsRoundTrip() throws {
        let original = AppSettings(backgroundOpacity: 0.63, backgroundBlur: 20)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func translucentOpacityPinsRendererTransparent() {
        let lines = AppSettings(backgroundOpacity: 0.63).ghosttyConfigLines()
        #expect(lines.contains("background-opacity = 0"))
        #expect(lines.contains("background-blur = 0"))
    }

    @Test func opaqueOrUnsetOpacityEmitsNoBackgroundPins() {
        // full opacity, unset opacity, and a blur with no translucency all render normally: ghostty
        // paints its own background (blur needs opacity < 1 to be visible). none emit the background
        // pins (the always-present scroll default means the line set is not empty).
        for settings in [AppSettings(backgroundOpacity: 1), AppSettings(), AppSettings(backgroundBlur: 40)] {
            let lines = settings.ghosttyConfigLines()
            #expect(!lines.contains("background-opacity = 0"))
            #expect(!lines.contains("background-blur = 0"))
        }
    }

    @Test func mouseScrollMultiplierAlwaysEmittedAtDefaultThree() {
        // unset → the default 3 is emitted (NOT omitted), so the default speed is effective.
        #expect(AppSettings().ghosttyConfigLines().contains("mouse-scroll-multiplier = 3"))
    }

    @Test func mouseScrollMultiplierEmitsSetValue() {
        #expect(AppSettings(mouseScrollMultiplier: 5).ghosttyConfigLines().contains("mouse-scroll-multiplier = 5"))
        // fractional keeps the decimal via the shared format helper
        #expect(AppSettings(mouseScrollMultiplier: 1.5).ghosttyConfigLines().contains("mouse-scroll-multiplier = 1.5"))
    }

    @Test func mouseScrollMultiplierRoundTrips() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(mouseScrollMultiplier: 4)))
        #expect(decoded.mouseScrollMultiplier == 4)
    }

    @Test func statusColorFieldsRoundTripAndAreNotGhosttyKeys() throws {
        let original = AppSettings(activeStatusColorHex: "#112233", blockedStatusColorHex: "#445566",
                                   completedStatusColorHex: "#778899")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        // the glyph colors are applied at the AppKit level, never as ghostty config keys — so the only
        // lines are the always-on defaults (scroll + right-click).
        #expect(decoded.ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func notificationsEnabledRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(notificationsEnabled: false)))
        #expect(decoded.notificationsEnabled == false)
        // it's an app-level toggle, never a ghostty config key — only the always-on defaults (scroll + right-click) are emitted.
        #expect(AppSettings(notificationsEnabled: false).ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func restoreRunningCommandRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(restoreRunningCommand: true)))
        #expect(decoded.restoreRunningCommand == true)
        // absent in a legacy file decodes to nil (off).
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"Nord"}"#.utf8))
        #expect(legacy.restoreRunningCommand == nil)
        // an app-level behavior flag, never a ghostty config key — only the always-on defaults (scroll + right-click) are emitted.
        #expect(AppSettings(restoreRunningCommand: true).ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func blockedStatusSoundNameRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(blockedStatusSoundName: "Glass")))
        #expect(decoded.blockedStatusSoundName == "Glass")
        // absent in a legacy file decodes to nil (no sound).
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"Nord"}"#.utf8))
        #expect(legacy.blockedStatusSoundName == nil)
        // an app-level value, never a ghostty config key — only the always-on defaults (scroll + right-click) are emitted.
        #expect(AppSettings(blockedStatusSoundName: "Glass").ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func compactToolbarRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(compactToolbar: true)))
        #expect(decoded.compactToolbar == true)
        // window-chrome toggle applied at the AppKit level, never a ghostty config key — only the
        // always-on defaults (scroll + right-click) are emitted.
        #expect(AppSettings(compactToolbar: true).ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func notificationBadgeEnabledDefaultsNil() {
        #expect(AppSettings().notificationBadgeEnabled == nil)
    }

    @Test func notificationBadgeEnabledRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(notificationBadgeEnabled: false)))
        #expect(decoded.notificationBadgeEnabled == false)
        // app-level sidebar render toggle, never a ghostty config key — only the always-on defaults (scroll + right-click) are emitted.
        #expect(AppSettings(notificationBadgeEnabled: false).ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func configDirectoryRoundTripsAndIsNotAConfigLine() throws {
        let original = AppSettings(configDirectory: "/tmp/agterm-config")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded.configDirectory == "/tmp/agterm-config")
        // app-level path, never a ghostty config key — only the always-on defaults (scroll + right-click) appear.
        #expect(decoded.ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func configDirectoryDecodesNilWhenAbsent() throws {
        // a settings.json written before `configDirectory` existed still decodes.
        let json = #"{ "fontSize": 16 }"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.configDirectory == nil)
    }

    @Test func inactivePaneMuteStrengthRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(inactivePaneMuteStrength: 7)))
        #expect(decoded.inactivePaneMuteStrength == 7)
        // SwiftUI overlay opacity applied in the app target, never a ghostty config key.
        #expect(AppSettings(inactivePaneMuteStrength: 7).ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func inactivePaneMuteStrengthDecodesNilWhenAbsent() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "fontSize": 16 }"#.utf8))
        #expect(decoded.inactivePaneMuteStrength == nil)
    }

    @Test func muteOpacityScalesAndClamps() {
        #expect(AppSettings.muteOpacity(strength: 0) == 0)
        #expect(AppSettings.muteOpacity(strength: 5) == 0.4)
        #expect(AppSettings.muteOpacity(strength: 10) == 0.8)
        // out-of-range strengths clamp to the 0...10 ends rather than over/undershooting.
        #expect(AppSettings.muteOpacity(strength: -3) == 0)
        #expect(AppSettings.muteOpacity(strength: 99) == 0.8)
        #expect(AppSettings.defaultInactivePaneMuteStrength == 5)
    }

    @Test func sidebarBackgroundShiftRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(sidebarBackgroundShift: 8)))
        #expect(decoded.sidebarBackgroundShift == 8)
        // AppKit-level sidebar tint applied in the app target, never a ghostty config key.
        #expect(AppSettings(sidebarBackgroundShift: 8).ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func sidebarBackgroundShiftDecodesNilWhenAbsent() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "fontSize": 16 }"#.utf8))
        #expect(decoded.sidebarBackgroundShift == nil)
    }

    @Test func sidebarShiftAmountIsSignedAndClamps() {
        #expect(AppSettings.sidebarShiftAmount(strength: 5) == 0)
        #expect(abs(AppSettings.sidebarShiftAmount(strength: 0) - (-0.30)) < 1e-9) // full lighten
        #expect(abs(AppSettings.sidebarShiftAmount(strength: 10) - 0.30) < 1e-9)   // full darken
        #expect(AppSettings.sidebarShiftAmount(strength: 7) > 0)                   // above center darkens
        #expect(AppSettings.sidebarShiftAmount(strength: 3) < 0)                   // below center lightens
        // out-of-range strengths clamp to the 0...10 ends.
        #expect(AppSettings.sidebarShiftAmount(strength: -4) == AppSettings.sidebarShiftAmount(strength: 0))
        #expect(AppSettings.sidebarShiftAmount(strength: 99) == AppSettings.sidebarShiftAmount(strength: 10))
        #expect(AppSettings.defaultSidebarBackgroundShift == 5)
    }

    @Test func defaultThemeIsAgtermButNotBakedIntoAppSettings() {
        #expect(AppSettings.defaultTheme == "agterm")
        // the seed lives in SettingsStore.load, NOT the memberwise default — AppSettings() stays
        // theme-less so "nil = no theme line" holds (the ghostty built-in / "default ghostty" case).
        #expect(AppSettings().theme == nil)
        #expect(!AppSettings().ghosttyConfigLines().contains { $0.hasPrefix("theme = ") })
        #expect(AppSettings(theme: AppSettings.defaultTheme).ghosttyConfigLines().contains("theme = agterm"))
    }

    @Test func inheritGlobalGhosttyConfigDefaultsOffAndIsNotAGhosttyKey() throws {
        // default (nil) = off; an app-level flag, so it adds NO ghostty config line.
        #expect(AppSettings().inheritGlobalGhosttyConfig == nil)
        #expect(AppSettings(inheritGlobalGhosttyConfig: true).ghosttyConfigLines() == AppSettings().ghosttyConfigLines())
        // round-trips each state; a legacy settings.json without the key decodes to nil (off).
        for value: Bool? in [nil, true, false] {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(inheritGlobalGhosttyConfig: value)))
            #expect(decoded.inheritGlobalGhosttyConfig == value)
        }
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "fontSize": 16 }"#.utf8))
        #expect(legacy.inheritGlobalGhosttyConfig == nil)
    }

    @Test func attentionButtonEnabledDefaultsOffAndIsNotAGhosttyKey() throws {
        // default (nil) = off; an app-level chrome flag, so it adds NO ghostty config line.
        #expect(AppSettings().attentionButtonEnabled == nil)
        #expect(AppSettings(attentionButtonEnabled: true).ghosttyConfigLines() == AppSettings().ghosttyConfigLines())
        // round-trips each state; a legacy settings.json without the key decodes to nil (off).
        for value: Bool? in [nil, true, false] {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(attentionButtonEnabled: value)))
            #expect(decoded.attentionButtonEnabled == value)
        }
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "fontSize": 16 }"#.utf8))
        #expect(legacy.attentionButtonEnabled == nil)
    }

    @Test func rightClickPasteDefaultsOnAndIsAGhosttyKey() throws {
        // default (nil) = on → emits `right-click-action = paste`; off → `ignore`. UNLIKE the app-level
        // flags this IS a ghostty key (the toggle owns it, always emitted).
        #expect(AppSettings().rightClickPaste == nil)
        #expect(AppSettings().ghosttyConfigLines().contains("right-click-action = paste"))
        #expect(AppSettings(rightClickPaste: true).ghosttyConfigLines().contains("right-click-action = paste"))
        #expect(AppSettings(rightClickPaste: false).ghosttyConfigLines().contains("right-click-action = ignore"))
        // round-trips each state; a legacy settings.json without the key decodes to nil (on).
        for value: Bool? in [nil, true, false] {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(rightClickPaste: value)))
            #expect(decoded.rightClickPaste == value)
        }
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "fontSize": 16 }"#.utf8))
        #expect(legacy.rightClickPaste == nil)
    }

    @Test func newSessionDirectoryRoundTripsAndIsNotAConfigLine() throws {
        let original = AppSettings(newSessionDirectory: "custom", newSessionCustomDirectory: "/tmp/work")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        // absent in a legacy file decodes to nil (the home default).
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "fontSize": 16 }"#.utf8))
        #expect(legacy.newSessionDirectory == nil)
        #expect(legacy.newSessionCustomDirectory == nil)
        // an app-level behavior value, never a ghostty config key — only the always-on defaults are emitted.
        #expect(original.ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func resolveNewSessionCwdHomeIsDefault() {
        // nil mode (default) and an explicit "home" both resolve to home, ignoring the session cwd.
        #expect(AppSettings().resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/home")
        #expect(AppSettings(newSessionDirectory: "home").resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/home")
        // an unknown future mode falls back to home rather than crashing.
        #expect(AppSettings(newSessionDirectory: "future").resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/home")
    }

    @Test func resolveNewSessionCwdCurrentSessionInheritsOrFallsBack() {
        let settings = AppSettings(newSessionDirectory: "currentSession")
        #expect(settings.resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/proj")
        // no active session (nil cwd) or a blank cwd falls back to home.
        #expect(settings.resolveNewSessionCwd(currentSessionCwd: nil, home: "/home") == "/home")
        #expect(settings.resolveNewSessionCwd(currentSessionCwd: "", home: "/home") == "/home")
    }

    @Test func resolveNewSessionCwdCustomUsesPathElseHome() {
        #expect(AppSettings(newSessionDirectory: "custom", newSessionCustomDirectory: "/fixed")
            .resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/fixed")
        // custom mode with an unset or blank path falls back to home.
        #expect(AppSettings(newSessionDirectory: "custom")
            .resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/home")
        #expect(AppSettings(newSessionDirectory: "custom", newSessionCustomDirectory: "")
            .resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/home")
    }
}
