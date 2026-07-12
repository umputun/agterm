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
        // spot-check the documented raw names so a rename can't drift silently.
        #expect(BuiltinAction.newWindow.rawValue == "new_window")
        #expect(BuiltinAction.toggleSplit.rawValue == "toggle_split")
        #expect(BuiltinAction.toggleTerminalZoom.rawValue == "toggle_terminal_zoom")
        #expect(BuiltinAction.toggleSearch.rawValue == "toggle_search")
        #expect(BuiltinAction.commandPalette.rawValue == "command_palette")
        #expect(BuiltinAction.customCommandPalette.rawValue == "custom_command_palette")
        #expect(BuiltinAction.nextAttentionSession.rawValue == "next_attention_session")
        #expect(BuiltinAction.toggleSidebar.rawValue == "toggle_sidebar")
        #expect(BuiltinAction.selectTheme.rawValue == "select_theme")
        #expect(BuiltinAction.toggleFlaggedView.rawValue == "toggle_flagged_view")
        #expect(BuiltinAction.toggleFlag.rawValue == "toggle_flag")
        #expect(BuiltinAction.focusWorkspace.rawValue == "focus_workspace")
        #expect(BuiltinAction.showAttention.rawValue == "show_attention")
        #expect(BuiltinAction.reopenRecent.rawValue == "reopen_recent")
        #expect(BuiltinAction.undoClose.rawValue == "undo_close")
        #expect(BuiltinAction.toggleFullscreen.rawValue == "toggle_fullscreen")
        #expect(BuiltinAction.dashboard.rawValue == "dashboard")
        #expect(BuiltinAction.allCases.count == 40)
    }

    @Test func rejectsUnknownName() {
        #expect(BuiltinAction(rawValue: "not_an_action") == nil)
        #expect(BuiltinAction(rawValue: "") == nil)
        #expect(BuiltinAction(rawValue: "New_Window") == nil)
    }

    @Test func arrowGlyphFallbackCoversTheSixArrowActions() {
        // the six arrow-bound actions can't round-trip through Chord, so their menu glyph is hardcoded.
        #expect(BuiltinAction.focusLeftPane.arrowGlyphFallback == "⌥⌘←")
        #expect(BuiltinAction.focusRightPane.arrowGlyphFallback == "⌥⌘→")
        #expect(BuiltinAction.previousSession.arrowGlyphFallback == "⌥⌘↑")
        #expect(BuiltinAction.nextSession.arrowGlyphFallback == "⌥⌘↓")
        #expect(BuiltinAction.previousAttentionSession.arrowGlyphFallback == "⌃⌥↑")
        #expect(BuiltinAction.nextAttentionSession.arrowGlyphFallback == "⌃⌥↓")
    }

    @Test func nonArrowActionsHaveNoArrowGlyphFallback() {
        // an action with an expressible default resolves through the keymap, not the fallback.
        #expect(BuiltinAction.toggleSidebar.arrowGlyphFallback == nil)
        #expect(BuiltinAction.newSession.arrowGlyphFallback == nil)
        // a keyless, non-arrow action has nothing.
        #expect(BuiltinAction.firstSession.arrowGlyphFallback == nil)
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
            .closeSession: Chord(mods: [.command], key: "w"),
            .reopenRecent: Chord(mods: [.command, .shift], key: "t"),
            .undoClose: Chord(mods: [.command], key: "z"),
            .clearStatus: nil,
            .increaseFontSize: Chord(mods: [.command], key: "+"),
            .decreaseFontSize: Chord(mods: [.command], key: "-"),
            .resetFontSize: Chord(mods: [.command], key: "0"),
            .toggleSplit: Chord(mods: [.command], key: "d"),
            .toggleScratch: Chord(mods: [.command], key: "j"),
            .toggleTerminalZoom: Chord(mods: [.command, .shift], key: "return"),
            .toggleSearch: Chord(mods: [.command], key: "f"),
            .toggleSidebar: Chord(mods: [.command, .control], key: "s"),
            .toggleFullscreen: Chord(mods: [.command, .control], key: "f"),
            .selectTheme: nil,      // keyless — gains a key only when the user maps one
            .toggleFlaggedView: nil, // keyless — gains a key only when the user maps one
            .toggleFlag: Chord(mods: [.command, .shift], key: "f"),
            .focusWorkspace: nil,   // keyless — gains a key only when the user maps one
            .focusLeftPane: nil,    // ⌘⌥← — arrow, not expressible as a parsed Chord
            .focusRightPane: nil,   // ⌘⌥→ — arrow
            .previousSession: nil,  // ⌥⌘↑ — arrow
            .nextSession: nil,      // ⌥⌘↓ — arrow
            .previousAttentionSession: nil, // ⌃⌥↑ — arrow
            .nextAttentionSession: nil,     // ⌃⌥↓ — arrow
            .firstSession: nil,
            .lastSession: nil,
            .quickTerminal: Chord(mods: [.control], key: "`"),
            .sessionPalette: Chord(mods: [.control], key: "p"),
            .commandPalette: Chord(mods: [.control, .shift], key: "p"),
            .customCommandPalette: Chord(mods: [.control, .shift], key: "o"),
            .showAttention: Chord(mods: [.control, .shift], key: "i"),
            .dashboard: Chord(mods: [.command, .shift], key: "d"),
        ]
        // the table must cover every case so a new action can't be added without a documented default.
        #expect(expected.count == BuiltinAction.allCases.count)
        for action in BuiltinAction.allCases {
            #expect(expected[action] == action.defaultChord, "default chord mismatch for \(action.rawValue)")
        }
    }

    @Test func toggleSearchDefaultIsCmdFAndRoundTrips() {
        let chord = Chord(mods: [.command], key: "f")
        #expect(BuiltinAction.toggleSearch.defaultChord == chord)
        // the chord must round-trip through the keymap grammar so the starter renders it as `cmd+f`,
        // not `(not expressible)` (the same check chordSyntax runs app-side).
        #expect(chord.displayString == "cmd+f")
        #expect(parseKeybind(chord.displayString) == [chord])
    }

    @Test func toggleSidebarDefaultIsCmdCtrlSAndRoundTrips() {
        let chord = Chord(mods: [.command, .control], key: "s")
        #expect(BuiltinAction.toggleSidebar.defaultChord == chord)
        // must round-trip through the keymap grammar (so the starter renders it, not "(not expressible)").
        #expect(parseKeybind(chord.displayString) == [chord])
    }

    @Test func toggleFullscreenDefaultIsCmdCtrlFAndRoundTrips() {
        let chord = Chord(mods: [.command, .control], key: "f")
        #expect(BuiltinAction.toggleFullscreen.defaultChord == chord)
        // must round-trip through the keymap grammar (so the starter renders it, not "(not expressible)").
        #expect(parseKeybind(chord.displayString) == [chord])
    }

    @Test func customCommandPaletteDefaultIsCtrlShiftOAndRoundTrips() {
        let chord = Chord(mods: [.control, .shift], key: "o")
        #expect(BuiltinAction.customCommandPalette.defaultChord == chord)
        // must round-trip through the keymap grammar (so the starter renders it, not "(not expressible)").
        #expect(chord.displayString == "ctrl+shift+o")
        #expect(parseKeybind(chord.displayString) == [chord])
    }

    @Test func toggleFlagDefaultIsCmdShiftFAndRoundTrips() {
        let chord = Chord(mods: [.command, .shift], key: "f")
        #expect(BuiltinAction.toggleFlag.defaultChord == chord)
        // must round-trip through the keymap grammar (so the starter renders it, not "(not expressible)").
        #expect(chord.displayString == "cmd+shift+f")
        #expect(parseKeybind(chord.displayString) == [chord])
    }

    @Test func keylessActionsHaveNilDefault() {
        let keyless: Set<BuiltinAction> = [
            .renameWindow, .deleteWindow, .renameWorkspace, .deleteWorkspace, .renameSession, .clearStatus,
            .firstSession, .lastSession, .selectTheme, .toggleFlaggedView, .focusWorkspace,
            // arrow-bound actions are also nil here (arrows can't round-trip through parseKeybind).
            .focusLeftPane, .focusRightPane, .previousSession, .nextSession,
            .previousAttentionSession, .nextAttentionSession,
        ]
        for action in keyless {
            #expect(action.defaultChord == nil, "expected nil default for \(action.rawValue)")
        }
    }
}
