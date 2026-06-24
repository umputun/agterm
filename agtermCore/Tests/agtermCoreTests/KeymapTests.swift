import Foundation
import Testing
@testable import agtermCore

struct KeymapTests {
    @Test func overrideWinsOverDefault() {
        let override = Chord(mods: [.command, .shift], key: "d")
        let keymap = Keymap(builtinOverrides: [.toggleSplit: override], commands: [])
        #expect(keymap.equivalent(for: .toggleSplit) == override)
        // sanity: the shipped default differs from the override, so this is a real win.
        #expect(BuiltinAction.toggleSplit.defaultChord != override)
    }

    @Test func absentOverrideFallsBackToDefault() {
        let keymap = Keymap(builtinOverrides: [:], commands: [])
        #expect(keymap.equivalent(for: .toggleSplit) == BuiltinAction.toggleSplit.defaultChord)
        #expect(keymap.equivalent(for: .newSession) == Chord(mods: [.command], key: "n"))
    }

    @Test func keylessActionWithOverrideReturnsOverride() {
        // firstSession has no default chord; an override gives it one.
        #expect(BuiltinAction.firstSession.defaultChord == nil)
        let override = Chord(mods: [.command], key: "1")
        let keymap = Keymap(builtinOverrides: [.firstSession: override], commands: [])
        #expect(keymap.equivalent(for: .firstSession) == override)
    }

    @Test func keylessActionWithoutOverrideReturnsNil() {
        let keymap = Keymap(builtinOverrides: [:], commands: [])
        #expect(keymap.equivalent(for: .firstSession) == nil)
        // an arrow-bound action is also nil with no override.
        #expect(keymap.equivalent(for: .focusLeftPane) == nil)
    }

    @Test func parseMapHappyPath() {
        let (keymap, diagnostics) = parseKeymap("map cmd+shift+d toggle_split")
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "d")])
        #expect(keymap.commands.isEmpty)
    }

    @Test func rebindToggleSearchResolvesThroughGenericPath() {
        // toggle_search rebinds like any other built-in: the generic parse/resolve path (no per-action
        // special-casing) parses the chord, maps the raw name to .toggleSearch, and equivalent(for:)
        // returns the override instead of the cmd+f default.
        let (keymap, diagnostics) = parseKeymap("map cmd+shift+l toggle_search")
        #expect(diagnostics.isEmpty)
        let override = Chord(mods: [.command, .shift], key: "l")
        #expect(keymap.builtinOverrides == [.toggleSearch: override])
        #expect(keymap.equivalent(for: .toggleSearch) == override)
        // sanity: the default is the shipped cmd+f, so the override is a real rebind.
        #expect(BuiltinAction.toggleSearch.defaultChord == Chord(mods: [.command], key: "f"))
    }

    @Test func parseCommandHappyPath() {
        let (keymap, diagnostics) = parseKeymap("command \"Lazygit\" ctrl+a>g lazygit")
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(keymap.commands.count == 1)
        let command = keymap.commands[0]
        #expect(command.name == "Lazygit")
        #expect(command.shortcut == "ctrl+a>g")
        #expect(command.command == "lazygit")
    }

    @Test func parseCommandQuotedNameWithSpaces() {
        let (keymap, diagnostics) = parseKeymap("command \"Open in Zed\" cmd+shift+e open -a Zed {AGT_SESSION_PWD}")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.count == 1)
        let command = keymap.commands[0]
        #expect(command.name == "Open in Zed")
        #expect(command.shortcut == "cmd+shift+e")
        #expect(command.command == "open -a Zed {AGT_SESSION_PWD}")
    }

    @Test func parseCommandPaletteOnlyWhenNoChord() {
        let (keymap, diagnostics) = parseKeymap("command \"Deploy\" ./deploy.sh")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.count == 1)
        let command = keymap.commands[0]
        #expect(command.name == "Deploy")
        #expect(command.shortcut.isEmpty)
        #expect(command.command == "./deploy.sh")
    }

    @Test func parseCommandBareKeyRejectedAsShortcut() {
        // a modifier-less first token (a bare key) is NOT consumed as a shortcut: it would shadow that
        // key in the terminal, so the line stays palette-only with the token kept in the shell line and
        // a diagnostic is emitted.
        let (keymap, diagnostics) = parseKeymap("command \"X\" a echo hi")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(keymap.commands[0].command == "a echo hi")
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("must include a modifier"))
    }

    @Test func parseCommandModifierShortcutAccepted() {
        // a single chord WITH a modifier is a valid custom shortcut.
        let (keymap, diagnostics) = parseKeymap("command \"X\" cmd+e echo hi")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut == "cmd+e")
        #expect(keymap.commands[0].command == "echo hi")
    }

    @Test func parseCommandPaletteOnlyShellTokenNotSwallowed() {
        // the trap: a palette-only command whose shell line starts with a single-char token (`[`, `:`,
        // a one-letter alias) must NOT have that token silently bound as a shortcut.
        let (keymap, diagnostics) = parseKeymap("command \"Check\" [ -f /tmp ] && echo ok")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(keymap.commands[0].command == "[ -f /tmp ] && echo ok")
        #expect(diagnostics.count == 1)
    }

    @Test func parseCommandPreservesAgtTokens() {
        let (keymap, diagnostics) = parseKeymap("command \"Notify\" echo {AGT_SELECTION} > {AGT_SOCKET}")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].command == "echo {AGT_SELECTION} > {AGT_SOCKET}")
    }

    @Test func parseSkipsCommentsAndBlankLines() {
        let text = """
        # leading comment

        map cmd+shift+d toggle_split  # inline comment
        # another comment
        command "Deploy" ./deploy.sh
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "d")])
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "Deploy")
    }

    @Test func inlineCommentInsideQuotedNameIsKept() {
        let (keymap, diagnostics) = parseKeymap("command \"name # not a comment\" echo hi")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "name # not a comment")
    }

    @Test func parseUnknownVerbDiagnostic() {
        let (keymap, diagnostics) = parseKeymap("bind cmd+d toggle_split")
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 1)
        #expect(diagnostics[0].message.contains("unknown verb"))
    }

    @Test func parseUnknownActionDiagnostic() {
        let (keymap, diagnostics) = parseKeymap("map cmd+d not_an_action")
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 1)
        #expect(diagnostics[0].message.contains("unknown action"))
    }

    @Test func parseLeaderOnBuiltinDiagnostic() {
        let (keymap, diagnostics) = parseKeymap("map ctrl+a>g toggle_split")
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 1)
        #expect(diagnostics[0].message == "built-in shortcut cannot be a leader sequence")
    }

    @Test func parseInvalidChordDiagnostic() {
        let (keymap, diagnostics) = parseKeymap("map cmd+f1 toggle_split")
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("invalid chord"))
    }

    @Test func parseDuplicateBuiltinChordDiagnostic() {
        // two maps to the same chord for DIFFERENT actions: the later one (line 2) is skipped.
        let text = """
        map cmd+shift+d toggle_split
        map cmd+shift+d new_session
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "d")])
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 2)
        #expect(diagnostics[0].message.contains("conflicts with built-in 'toggle_split'"))
    }

    @Test func mapToOtherBuiltinUnmovedDefaultIsRejected() {
        // cmd+d is toggle_split's UNMOVED default; mapping new_session to it must be diagnosed and the
        // override dropped (otherwise two menu items would carry the same key equivalent). The CRITICAL
        // case: the prior check only caught override-vs-override, not override-vs-other-default.
        let (keymap, diagnostics) = parseKeymap("map cmd+d new_session")
        #expect(keymap.builtinOverrides.isEmpty)
        // new_session keeps its own default (the map was skipped, not applied).
        #expect(keymap.equivalent(for: .newSession) == Chord(mods: [.command], key: "n"))
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 1)
        #expect(diagnostics[0].message.contains("conflicts with built-in 'toggle_split'"))
    }

    @Test func mapToFreedDefaultOfMovedBuiltinSucceeds() {
        // moving toggle_split off cmd+d frees that chord; new_session may then take it. order is
        // intentionally move-then-take, and the resolution is a single FINAL pass so it succeeds with
        // no diagnostic — the freed-default case must not regress.
        let text = """
        map cmd+shift+d toggle_split
        map cmd+d new_session
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides[.toggleSplit] == Chord(mods: [.command, .shift], key: "d"))
        #expect(keymap.builtinOverrides[.newSession] == Chord(mods: [.command], key: "d"))
    }

    @Test func mapToOtherBuiltinDefaultThenMoveThatBuiltinBothSucceed() {
        // codex's reverse-order case: take cmd+d for new_session FIRST, then move toggle_split off cmd+d.
        // resolution is order-independent and decided against the final state, so both succeed with NO
        // diagnostic (final state is conflict-free: new_session=cmd+d, toggle_split=cmd+shift+d).
        let text = """
        map cmd+d new_session
        map cmd+shift+d toggle_split
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides[.newSession] == Chord(mods: [.command], key: "d"))
        #expect(keymap.builtinOverrides[.toggleSplit] == Chord(mods: [.command, .shift], key: "d"))
    }

    @Test func mapTabSeparatedLineParses() {
        // a tab between the chord and the action must parse the same as a space.
        let (keymap, diagnostics) = parseKeymap("map\tcmd+shift+d\ttoggle_split")
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "d")])
    }

    @Test func mapCascadingCollisionDropsBothRevertsToDefaults() {
        // cascade: toggle_split's override (cmd+o) loses to open_directory's UNMOVED default cmd+o, so
        // it is dropped → reverts to its OWN default cmd+d → which then collides with new_session's
        // accepted override cmd+d. Resolution must iterate to a fixpoint and drop BOTH overrides, leaving
        // a conflict-free all-defaults state with two diagnostics.
        let text = """
        map cmd+o toggle_split
        map cmd+d new_session
        """
        let (keymap, diagnostics) = parseKeymap(text)
        // both overrides dropped → every action sits on its shipped default.
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(keymap.equivalent(for: .toggleSplit) == BuiltinAction.toggleSplit.defaultChord)
        #expect(keymap.equivalent(for: .newSession) == BuiltinAction.newSession.defaultChord)
        #expect(keymap.equivalent(for: .openDirectory) == BuiltinAction.openDirectory.defaultChord)
        // the final state is collision-free: no two distinct actions resolve to the same chord.
        let chords = BuiltinAction.allCases.compactMap { keymap.equivalent(for: $0) }
        #expect(chords.count == Set(chords).count)
        // two diagnostics, one per dropped override, in file order.
        #expect(diagnostics.count == 2)
        #expect(diagnostics[0].line == 1)
        #expect(diagnostics[1].line == 2)
        #expect(diagnostics.allSatisfy { $0.message.contains("conflicts with built-in") })
    }

    @Test func mapBuiltinToReservedMonitorChordIsRejected() {
        // ctrl+1 is owned by the Ctrl-1/2 pane monitor; a built-in map to it must be diagnosed + skipped
        // (it would dead-race the monitor), so the action keeps its default.
        let (keymap, diagnostics) = parseKeymap("map ctrl+1 new_session")
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(keymap.equivalent(for: .newSession) == Chord(mods: [.command], key: "n"))
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 1)
        #expect(diagnostics[0].message.contains("reserved"))
    }

    @Test func mapBuiltinToReservedCtrlTabIsRejected() {
        // ctrl+tab is the Ctrl-Tab switcher's chord; a built-in map to it is reserved and skipped.
        let (keymap, diagnostics) = parseKeymap("map ctrl+tab quick_terminal")
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("reserved"))
    }

    @Test func parseHandlesCRLFLineEndings() {
        // a CRLF file leaves a trailing \r that .whitespaces does not strip; normalization must let the
        // line parse normally rather than reading `toggle_split\r` as an unknown action.
        let text = "map cmd+shift+d toggle_split\r\ncommand \"Deploy\" ./deploy.sh\r\n"
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "d")])
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "Deploy")
    }

    @Test func mapSameActionTwiceIsLastWins() {
        // re-mapping the SAME action can't collide with itself: the later chord wins, no diagnostic.
        let text = """
        map cmd+shift+d toggle_split
        map cmd+shift+x toggle_split
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "x")])
    }

    @Test func parseMapMissingActionDiagnostic() {
        let (keymap, diagnostics) = parseKeymap("map cmd+d")
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("map requires"))
    }

    @Test func parseCommandMissingQuotedNameDiagnostic() {
        let (keymap, diagnostics) = parseKeymap("command Deploy ./deploy.sh")
        #expect(keymap.commands.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("quoted name"))
    }

    @Test func parseDiagnosticLineNumbersWhileGoodLinesParse() {
        let text = """
        map cmd+shift+d toggle_split
        bogus line here
        command "Deploy" ./deploy.sh
        map ctrl+a>g new_session
        """
        let (keymap, diagnostics) = parseKeymap(text)
        // the two valid lines still parse.
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "d")])
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "Deploy")
        // the two bad lines each yield a diagnostic at the correct line number.
        #expect(diagnostics.count == 2)
        #expect(diagnostics[0].line == 2)
        #expect(diagnostics[0].message.contains("unknown verb"))
        #expect(diagnostics[1].line == 4)
        #expect(diagnostics[1].message == "built-in shortcut cannot be a leader sequence")
    }

    @Test func customChordEqualsBuiltinDefaultIsDropped() {
        // cmd+d is toggle_split's shipped default; the custom command keeps its palette entry but
        // loses the keybind.
        let (keymap, diagnostics) = parseKeymap("command \"Boom\" cmd+d echo boom")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "Boom")
        #expect(keymap.commands[0].command == "echo boom")
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 0)
        #expect(diagnostics[0].message.contains("built-in"))
    }

    @Test func customChordEqualsOverriddenBuiltinChordIsDropped() {
        // the built-in toggle_split is moved to cmd+shift+d; a custom command bound to the NEW
        // built-in chord collides and is dropped.
        let text = """
        map cmd+shift+d toggle_split
        command "Boom" cmd+shift+d echo boom
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "d")])
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("built-in"))
    }

    @Test func freedDefaultChordIsUsableByCustomAfterBuiltinMoves() {
        // moving toggle_split off cmd+d frees that chord; a custom command may then take it. order
        // is intentionally custom-before-map to prove validation is a single FINAL pass.
        let text = """
        command "Boom" cmd+d echo boom
        map cmd+shift+d toggle_split
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "d")])
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut == "cmd+d")
        #expect(diagnostics.isEmpty)
    }

    @Test func customLeaderWhoseFirstChordEqualsBuiltinIsDropped() {
        // toggle_split's default is cmd+d; a custom leader STARTING with cmd+d is shadowed by the menu.
        let (keymap, diagnostics) = parseKeymap("command \"Boom\" cmd+d>g echo boom")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("built-in"))
    }

    @Test func customBoundToReservedMonitorChordIsDropped() {
        // ctrl+1 is owned by the Ctrl-1/2 pane monitor; a custom command bound to it keeps its palette
        // entry but loses the keybind, with a diagnostic.
        let (keymap, diagnostics) = parseKeymap("command \"Boom\" ctrl+1 echo boom")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "Boom")
        #expect(keymap.commands[0].command == "echo boom")
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 0)
        #expect(diagnostics[0].message.contains("reserved"))
    }

    @Test func customLeaderStartingWithReservedMonitorChordIsDropped() {
        // ctrl+tab is the Ctrl-Tab switcher's chord; a custom leader STARTING with it is reserved.
        let (keymap, diagnostics) = parseKeymap("command \"Boom\" ctrl+tab>g echo boom")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("reserved"))
    }

    @Test func customLeaderWhoseLaterChordIsReservedMonitorChordIsDropped() {
        // ctrl+a>ctrl+1 — the FIRST chord (ctrl+a) is not reserved, but ctrl+1 (the later chord) is
        // owned by the Ctrl-1/2 pane monitor, which consumes it wherever it lands in the leader, so the
        // leader can never complete. the keybind is dropped (palette entry kept) with a diagnostic.
        let (keymap, diagnostics) = parseKeymap("command \"Boom\" ctrl+a>ctrl+1 echo boom")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "Boom")
        #expect(keymap.commands[0].command == "echo boom")
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 0)
        #expect(diagnostics[0].message.contains("reserved"))
    }

    @Test func customLeaderWithNoReservedChordIsAccepted() {
        // a normal leader with no reserved chord at any position keeps its keybind, no diagnostic.
        let (keymap, diagnostics) = parseKeymap("command \"Lazygit\" ctrl+a>g lazygit")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut == "ctrl+a>g")
        #expect(diagnostics.isEmpty)
    }

    @Test func commandWithEmptyShellLineIsDiagnosed() {
        // a name with no shell line (or a name + chord with no command) is a no-op; skip it + diagnose.
        let (keymap, diagnostics) = parseKeymap("command \"Empty\"")
        #expect(keymap.commands.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 1)
        #expect(diagnostics[0].message.contains("no shell line"))
    }

    @Test func commandWithChordButEmptyShellLineIsDiagnosed() {
        let (keymap, diagnostics) = parseKeymap("command \"Empty\" cmd+shift+e")
        #expect(keymap.commands.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("no shell line"))
    }

    @Test func customVsCustomDuplicateDropsBoth() {
        let text = """
        command "First" cmd+shift+e echo one
        command "Second" cmd+shift+e echo two
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.commands.count == 2)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(keymap.commands[1].shortcut.isEmpty)
        // both commands stay in the palette, just unkeyed.
        #expect(keymap.commands[0].command == "echo one")
        #expect(keymap.commands[1].command == "echo two")
        #expect(diagnostics.count == 2)
        // each diagnostic names the OTHER offending command by name.
        #expect(diagnostics.contains { $0.message.contains("'First'") && $0.message.contains("'Second'") })
        #expect(diagnostics.contains { $0.message.contains("'Second'") && $0.message.contains("'First'") })
    }

    @Test func customVsCustomPrefixDropsBoth() {
        // a single chord that is a prefix of a leader sequence is the wait-or-fire ambiguity.
        let text = """
        command "Lead" ctrl+a echo lead
        command "Leader" ctrl+a>g echo leader
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.commands.count == 2)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(keymap.commands[1].shortcut.isEmpty)
        #expect(diagnostics.count == 2)
        // each diagnostic names the OTHER offending command by name.
        #expect(diagnostics.contains { $0.message.contains("'Lead'") && $0.message.contains("'Leader'") })
        #expect(diagnostics.contains { $0.message.contains("'Leader'") && $0.message.contains("'Lead'") })
    }
}
