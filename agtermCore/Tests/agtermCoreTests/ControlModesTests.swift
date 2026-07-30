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
        #expect(ControlWorkspaceFocusMode(rawValue: "on") == .on)
        #expect(ControlWorkspaceFocusMode(rawValue: "off") == .off)
        #expect(ControlWorkspaceFocusMode(rawValue: "toggle") == .toggle)
        #expect(ControlWorkspaceFocusMode(rawValue: "add") == .add)
        #expect(ControlWorkspaceFocusMode(rawValue: "remove") == nil)
        #expect(ControlWorkspaceFocusMode(rawValue: "") == nil)
    }

    @Test func workspaceFocusModeListsEveryCase() {
        // there is deliberately no membership-toggle mode: the row menu computes its own direction.
        #expect(ControlWorkspaceFocusMode.allCases == [.on, .off, .toggle, .add])
    }

    @Test func workspaceFocusModeDerivesValidNamesFromAllCases() {
        #expect(ControlWorkspaceFocusMode.validNamesList == ControlWorkspaceFocusMode.allCases.map(\.rawValue).joined(separator: "|"))
        #expect(ControlWorkspaceFocusMode.validNamesPhrase == ControlWorkspaceFocusMode.allCases.map(\.rawValue).joined(separator: ", "))
        #expect(ControlWorkspaceFocusMode.validNamesList == "on|off|toggle|add")
        #expect(ControlWorkspaceFocusMode.validNamesPhrase == "on, off, toggle, add")
    }

    @Test func workspaceFocusModeHelpNamesEveryModeAndItsFilterEffect() {
        // each clause has to name what the mode does to the FILTER FLAG: `add` is the only one that
        // leaves it alone, and stating that in isolation reads as if the others did too.
        let phrase = ControlWorkspaceFocusMode.helpPhrase
        for mode in ControlWorkspaceFocusMode.allCases {
            #expect(phrase.contains(mode.helpSummary), "the help phrase should carry \(mode.rawValue)'s clause")
            #expect(mode.helpSummary.hasPrefix(mode.rawValue), "each clause should lead with its wire token")
            #expect(mode.helpSummary.contains("filter"), "each clause should state its effect on the filter")
        }
        #expect(ControlWorkspaceFocusMode.on.helpSummary.contains("apply"))
        #expect(ControlWorkspaceFocusMode.add.helpSummary.contains("leaving the filter flag alone"))
    }

    @Test func sidebarViewModeParsesModes() {
        #expect(ControlSidebarViewMode.parse(nil) == .toggle)
        #expect(ControlSidebarViewMode.parse("tree") == .tree)
        #expect(ControlSidebarViewMode.parse("flagged") == .flagged)
        #expect(ControlSidebarViewMode.parse("toggle") == .toggle)
        #expect(ControlSidebarViewMode.parse("wide") == nil)
    }
}
