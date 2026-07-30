import Foundation
import Testing
@testable import agtermCore

struct KeymapTests {
    @Test func overrideWinsOverDefault() {
        let override = Chord(mods: [.command, .shift], key: "e")
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
        #expect(BuiltinAction.firstSession.defaultChord == nil)
        let override = Chord(mods: [.command], key: "1")
        let keymap = Keymap(builtinOverrides: [.firstSession: override], commands: [])
        #expect(keymap.equivalent(for: .firstSession) == override)
    }

    @Test func keylessActionWithoutOverrideReturnsNil() {
        let keymap = Keymap(builtinOverrides: [:], commands: [])
        #expect(keymap.equivalent(for: .firstSession) == nil)
        #expect(keymap.equivalent(for: .focusLeftPane) == Chord(mods: [.command, .option], key: "left"))
    }

    @Test func parseMapHappyPath() {
        let (keymap, diagnostics) = parseKeymap("map cmd+shift+e toggle_split")
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "e")])
        #expect(keymap.commands.isEmpty)
    }

    // MARK: glyphHint — the shortcut shown in the palette and toolbar tooltips

    @Test func glyphHintRendersDefaultChordAsGlyphs() {
        let keymap = Keymap(builtinOverrides: [:], commands: [])
        #expect(keymap.glyphHint(for: .newSession) == "⌘N")
        #expect(keymap.glyphHint(for: .toggleSidebar) == "⌃⌘S")
        #expect(keymap.glyphHint(for: .toggleSplit) == "⌘D")
    }

    @Test func glyphHintUsesOverrideWhenPresent() {
        let keymap = Keymap(builtinOverrides: [.toggleSidebar: Chord(mods: [.command], key: "k")], commands: [])
        #expect(keymap.glyphHint(for: .toggleSidebar) == "⌘K")
    }

    @Test func glyphHintRendersArrowDefaultsAsGlyphs() {
        let keymap = Keymap(builtinOverrides: [:], commands: [])
        #expect(keymap.glyphHint(for: .previousSession) == "⌥⌘↑")
        #expect(keymap.glyphHint(for: .focusLeftPane) == "⌥⌘←")
    }

    @Test func glyphHintOverrideWinsOverArrowDefault() {
        let keymap = Keymap(builtinOverrides: [.previousSession: Chord(mods: [.command], key: "p")], commands: [])
        #expect(keymap.glyphHint(for: .previousSession) == "⌘P")
    }

    @Test func glyphHintIsNilForUnconfiguredAction() {
        // the "if not configured, don't add" rule that keeps tooltips clean.
        let keymap = Keymap(builtinOverrides: [:], commands: [])
        #expect(keymap.glyphHint(for: .toggleFlaggedView) == nil)
        #expect(keymap.glyphHint(for: .firstSession) == nil)
    }

    @Test func rebindToggleSearchResolvesThroughGenericPath() {
        // toggle_search resolves through the generic path, with no per-action special-casing.
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
        // a bare key would shadow that key in the terminal, so it is never consumed as a shortcut.
        let (keymap, diagnostics) = parseKeymap("command \"X\" a echo hi")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(keymap.commands[0].command == "a echo hi")
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("must include a modifier"))
    }

    @Test func parseCommandModifierShortcutAccepted() {
        let (keymap, diagnostics) = parseKeymap("command \"X\" cmd+e echo hi")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut == "cmd+e")
        #expect(keymap.commands[0].command == "echo hi")
    }

    @Test func parseCommandPaletteOnlyShellTokenNotSwallowed() {
        // the trap: a shell line starting with a single-char token (`[`, `:`, a one-letter alias) must
        // not have that token silently bound as a shortcut.
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

        map cmd+shift+e toggle_split  # inline comment
        # another comment
        command "Deploy" ./deploy.sh
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "e")])
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "Deploy")
    }

    @Test func inlineCommentInsideQuotedNameIsKept() {
        let (keymap, diagnostics) = parseKeymap("command \"name # not a comment\" echo hi")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "name # not a comment")
    }

    @Test func hashInsideSingleQuotedShellArgIsKept() {
        let (keymap, diagnostics) = parseKeymap("command \"Commit\" cmd+shift+c git commit -m 'fix #42'")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].command == "git commit -m 'fix #42'")
    }

    @Test func trailingCommentAfterSingleQuotedArgIsStripped() {
        let (keymap, diagnostics) = parseKeymap("command \"X\" cmd+shift+x echo 'hi' # real comment")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].command == "echo 'hi'")
    }

    @Test func doubleQuoteInsideSingleQuotesDoesNotOpenAQuotedSpan() {
        // a `"` inside `'...'` is literal, so the `#` after the single-quoted arg still starts a comment.
        let (keymap, diagnostics) = parseKeymap("command \"Y\" cmd+shift+y echo 'a\"b' # c")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].command == "echo 'a\"b'")
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

    @Test func parseArrowChordMapLines() {
        // the exact lines from #278: arrows are part of the chord grammar, so these parse cleanly.
        let text = """
        map cmd+shift+left previous_session
        map cmd+shift+right next_session
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.equivalent(for: .previousSession) == Chord(mods: [.command, .shift], key: "left"))
        #expect(keymap.equivalent(for: .nextSession) == Chord(mods: [.command, .shift], key: "right"))
    }

    @Test func parseBareArrowMapIsRejected() {
        // a bare arrow would install an always-on menu key-equivalent, swallowing the key in the
        // terminal, the palettes, the dashboard grid, and every text field.
        let (keymap, diagnostics) = parseKeymap("map left previous_session")
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(keymap.equivalent(for: .previousSession) == Chord(mods: [.command, .option], key: "up"))
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("needs a modifier"))
    }

    @Test func parseModifiedArrowMapIsAcceptedForEveryArrow() {
        for key in ["left", "right", "up", "down"] {
            let (keymap, diagnostics) = parseKeymap("map cmd+shift+\(key) new_session")
            #expect(diagnostics.isEmpty, "unexpected diagnostics for cmd+shift+\(key)")
            #expect(keymap.equivalent(for: .newSession) == Chord(mods: [.command, .shift], key: key))
        }
    }

    @Test func mapOntoAnArrowActionsUnmovedDefaultIsRejected() {
        // cmd+opt+up is previous_session's UNMOVED default, so claiming it for another action must be
        // diagnosed, not silently double-bound.
        let (keymap, diagnostics) = parseKeymap("map cmd+opt+up new_session")
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(keymap.equivalent(for: .newSession) == Chord(mods: [.command], key: "n"))
        #expect(keymap.equivalent(for: .previousSession) == Chord(mods: [.command, .option], key: "up"))
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("conflicts with built-in 'previous_session'"))
    }

    @Test func customCommandOnAnArrowDefaultIsDropped() {
        // cmd+opt+down is next_session's shipped default.
        let (keymap, diagnostics) = parseKeymap(#"command "Nav" cmd+opt+down echo hi"#)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "Nav")
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("built-in"))
    }

    @Test func parseBareNonArrowMapIsStillAccepted() {
        // the modifier requirement is arrow-ONLY; a bare non-arrow map stays legal.
        let (keymap, diagnostics) = parseKeymap("map a new_session")
        #expect(diagnostics.isEmpty)
        #expect(keymap.equivalent(for: .newSession) == Chord(mods: [], key: "a"))
    }

    @Test func parseDuplicateBuiltinChordDiagnostic() {
        let text = """
        map cmd+shift+e toggle_split
        map cmd+shift+e new_session
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "e")])
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 2)
        #expect(diagnostics[0].message.contains("conflicts with built-in 'toggle_split'"))
    }

    @Test func mapToOtherBuiltinUnmovedDefaultIsRejected() {
        // cmd+d is toggle_split's UNMOVED default; two menu items would otherwise carry the same key
        // equivalent.
        let (keymap, diagnostics) = parseKeymap("map cmd+d new_session")
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(keymap.equivalent(for: .newSession) == Chord(mods: [.command], key: "n"))
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 1)
        #expect(diagnostics[0].message.contains("conflicts with built-in 'toggle_split'"))
    }

    @Test func mapToFreedDefaultOfMovedBuiltinSucceeds() {
        // order is intentionally move-then-take: resolution is a single FINAL pass, so the freed
        // default is takeable.
        let text = """
        map cmd+shift+e toggle_split
        map cmd+d new_session
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides[.toggleSplit] == Chord(mods: [.command, .shift], key: "e"))
        #expect(keymap.builtinOverrides[.newSession] == Chord(mods: [.command], key: "d"))
    }

    @Test func mapToOtherBuiltinDefaultThenMoveThatBuiltinBothSucceed() {
        // the reverse order: resolution is decided against the FINAL state, so taking cmd+d before
        // toggle_split moves off it still succeeds.
        let text = """
        map cmd+d new_session
        map cmd+shift+e toggle_split
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides[.newSession] == Chord(mods: [.command], key: "d"))
        #expect(keymap.builtinOverrides[.toggleSplit] == Chord(mods: [.command, .shift], key: "e"))
    }

    @Test func mapTabSeparatedLineParses() {
        let (keymap, diagnostics) = parseKeymap("map\tcmd+shift+e\ttoggle_split")
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "e")])
    }

    @Test func mapCascadingCollisionDropsBothRevertsToDefaults() {
        // cascade: toggle_split's cmd+o override loses to open_directory's UNMOVED default, reverts to
        // its own cmd+d default, and that then collides with new_session's accepted cmd+d — so
        // resolution must iterate to a fixpoint and drop BOTH.
        let text = """
        map cmd+o toggle_split
        map cmd+d new_session
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(keymap.equivalent(for: .toggleSplit) == BuiltinAction.toggleSplit.defaultChord)
        #expect(keymap.equivalent(for: .newSession) == BuiltinAction.newSession.defaultChord)
        #expect(keymap.equivalent(for: .openDirectory) == BuiltinAction.openDirectory.defaultChord)
        // the final state is collision-free: no two distinct actions resolve to the same chord.
        let chords = BuiltinAction.allCases.compactMap { keymap.equivalent(for: $0) }
        #expect(chords.count == Set(chords).count)
        #expect(diagnostics.count == 2)
        #expect(diagnostics[0].line == 1)
        #expect(diagnostics[1].line == 2)
        #expect(diagnostics.allSatisfy { $0.message.contains("conflicts with built-in") })
    }

    @Test func mapBuiltinToReservedMonitorChordIsRejected() {
        // ctrl+1 is owned by the Ctrl-1/2 pane monitor, so a built-in mapped to it would dead-race it.
        let (keymap, diagnostics) = parseKeymap("map ctrl+1 new_session")
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(keymap.equivalent(for: .newSession) == Chord(mods: [.command], key: "n"))
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 1)
        #expect(diagnostics[0].message.contains("reserved"))
    }

    @Test func mapBuiltinToReservedCtrlTabIsRejected() {
        // ctrl+tab is the Ctrl-Tab switcher's chord.
        let (keymap, diagnostics) = parseKeymap("map ctrl+tab quick_terminal")
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("reserved"))
    }

    @Test func parseHandlesCRLFLineEndings() {
        // a CRLF file leaves a trailing \r that .whitespaces does not strip, so without normalization
        // the action reads as `toggle_split\r`.
        let text = "map cmd+shift+e toggle_split\r\ncommand \"Deploy\" ./deploy.sh\r\n"
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "e")])
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "Deploy")
    }

    @Test func mapSameActionTwiceIsLastWins() {
        let text = """
        map cmd+shift+e toggle_split
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
        map cmd+shift+e toggle_split
        bogus line here
        command "Deploy" ./deploy.sh
        map ctrl+a>g new_session
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "e")])
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "Deploy")
        #expect(diagnostics.count == 2)
        #expect(diagnostics[0].line == 2)
        #expect(diagnostics[0].message.contains("unknown verb"))
        #expect(diagnostics[1].line == 4)
        #expect(diagnostics[1].message == "built-in shortcut cannot be a leader sequence")
    }

    @Test func customChordEqualsBuiltinDefaultIsDropped() {
        // cmd+d is toggle_split's shipped default.
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
        // the custom command claims the chord toggle_split was just MOVED to, not its shipped default.
        let text = """
        map cmd+shift+e toggle_split
        command "Boom" cmd+shift+e echo boom
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "e")])
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("built-in"))
    }

    @Test func freedDefaultChordIsUsableByCustomAfterBuiltinMoves() {
        // order is intentionally custom-before-map: validation is a single FINAL pass, so the freed
        // default is takeable.
        let text = """
        command "Boom" cmd+d echo boom
        map cmd+shift+e toggle_split
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "e")])
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
        // ctrl+1 is owned by the Ctrl-1/2 pane monitor.
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
        // ctrl+tab is the Ctrl-Tab switcher's chord.
        let (keymap, diagnostics) = parseKeymap("command \"Boom\" ctrl+tab>g echo boom")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("reserved"))
    }

    @Test func customLeaderWhoseLaterChordIsReservedMonitorChordIsDropped() {
        // the FIRST chord is free, but the pane monitor consumes ctrl+1 wherever it lands in the
        // leader, so the sequence can never complete.
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
        let (keymap, diagnostics) = parseKeymap("command \"Lazygit\" ctrl+a>g lazygit")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut == "ctrl+a>g")
        #expect(diagnostics.isEmpty)
    }

    @Test func commandWithEmptyShellLineIsDiagnosed() {
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
        #expect(keymap.commands[0].command == "echo one")
        #expect(keymap.commands[1].command == "echo two")
        #expect(diagnostics.count == 2)
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
        #expect(diagnostics.contains { $0.message.contains("'Lead'") && $0.message.contains("'Leader'") })
        #expect(diagnostics.contains { $0.message.contains("'Leader'") && $0.message.contains("'Lead'") })
    }

    @Test func keymapStoreLoadsFileAndRecoversWhenMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-keymap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KeymapStore(configDirectory: dir)

        #expect(store.path == ConfigPaths.keymapPath(configDirectory: dir))
        #expect(store.load().keymap.commands.isEmpty)
        #expect(store.load().diagnostics.isEmpty)

        try "command \"Greet\" ctrl+shift+y echo hi\n".write(to: store.path, atomically: true, encoding: .utf8)
        let loaded = store.load()
        #expect(loaded.keymap.commands.contains { $0.name == "Greet" })
        #expect(loaded.diagnostics.isEmpty)
    }

    @Test func keymapStoreReportsMalformedKeymapDiagnostics() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-keymap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KeymapStore(configDirectory: dir)

        try "map cmd+d not_an_action\ncommand \"Good\" ctrl+shift+y echo ok\n"
            .write(to: store.path, atomically: true, encoding: .utf8)
        let loaded = store.load()

        #expect(loaded.keymap.commands.contains { $0.name == "Good" })
        #expect(loaded.diagnostics.contains { $0.line == 1 && $0.message.contains("unknown action") })
    }

    @Test func keymapStoreReportsUnreadableTextFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-keymap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KeymapStore(configDirectory: dir)

        try Data([0xff, 0xfe, 0xfd]).write(to: store.path)
        let loaded = store.load()

        #expect(loaded.keymap == Keymap(builtinOverrides: [:], commands: []))
        #expect(loaded.diagnostics.count == 1)
        #expect(loaded.diagnostics[0].line == 0)
        #expect(loaded.diagnostics[0].message.contains("could not read keymap.conf"))
    }
}
