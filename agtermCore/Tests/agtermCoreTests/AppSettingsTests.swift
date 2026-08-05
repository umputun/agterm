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
        #expect(decoded.closeGraceUndoEnabled == nil)
    }

    @Test func closeGraceUndoSettingRoundTripsAndDefaultsToNil() throws {
        let disabled = AppSettings(closeGraceUndoEnabled: false)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(disabled))
        #expect(decoded.closeGraceUndoEnabled == false)
        #expect(AppSettings().closeGraceUndoEnabled == nil)
    }

    @Test func emptySettingsEmitOnlyAlwaysOnDefaults() {
        #expect(AppSettings().ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func configLinesCoverSetFieldsRawNoQuoting() {
        let settings = AppSettings(fontFamily: "SF Mono", fontSize: 14, theme: "3024 Night")
        let lines = settings.ghosttyConfigLines()
        // names with spaces are NOT quoted — ghostty takes the line remainder.
        #expect(lines.contains("font-family = SF Mono"))
        #expect(lines.contains("theme = 3024 Night"))
        #expect(lines.contains("font-size = 14"))
    }

    @Test func configLinesOmitUnsetFields() {
        let lines = AppSettings(theme: "Alabaster").ghosttyConfigLines()
        #expect(lines == ["theme = Alabaster", "mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func followingEmitsRawDual() {
        // libghostty resolves the active side of the dual conditional itself, so agterm never picks one.
        let settings = AppSettings(theme: "Builtin Light", darkTheme: "Nord", followSystemAppearance: true)
        #expect(settings.ghosttyConfigLines().contains("theme = light:Builtin Light,dark:Nord"))
    }

    @Test func notFollowingEmitsSingleTheme() {
        #expect(AppSettings(theme: "Alabaster").ghosttyConfigLines().contains("theme = Alabaster"))
        let darkKept = AppSettings(theme: "Alabaster", darkTheme: "Nord", followSystemAppearance: false)
        #expect(darkKept.ghosttyConfigLines().contains("theme = Alabaster"))
        #expect(!darkKept.ghosttyConfigLines().contains { $0.hasPrefix("theme = light:") })
    }

    @Test func activeThemeTracksAppearanceWhenFollowing() {
        // the palette badge/selection resolver.
        let synced = AppSettings(theme: "Builtin Light", darkTheme: "Nord", followSystemAppearance: true)
        #expect(synced.activeTheme(isDark: true) == "Nord")
        #expect(synced.activeTheme(isDark: false) == "Builtin Light")
        let single = AppSettings(theme: "agterm")
        #expect(single.activeTheme(isDark: true) == "agterm")
        #expect(single.activeTheme(isDark: false) == "agterm")
        #expect(AppSettings().activeTheme(isDark: true) == nil)
    }

    @Test func followingWithoutDarkSlotEmitsSingle() {
        // an inconsistent hand-edit: fall back to the single theme rather than an ill-formed
        // `light:X,dark:`.
        let settings = AppSettings(theme: "Alabaster", darkTheme: nil, followSystemAppearance: true)
        #expect(settings.ghosttyConfigLines().contains("theme = Alabaster"))
        #expect(!settings.ghosttyConfigLines().contains { $0.hasPrefix("theme = light:") })
    }

    @Test func newThemeFieldsRoundTrip() throws {
        let original = AppSettings(theme: "Builtin Light", darkTheme: "agterm", followSystemAppearance: true)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.darkTheme == "agterm")
        #expect(decoded.followSystemAppearance == true)
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
        // blur needs opacity < 1 to be visible, so a blur with no translucency emits no pins either.
        for settings in [AppSettings(backgroundOpacity: 1), AppSettings(), AppSettings(backgroundBlur: 40)] {
            let lines = settings.ghosttyConfigLines()
            #expect(!lines.contains("background-opacity = 0"))
            #expect(!lines.contains("background-blur = 0"))
        }
    }

    @Test func mouseScrollMultiplierAlwaysEmittedAtDefaultThree() {
        #expect(AppSettings().ghosttyConfigLines().contains("mouse-scroll-multiplier = 3"))
    }

    @Test func mouseScrollMultiplierEmitsSetValue() {
        #expect(AppSettings(mouseScrollMultiplier: 5).ghosttyConfigLines().contains("mouse-scroll-multiplier = 5"))
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
        #expect(decoded.ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func statusShapeFieldsRoundTripAndAreNotGhosttyKeys() throws {
        let original = AppSettings(activeStatusShape: "square", blockedStatusShape: "triangle",
                                   completedStatusShape: "star")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.effectiveStatusShape(for: .active) == .square)
        #expect(decoded.effectiveStatusShape(for: .blocked) == .triangle)
        #expect(decoded.effectiveStatusShape(for: .completed) == .star)
        #expect(decoded.ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func everyStatusShapeRoundTripsThroughTheRawStorage() throws {
        for shape in StatusShape.allCases {
            let stored = AppSettings(blockedStatusShape: shape.rawValue)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(stored))
            #expect(decoded.blockedStatusShape == shape.rawValue)
            #expect(decoded.effectiveStatusShape(for: .blocked) == shape)
        }
    }

    @Test func statusShapesDefaultNilAndOmitFromJSON() throws {
        // unset means the default plain circle.
        let settings = AppSettings()
        #expect(settings.activeStatusShape == nil)
        #expect(settings.effectiveStatusShape(for: .active) == nil)
        #expect(settings.effectiveStatusShape(for: .blocked) == nil)
        #expect(settings.effectiveStatusShape(for: .completed) == nil)
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!json.contains("StatusShape"))
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "fontSize": 16 }"#.utf8))
        #expect(legacy.activeStatusShape == nil)
        #expect(legacy.blockedStatusShape == nil)
        #expect(legacy.completedStatusShape == nil)
        #expect(legacy.effectiveStatusShape(for: .blocked) == nil)
    }

    @Test func unknownStatusShapeResolvesToNilAndPreservesOtherSettings() throws {
        // forward-compat rule: an unknown shape keeps its raw string, resolves to nil (the built-in
        // glyph), and must not fail the whole decode.
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{ "blockedStatusShape": "trapezoid", "fontSize": 16 }"#.utf8))
        #expect(decoded.fontSize == 16)
        #expect(decoded.blockedStatusShape == "trapezoid")
        #expect(decoded.effectiveStatusShape(for: .blocked) == nil)
        #expect(AppSettings(activeStatusShape: "").effectiveStatusShape(for: .active) == nil)
    }

    @Test func effectiveStatusShapeIsNilForIdle() {
        // idle renders no glyph at all.
        let settings = AppSettings(activeStatusShape: "circle", blockedStatusShape: "square",
                                   completedStatusShape: "star")
        #expect(settings.effectiveStatusShape(for: .idle) == nil)
    }

    @Test func notificationsEnabledRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(notificationsEnabled: false)))
        #expect(decoded.notificationsEnabled == false)
        #expect(AppSettings(notificationsEnabled: false).ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func restoreRunningCommandRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(restoreRunningCommand: true)))
        #expect(decoded.restoreRunningCommand == true)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"Nord"}"#.utf8))
        #expect(legacy.restoreRunningCommand == nil)
        #expect(AppSettings(restoreRunningCommand: true).ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func autoHideSidebarInactiveWindowsRoundTripsAndIsNotAConfigLine() throws {
        #expect(AppSettings().autoHideSidebarInactiveWindows == nil)
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(AppSettings(autoHideSidebarInactiveWindows: true)))
        #expect(decoded.autoHideSidebarInactiveWindows == true)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"Nord"}"#.utf8))
        #expect(legacy.autoHideSidebarInactiveWindows == nil)
        #expect(AppSettings(autoHideSidebarInactiveWindows: true).ghosttyConfigLines()
            == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func confirmCloseSessionRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(confirmCloseSession: true)))
        #expect(decoded.confirmCloseSession == true)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"Nord"}"#.utf8))
        #expect(legacy.confirmCloseSession == nil)
        #expect(AppSettings(confirmCloseSession: true).ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func workspaceRowClickExpandsDefaultsOnAndIsNotAConfigLine() throws {
        #expect(AppSettings().workspaceRowClickExpands == nil)
        let decoded = try JSONDecoder().decode(AppSettings.self,
                                               from: JSONEncoder().encode(AppSettings(workspaceRowClickExpands: false)))
        #expect(decoded.workspaceRowClickExpands == false)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"Nord"}"#.utf8))
        #expect(legacy.workspaceRowClickExpands == nil)
        #expect(AppSettings(workspaceRowClickExpands: false).ghosttyConfigLines()
            == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func notificationSoundNameRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(notificationSoundName: "Glass")))
        #expect(decoded.notificationSoundName == "Glass")
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"Nord"}"#.utf8))
        #expect(legacy.notificationSoundName == nil)
        #expect(AppSettings(notificationSoundName: "Glass").ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func blockedStatusSoundNameRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(blockedStatusSoundName: "Glass")))
        #expect(decoded.blockedStatusSoundName == "Glass")
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"Nord"}"#.utf8))
        #expect(legacy.blockedStatusSoundName == nil)
        #expect(AppSettings(blockedStatusSoundName: "Glass").ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func toolbarModeRoundTripsAndIsNotAConfigLine() throws {
        for mode in ToolbarMode.allCases {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(toolbarMode: mode.rawValue)))
            #expect(decoded.toolbarMode == mode.rawValue)
            #expect(decoded.effectiveToolbarMode == mode)
        }
        #expect(AppSettings(toolbarMode: ToolbarMode.hidden.rawValue).ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func toolbarModeOmittedWhenNil() throws {
        #expect(AppSettings().toolbarMode == nil)
        let json = String(decoding: try JSONEncoder().encode(AppSettings()), as: UTF8.self)
        #expect(!json.contains("toolbarMode"))
        #expect(!json.contains("compactToolbar"))
        // the write path that lets the legacy key evaporate on the next save.
        let withMode = String(decoding: try JSONEncoder().encode(AppSettings(toolbarMode: ToolbarMode.hidden.rawValue)), as: UTF8.self)
        #expect(withMode.contains("toolbarMode"))
        #expect(withMode.contains("hidden"))
        #expect(!withMode.contains("compactToolbar"))
    }

    @Test func effectiveToolbarModeDefaultsCompact() {
        #expect(AppSettings().effectiveToolbarMode == .compact)
    }

    @Test func effectiveToolbarModeResolvesExplicitModes() {
        #expect(AppSettings(toolbarMode: ToolbarMode.compact.rawValue).effectiveToolbarMode == .compact)
        #expect(AppSettings(toolbarMode: ToolbarMode.normal.rawValue).effectiveToolbarMode == .normal)
        #expect(AppSettings(toolbarMode: ToolbarMode.hidden.rawValue).effectiveToolbarMode == .hidden)
    }

    @Test func unknownToolbarModePreservesOtherSettings() throws {
        // forward-compat rule: an unknown mode must not fail the decode and discard every other field.
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "toolbarMode": "floating", "fontSize": 16 }"#.utf8))
        #expect(decoded.fontSize == 16)
        #expect(decoded.toolbarMode == "floating")
        #expect(decoded.effectiveToolbarMode == .compact)
    }

    @Test func toolbarModeWinsOverLegacyCompactToolbar() {
        #expect(AppSettings(toolbarMode: ToolbarMode.hidden.rawValue, compactToolbar: false).effectiveToolbarMode == .hidden)
        #expect(AppSettings(toolbarMode: ToolbarMode.normal.rawValue, compactToolbar: true).effectiveToolbarMode == .normal)
    }

    @Test func legacyCompactToolbarMigratesToMode() throws {
        // the legacy shim maps false → normal, true/nil → compact.
        let normal = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "compactToolbar": false }"#.utf8))
        #expect(normal.toolbarMode == nil)
        #expect(normal.effectiveToolbarMode == .normal)
        let compact = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "compactToolbar": true }"#.utf8))
        #expect(compact.effectiveToolbarMode == .compact)
        let legacyAbsent = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "fontSize": 16 }"#.utf8))
        #expect(legacyAbsent.effectiveToolbarMode == .compact)
    }

    @Test func notificationBadgeEnabledDefaultsNil() {
        #expect(AppSettings().notificationBadgeEnabled == nil)
    }

    @Test func notificationBadgeEnabledRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(notificationBadgeEnabled: false)))
        #expect(decoded.notificationBadgeEnabled == false)
        #expect(AppSettings(notificationBadgeEnabled: false).ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func configDirectoryRoundTripsAndIsNotAConfigLine() throws {
        let original = AppSettings(configDirectory: "/tmp/agterm-config")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded.configDirectory == "/tmp/agterm-config")
        #expect(decoded.ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func configDirectoryDecodesNilWhenAbsent() throws {
        let json = #"{ "fontSize": 16 }"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.configDirectory == nil)
    }

    @Test func inactivePaneMuteStrengthRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(inactivePaneMuteStrength: 7)))
        #expect(decoded.inactivePaneMuteStrength == 7)
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
        #expect(AppSettings.muteOpacity(strength: -3) == 0)
        #expect(AppSettings.muteOpacity(strength: 99) == 0.8)
        #expect(AppSettings.defaultInactivePaneMuteStrength == 5)
    }

    @Test func sidebarBackgroundShiftRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(sidebarBackgroundShift: 8)))
        #expect(decoded.sidebarBackgroundShift == 8)
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
        #expect(AppSettings.sidebarShiftAmount(strength: -4) == AppSettings.sidebarShiftAmount(strength: 0))
        #expect(AppSettings.sidebarShiftAmount(strength: 99) == AppSettings.sidebarShiftAmount(strength: 10))
        #expect(AppSettings.defaultSidebarBackgroundShift == 5)
    }

    @Test func fontSizesRoundTripAndAreNotConfigLines() throws {
        let original = AppSettings(sidebarFontSize: 16, interfaceFontSize: 18)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded.sidebarFontSize == 16)
        #expect(decoded.interfaceFontSize == 18)
        #expect(original.ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func fontSizesDefaultNilAndOmitFromJSON() throws {
        #expect(AppSettings().sidebarFontSize == nil)
        #expect(AppSettings().interfaceFontSize == nil)
        #expect(AppSettings().effectiveSidebarFontSize == AppSettings.defaultSidebarFontSize)
        #expect(AppSettings().effectiveInterfaceFontSize == AppSettings.defaultInterfaceFontSize)
        let json = String(decoding: try JSONEncoder().encode(AppSettings()), as: UTF8.self)
        #expect(!json.contains("sidebarFontSize"))
        #expect(!json.contains("interfaceFontSize"))
    }

    @Test func sidebarAndInterfaceFontSizesAreIndependent() throws {
        let sidebarOnly = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "sidebarFontSize": 17 }"#.utf8))
        #expect(sidebarOnly.effectiveSidebarFontSize == 17)
        #expect(sidebarOnly.effectiveInterfaceFontSize == AppSettings.defaultInterfaceFontSize)
        let interfaceOnly = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "interfaceFontSize": 17 }"#.utf8))
        #expect(interfaceOnly.effectiveInterfaceFontSize == 17)
        #expect(interfaceOnly.effectiveSidebarFontSize == AppSettings.defaultSidebarFontSize)
    }

    @Test func fontSizesClampToTheirRanges() {
        #expect(AppSettings.defaultSidebarFontSize == 13)
        #expect(AppSettings.defaultInterfaceFontSize == 13)
        #expect(AppSettings.clampSidebarFontSize(13) == 13)
        #expect(AppSettings.clampSidebarFontSize(2) == AppSettings.sidebarFontSizeRange.lowerBound)
        #expect(AppSettings.clampSidebarFontSize(99) == AppSettings.sidebarFontSizeRange.upperBound)
        #expect(AppSettings.clampInterfaceFontSize(13) == 13)
        #expect(AppSettings.clampInterfaceFontSize(2) == AppSettings.interfaceFontSizeRange.lowerBound)
        #expect(AppSettings.clampInterfaceFontSize(99) == AppSettings.interfaceFontSizeRange.upperBound)
        var outOfRange = AppSettings()
        outOfRange.sidebarFontSize = 99
        outOfRange.interfaceFontSize = 2
        #expect(outOfRange.effectiveSidebarFontSize == AppSettings.sidebarFontSizeRange.upperBound)
        #expect(outOfRange.effectiveInterfaceFontSize == AppSettings.interfaceFontSizeRange.lowerBound)
    }

    @Test func sidebarRowHeightScalesWithFontSize() {
        #expect(AppSettings.sidebarRowHeight(fontSize: 13) == 28) // the historical default row
        #expect(AppSettings.sidebarRowHeight(fontSize: 18) == 33)
        #expect(AppSettings.sidebarRowHeight(fontSize: 14.6) == 30) // fractional in-range rounds (14.6 -> 15, +15)
        // out-of-range sizes clamp before the padding is added.
        #expect(AppSettings.sidebarRowHeight(fontSize: 2) == AppSettings.sidebarFontSizeRange.lowerBound.rounded() + 15)
        #expect(AppSettings.sidebarRowHeight(fontSize: 99) == AppSettings.sidebarFontSizeRange.upperBound.rounded() + 15)
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
        #expect(AppSettings().inheritGlobalGhosttyConfig == nil)
        #expect(AppSettings(inheritGlobalGhosttyConfig: true).ghosttyConfigLines() == AppSettings().ghosttyConfigLines())
        for value: Bool? in [nil, true, false] {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(inheritGlobalGhosttyConfig: value)))
            #expect(decoded.inheritGlobalGhosttyConfig == value)
        }
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "fontSize": 16 }"#.utf8))
        #expect(legacy.inheritGlobalGhosttyConfig == nil)
    }

    @Test func attentionButtonEnabledDefaultsOffAndIsNotAGhosttyKey() throws {
        #expect(AppSettings().attentionButtonEnabled == nil)
        #expect(AppSettings(attentionButtonEnabled: true).ghosttyConfigLines() == AppSettings().ghosttyConfigLines())
        for value: Bool? in [nil, true, false] {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(attentionButtonEnabled: value)))
            #expect(decoded.attentionButtonEnabled == value)
        }
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "fontSize": 16 }"#.utf8))
        #expect(legacy.attentionButtonEnabled == nil)
    }

    @Test func dockBounceDefaultsToOffResolvesTolerantlyAndIsNotAGhosttyKey() throws {
        #expect(AppSettings().effectiveDockBounce == .off)
        #expect(AppSettings(dockBounce: "once").ghosttyConfigLines() == AppSettings().ghosttyConfigLines())
        for mode in DockBounce.allCases {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(dockBounce: mode.rawValue)))
            #expect(decoded.dockBounce == mode.rawValue)
            #expect(decoded.effectiveDockBounce == mode)
        }
        // an unknown/future raw value degrades to off instead of failing the decode.
        #expect(AppSettings(dockBounce: "supernova").effectiveDockBounce == .off)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "fontSize": 16 }"#.utf8))
        #expect(legacy.dockBounce == nil)
        #expect(legacy.effectiveDockBounce == .off)
    }

    @Test func rightClickPasteDefaultsOnAndIsAGhosttyKey() throws {
        // UNLIKE the app-level flags this IS a ghostty key — the toggle owns it, always emitted.
        #expect(AppSettings().rightClickPaste == nil)
        #expect(AppSettings().ghosttyConfigLines().contains("right-click-action = paste"))
        #expect(AppSettings(rightClickPaste: true).ghosttyConfigLines().contains("right-click-action = paste"))
        #expect(AppSettings(rightClickPaste: false).ghosttyConfigLines().contains("right-click-action = ignore"))
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
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{ "fontSize": 16 }"#.utf8))
        #expect(legacy.newSessionDirectory == nil)
        #expect(legacy.newSessionCustomDirectory == nil)
        #expect(original.ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func resolveNewSessionCwdHomeIsDefault() {
        #expect(AppSettings().resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/home")
        #expect(AppSettings(newSessionDirectory: "home").resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/home")
        // an unknown future mode falls back to home.
        #expect(AppSettings(newSessionDirectory: "future").resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/home")
    }

    @Test func resolveNewSessionCwdCurrentSessionInheritsOrFallsBack() {
        let settings = AppSettings(newSessionDirectory: "currentSession")
        #expect(settings.resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/proj")
        #expect(settings.resolveNewSessionCwd(currentSessionCwd: nil, home: "/home") == "/home")
        #expect(settings.resolveNewSessionCwd(currentSessionCwd: "", home: "/home") == "/home")
    }

    @Test func resolveNewSessionCwdCustomUsesPathElseHome() {
        #expect(AppSettings(newSessionDirectory: "custom", newSessionCustomDirectory: "/fixed")
            .resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/fixed")
        #expect(AppSettings(newSessionDirectory: "custom")
            .resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/home")
        #expect(AppSettings(newSessionDirectory: "custom", newSessionCustomDirectory: "")
            .resolveNewSessionCwd(currentSessionCwd: "/proj", home: "/home") == "/home")
    }

    @Test func autoFollowAttentionUnknownDecodesToOff() {
        #expect(AppSettings.AutoFollowAttention(rawValue: "s5") == .s5)
        #expect(AppSettings.AutoFollowAttention(rawValue: "future") == nil)
        #expect((AppSettings.AutoFollowAttention(rawValue: "future") ?? .off) == .off)
    }

    @Test func autoFollowAttentionTolerantInit() {
        #expect(AppSettings.AutoFollowAttention(tolerant: "s30") == .s30)
        #expect(AppSettings.AutoFollowAttention(tolerant: nil) == .off)
        #expect(AppSettings.AutoFollowAttention(tolerant: "") == .off)
        #expect(AppSettings.AutoFollowAttention(tolerant: "future") == .off)
    }

    @Test func autoFollowAttentionTimeoutMapping() {
        #expect(AppSettings.AutoFollowAttention.off.timeout == nil)
        #expect(AppSettings.AutoFollowAttention.s5.timeout == 5)
        #expect(AppSettings.AutoFollowAttention.s10.timeout == 10)
        #expect(AppSettings.AutoFollowAttention.s30.timeout == 30)
        #expect(AppSettings.AutoFollowAttention.s60.timeout == 60)
        #expect(AppSettings.AutoFollowAttention.m5.timeout == 300)
        #expect(AppSettings.AutoFollowAttention.allCases.filter { $0.timeout == nil } == [.off])
    }

    @Test func autoFollowFieldsDefaultNilAndOmitFromJSON() throws {
        #expect(AppSettings().autoFollowAttention == nil)
        #expect(AppSettings().autoFollowStayOnActive == nil)
        let json = String(decoding: try JSONEncoder().encode(AppSettings()), as: UTF8.self)
        #expect(!json.contains("autoFollowAttention"))
        #expect(!json.contains("autoFollowStayOnActive"))
    }

    @Test func autoFollowFieldsRoundTripAndAreNotConfigLines() throws {
        let original = AppSettings(autoFollowAttention: "s30", autoFollowStayOnActive: true)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.autoFollowAttention == "s30")
        #expect(decoded.autoFollowStayOnActive == true)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"Nord"}"#.utf8))
        #expect(legacy.autoFollowAttention == nil)
        #expect(legacy.autoFollowStayOnActive == nil)
        #expect(original.ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func hiddenInterfaceElementsDefaultsNilAndShowsEverything() {
        let settings = AppSettings()
        #expect(settings.hiddenInterfaceElements == nil)
        #expect(settings.resolvedHiddenInterfaceElements.isEmpty)
        for element in InterfaceElement.allCases {
            #expect(!settings.isInterfaceElementHidden(element))
        }
    }

    @Test func hiddenInterfaceElementsRoundTripsAndIsNotAConfigLine() throws {
        let original = AppSettings(hiddenInterfaceElements: ["scratch", "flaggedView"])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.isInterfaceElementHidden(.scratch))
        #expect(decoded.isInterfaceElementHidden(.flaggedView))
        #expect(!decoded.isInterfaceElementHidden(.split))
        #expect(original.ghosttyConfigLines() == ["mouse-scroll-multiplier = 3", "right-click-action = paste"])
    }

    @Test func workspaceAddSessionIsADistinctSidebarInterfaceElement() {
        // the workspace-row hover "+", a separate toggle from the footer newSession button.
        #expect(InterfaceElement.workspaceAddSession.section == .sidebar)
        #expect(InterfaceElement.workspaceAddSession.displayName == "Workspace add-session")
        let hidden = AppSettings(hiddenInterfaceElements: ["workspaceAddSession"])
        #expect(hidden.isInterfaceElementHidden(.workspaceAddSession))
        #expect(!hidden.isInterfaceElementHidden(.newSession))
    }

    @Test func focusFilterIsASidebarInterfaceElement() {
        // the bottom-bar workspace-filter toggle, hidden independently of the flagged-view toggle beside it.
        #expect(InterfaceElement.focusFilter.section == .sidebar)
        #expect(InterfaceElement.focusFilter.displayName == "Workspace filter")
        let hidden = AppSettings(hiddenInterfaceElements: ["focusFilter"])
        #expect(hidden.isInterfaceElementHidden(.focusFilter))
        #expect(!hidden.isInterfaceElementHidden(.flaggedView))
    }

    @Test func unknownInterfaceElementDecodesTolerantly() throws {
        // forward-compat rule: an unknown name is dropped from the resolved set and must not fail the
        // whole decode.
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{ "hiddenInterfaceElements": ["scratch", "teleporter"], "fontSize": 16 }"#.utf8))
        #expect(decoded.fontSize == 16)
        #expect(decoded.resolvedHiddenInterfaceElements == [.scratch])
        #expect(decoded.isInterfaceElementHidden(.scratch))
    }

    @Test func interfaceElementSectionsPartitionAllCases() {
        // the Settings tab relies on this partition to group the toggles.
        let titleBar = InterfaceElement.allCases.filter { $0.section == .titleBar }
        let sidebar = InterfaceElement.allCases.filter { $0.section == .sidebar }
        #expect(titleBar.count + sidebar.count == InterfaceElement.allCases.count)
        #expect(sidebar == [.newWorkspace, .newSession, .flaggedView, .focusFilter, .workspaceAddSession])
        #expect(!titleBar.isEmpty)
    }

    @Test(arguments: [
        // (countA, countB, countC, afterA, afterB)
        (1, 2, 2, false, true),  // default: lone recent flows in, one divider between the two full groups
        (1, 1, 2, false, false), // hide a B button: B is a single, no divider anywhere
        (2, 2, 2, true, true),   // all full: both dividers
        (2, 0, 2, false, true),  // empty B: a full A and a full C meet directly
        (2, 1, 2, false, false), // lone B between two full groups: no bridge, no dividers
        (2, 2, 1, true, false),  // lone C: divider only between the two full A/B groups
        (0, 2, 2, false, true),  // empty A: divider only between B and C
        (0, 0, 2, false, false), // only C present: no dividers at the leading edge
        (2, 2, 0, true, false),  // empty C: divider only between A and B
        (0, 0, 0, false, false), // nothing visible
    ])
    func titlebarGroupDividersOnlyBetweenFullGroups(countA: Int, countB: Int, countC: Int,
                                                    afterA: Bool, afterB: Bool) {
        let dividers = InterfaceElement.titlebarGroupDividers(countA: countA, countB: countB, countC: countC)
        #expect(dividers.afterA == afterA)
        #expect(dividers.afterB == afterB)
    }
}
