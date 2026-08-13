import Foundation
import Testing
@testable import agtermCore

struct BuiltinActionTests {
    @Test func everyRawNameRoundTrips() {
        for action in BuiltinAction.allCases {
            #expect(BuiltinAction(rawValue: action.rawValue) == action)
        }
    }

    @Test func rawNamesAreTheKittyStyleNames() {
        #expect(BuiltinAction.newWindow.rawValue == "new_window")
        #expect(BuiltinAction.toggleSplit.rawValue == "toggle_split")
        #expect(BuiltinAction.toggleHorizontalSplit.rawValue == "toggle_horizontal_split")
        #expect(BuiltinAction.toggleTerminalZoom.rawValue == "toggle_terminal_zoom")
        #expect(BuiltinAction.toggleSearch.rawValue == "toggle_search")
        #expect(BuiltinAction.commandPalette.rawValue == "command_palette")
        #expect(BuiltinAction.customCommandPalette.rawValue == "custom_command_palette")
        #expect(BuiltinAction.nextAttentionSession.rawValue == "next_attention_session")
        #expect(BuiltinAction.toggleSidebar.rawValue == "toggle_sidebar")
        #expect(BuiltinAction.selectTheme.rawValue == "select_theme")
        #expect(BuiltinAction.toggleFlaggedView.rawValue == "toggle_flagged_view")
        #expect(BuiltinAction.toggleWorkspaceFilter.rawValue == "toggle_workspace_filter")
        #expect(BuiltinAction.toggleFlag.rawValue == "toggle_flag")
        #expect(BuiltinAction.focusWorkspace.rawValue == "focus_workspace")
        #expect(BuiltinAction.showAttention.rawValue == "show_attention")
        #expect(BuiltinAction.reopenRecent.rawValue == "reopen_recent")
        #expect(BuiltinAction.undoClose.rawValue == "undo_close")
        #expect(BuiltinAction.toggleFullscreen.rawValue == "toggle_fullscreen")
        #expect(BuiltinAction.dashboard.rawValue == "dashboard")
        #expect(BuiltinAction.duplicateSession.rawValue == "duplicate_session")
        #expect(BuiltinAction.allCases.count == 43)
    }

    @Test func rejectsUnknownName() {
        #expect(BuiltinAction(rawValue: "not_an_action") == nil)
        #expect(BuiltinAction(rawValue: "") == nil)
        #expect(BuiltinAction(rawValue: "New_Window") == nil)
    }

    @Test func arrowBoundActionsShipRealDefaultsThatRoundTrip() {
        // the six arrow-bound actions are ordinary defaultChord-driven actions: the menu holds no
        // hardcoded fallback, so their shipped chords must be spellable in keymap.conf.
        let expected: [BuiltinAction: (syntax: String, glyph: String)] = [
            .focusLeftPane: ("cmd+opt+left", "⌥⌘←"), .focusRightPane: ("cmd+opt+right", "⌥⌘→"),
            .previousSession: ("cmd+opt+up", "⌥⌘↑"), .nextSession: ("cmd+opt+down", "⌥⌘↓"),
            .previousAttentionSession: ("ctrl+opt+up", "⌃⌥↑"), .nextAttentionSession: ("ctrl+opt+down", "⌃⌥↓"),
        ]
        for (action, want) in expected {
            let chord = action.defaultChord
            #expect(chord?.displayString == want.syntax, "default chord mismatch for \(action.rawValue)")
            #expect(chord.map { parseKeybind(want.syntax) == [$0] } == true)
            #expect(chord?.glyphString == want.glyph)
        }
    }

    @Test func everyShippedDefaultRoundTripsExceptTheDocumentedPlusKey() {
        // a default that can't round-trip renders as "(not expressible)" in the starter file. ⌘+ is the
        // ONE documented exception (`+` is the chord joiner); anything else here is a bug in that default.
        let notExpressible = BuiltinAction.allCases.filter { action in
            guard let chord = action.defaultChord else { return false }
            return parseKeybind(chord.displayString) != [chord]
        }
        #expect(notExpressible == [.increaseFontSize])
    }

    @Test func shippedDefaultsAreAllDistinct() {
        // resolveBuiltinOverrides' termination argument depends on this: every collision must involve at
        // least one user override, so no two shipped defaults may claim the same chord.
        let defaults = BuiltinAction.allCases.compactMap(\.defaultChord)
        #expect(Set(defaults).count == defaults.count)
    }

    @Test func defaultChordMatchesShippedTable() {
        let expected: [BuiltinAction: Chord?] = [
            .newWindow: Chord(mods: [.command, .option], key: "n"),
            .renameWindow: nil,
            .deleteWindow: nil,
            .newWorkspace: Chord(mods: [.command, .shift], key: "n"),
            .renameWorkspace: nil,
            .deleteWorkspace: nil,
            .newSession: Chord(mods: [.command], key: "n"),
            .openDirectory: Chord(mods: [.command], key: "o"),
            .renameSession: nil,
            .duplicateSession: nil,
            .closeSession: Chord(mods: [.command], key: "w"),
            .reopenRecent: Chord(mods: [.command, .shift], key: "t"),
            .undoClose: Chord(mods: [.command], key: "z"),
            .clearStatus: nil,
            .increaseFontSize: Chord(mods: [.command], key: "+"),
            .decreaseFontSize: Chord(mods: [.command], key: "-"),
            .resetFontSize: Chord(mods: [.command], key: "0"),
            .toggleSplit: Chord(mods: [.command], key: "d"),
            .toggleHorizontalSplit: Chord(mods: [.command, .shift], key: "d"),
            .toggleScratch: Chord(mods: [.command], key: "j"),
            .toggleTerminalZoom: Chord(mods: [.command, .shift], key: "return"),
            .toggleSearch: Chord(mods: [.command], key: "f"),
            .toggleSidebar: Chord(mods: [.command, .control], key: "s"),
            .toggleFullscreen: Chord(mods: [.command, .control], key: "f"),
            .selectTheme: nil,
            .toggleFlaggedView: nil,
            .toggleWorkspaceFilter: nil,
            .toggleFlag: Chord(mods: [.command, .shift], key: "f"),
            .focusWorkspace: nil,
            .focusLeftPane: Chord(mods: [.command, .option], key: "left"),
            .focusRightPane: Chord(mods: [.command, .option], key: "right"),
            .previousSession: Chord(mods: [.command, .option], key: "up"),
            .nextSession: Chord(mods: [.command, .option], key: "down"),
            .previousAttentionSession: Chord(mods: [.control, .option], key: "up"),
            .nextAttentionSession: Chord(mods: [.control, .option], key: "down"),
            .firstSession: nil,
            .lastSession: nil,
            .quickTerminal: Chord(mods: [.control], key: "`"),
            .sessionPalette: Chord(mods: [.control], key: "p"),
            .commandPalette: Chord(mods: [.control, .shift], key: "p"),
            .customCommandPalette: Chord(mods: [.control, .shift], key: "o"),
            .showAttention: Chord(mods: [.control, .shift], key: "i"),
            .dashboard: Chord(mods: [.command, .shift], key: "g"),
        ]
        #expect(expected.count == BuiltinAction.allCases.count)
        for action in BuiltinAction.allCases {
            #expect(expected[action] == action.defaultChord, "default chord mismatch for \(action.rawValue)")
        }
    }

    @Test func toggleSearchDefaultIsCmdFAndRoundTrips() {
        let chord = Chord(mods: [.command], key: "f")
        #expect(BuiltinAction.toggleSearch.defaultChord == chord)
        #expect(chord.displayString == "cmd+f")
        #expect(parseKeybind(chord.displayString) == [chord])
    }

    @Test func toggleSidebarDefaultIsCmdCtrlSAndRoundTrips() {
        let chord = Chord(mods: [.command, .control], key: "s")
        #expect(BuiltinAction.toggleSidebar.defaultChord == chord)
        #expect(parseKeybind(chord.displayString) == [chord])
    }

    @Test func toggleFullscreenDefaultIsCmdCtrlFAndRoundTrips() {
        let chord = Chord(mods: [.command, .control], key: "f")
        #expect(BuiltinAction.toggleFullscreen.defaultChord == chord)
        #expect(parseKeybind(chord.displayString) == [chord])
    }

    @Test func customCommandPaletteDefaultIsCtrlShiftOAndRoundTrips() {
        let chord = Chord(mods: [.control, .shift], key: "o")
        #expect(BuiltinAction.customCommandPalette.defaultChord == chord)
        #expect(chord.displayString == "ctrl+shift+o")
        #expect(parseKeybind(chord.displayString) == [chord])
    }

    @Test func toggleFlagDefaultIsCmdShiftFAndRoundTrips() {
        let chord = Chord(mods: [.command, .shift], key: "f")
        #expect(BuiltinAction.toggleFlag.defaultChord == chord)
        #expect(chord.displayString == "cmd+shift+f")
        #expect(parseKeybind(chord.displayString) == [chord])
    }

    @Test func toggleWorkspaceFilterIsKeylessAndMappable() {
        // keyless like toggle_flagged_view, but its raw name must still be spellable in keymap.conf —
        // a keyless action the grammar can't name would be unreachable from the keyboard forever.
        #expect(BuiltinAction.toggleWorkspaceFilter.defaultChord == nil)
        let (keymap, diagnostics) = parseKeymap("map cmd+shift+g toggle_workspace_filter")
        #expect(diagnostics.isEmpty)
        let override = Chord(mods: [.command, .shift], key: "g")
        #expect(keymap.builtinOverrides == [.toggleWorkspaceFilter: override])
        #expect(keymap.equivalent(for: .toggleWorkspaceFilter) == override)
        #expect(Keymap(builtinOverrides: [:], commands: []).glyphHint(for: .toggleWorkspaceFilter) == nil)
    }

    @Test func keylessActionsHaveNilDefault() {
        let keyless: Set<BuiltinAction> = [
            .renameWindow, .deleteWindow, .renameWorkspace, .deleteWorkspace, .renameSession, .duplicateSession,
            .clearStatus, .firstSession, .lastSession, .selectTheme, .toggleFlaggedView, .focusWorkspace,
            .toggleWorkspaceFilter,
        ]
        for action in keyless {
            #expect(action.defaultChord == nil, "expected nil default for \(action.rawValue)")
        }
        #expect(BuiltinAction.allCases.filter { $0.defaultChord == nil } == BuiltinAction.allCases.filter { keyless.contains($0) })
    }
}
