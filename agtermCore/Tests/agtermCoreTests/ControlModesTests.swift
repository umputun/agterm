import Foundation
import Testing
@testable import agtermCore

struct ControlModesTests {
    @Test func toggleModeDefaultsToToggle() {
        #expect(ControlToggleMode.parse(nil) == .toggle)
        #expect(ControlToggleMode.parse(nil, on: "show", off: "hide") == .toggle)
    }

    @Test func toggleModeParsesDefaultTokens() {
        #expect(ControlToggleMode.parse("on") == .on)
        #expect(ControlToggleMode.parse("off") == .off)
        #expect(ControlToggleMode.parse("toggle") == .toggle)
    }

    @Test func toggleModeParsesCustomTrueFalseTokens() {
        #expect(ControlToggleMode.parse("show", on: "show", off: "hide") == .on)
        #expect(ControlToggleMode.parse("hide", on: "show", off: "hide") == .off)
        #expect(ControlToggleMode.parse("toggle", on: "show", off: "hide") == .toggle)
    }

    @Test func toggleModeRejectsUnknownToken() {
        #expect(ControlToggleMode.parse("yes") == nil)
        #expect(ControlToggleMode.parse("on", on: "show", off: "hide") == nil)
    }

    @Test func toggleModeComputesDesiredValue() {
        #expect(ControlToggleMode.on.desiredValue(current: false))
        #expect(ControlToggleMode.on.desiredValue(current: true))
        #expect(!ControlToggleMode.off.desiredValue(current: false))
        #expect(!ControlToggleMode.off.desiredValue(current: true))
        #expect(ControlToggleMode.toggle.desiredValue(current: false))
        #expect(!ControlToggleMode.toggle.desiredValue(current: true))
    }

    @Test func paneFocusModeDefaultsToOther() {
        #expect(ControlPaneFocusMode.parse(nil) == .toggle)
    }

    @Test func paneFocusModeParsesAliases() {
        #expect(ControlPaneFocusMode.parse("left") == .primary)
        #expect(ControlPaneFocusMode.parse("primary") == .primary)
        #expect(ControlPaneFocusMode.parse("right") == .split)
        #expect(ControlPaneFocusMode.parse("split") == .split)
        #expect(ControlPaneFocusMode.parse("other") == .toggle)
        #expect(ControlPaneFocusMode.parse("toggle") == .toggle)
    }

    @Test func paneFocusModeRejectsUnknownPane() {
        #expect(ControlPaneFocusMode.parse("center") == nil)
    }

    @Test func paneFocusModeComputesTargetPane() {
        #expect(!ControlPaneFocusMode.primary.wantsSplit(currentSplitFocused: false))
        #expect(!ControlPaneFocusMode.primary.wantsSplit(currentSplitFocused: true))
        #expect(ControlPaneFocusMode.split.wantsSplit(currentSplitFocused: false))
        #expect(ControlPaneFocusMode.split.wantsSplit(currentSplitFocused: true))
        #expect(ControlPaneFocusMode.toggle.wantsSplit(currentSplitFocused: false))
        #expect(!ControlPaneFocusMode.toggle.wantsSplit(currentSplitFocused: true))
    }
}
