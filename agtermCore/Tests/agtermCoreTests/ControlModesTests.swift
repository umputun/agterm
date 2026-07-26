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

    @Test func workspaceFocusModeParsesWireTokens() {
        #expect(WorkspaceFocusMode(rawValue: "on") == .on)
        #expect(WorkspaceFocusMode(rawValue: "off") == .off)
        #expect(WorkspaceFocusMode(rawValue: "toggle") == .toggle)
        #expect(WorkspaceFocusMode(rawValue: "add") == .add)
        #expect(WorkspaceFocusMode(rawValue: "remove") == nil)
        #expect(WorkspaceFocusMode(rawValue: "") == nil)
    }

    @Test func workspaceFocusModeListsEveryCase() {
        // there is deliberately no membership-toggle mode: the row menu computes its own direction.
        #expect(WorkspaceFocusMode.allCases == [.on, .off, .toggle, .add])
    }

    @Test func workspaceFocusModeDerivesValidNamesFromAllCases() {
        // both spellings derive from allCases, so a new mode cannot leave an error/help string stale.
        #expect(WorkspaceFocusMode.validNamesList == WorkspaceFocusMode.allCases.map(\.rawValue).joined(separator: "|"))
        #expect(WorkspaceFocusMode.validNamesPhrase == WorkspaceFocusMode.allCases.map(\.rawValue).joined(separator: ", "))
        #expect(WorkspaceFocusMode.validNamesList == "on|off|toggle|add")
        #expect(WorkspaceFocusMode.validNamesPhrase == "on, off, toggle, add")
    }

    @Test func sidebarViewModeParsesModes() {
        #expect(ControlSidebarViewMode.parse(nil) == .toggle)
        #expect(ControlSidebarViewMode.parse("tree") == .tree)
        #expect(ControlSidebarViewMode.parse("flagged") == .flagged)
        #expect(ControlSidebarViewMode.parse("toggle") == .toggle)
        #expect(ControlSidebarViewMode.parse("wide") == nil)
    }
}
