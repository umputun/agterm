import Foundation
import Testing
@testable import agtermCore

/// A realistic `keymap.conf` holding no `|` and no multi-chord `map` — the exact shape the compatibility
/// invariant covers. It carries the paths that could drift: a bare non-arrow map, a modified arrow, keyed and
/// palette-only commands, and three conflicts whose diagnostics quote non-canonical raw spellings.
/// `ControlKeymapTests` and `SocketClientTests` pin the projection and the rendering of the same text.
let pipeFreeKeymapFixture = """
# regression fixture: no `|` anywhere, no multi-chord map
map cmd+shift+e toggle_split
map t toggle_sidebar
map ctrl+cmd+left focus_left_pane
map cmd+w new_session

command "Deploy" cmd+shift+y ./deploy.sh
command "Open Notes" vim {AGT_SESSION_PWD}/notes.md
command "Clash" command+shift+e echo clash
command "First" control+shift+g echo one
command "Second" ctrl+shift+g echo two
"""

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

    @Test func glyphHintAppendsAlternativesAfterTheMenuChord() {
        let (keymap, diagnostics) = parseKeymap("map cmd+t|ctrl+space>s|cmd+ctrl+y toggle_split")
        #expect(diagnostics.isEmpty)
        #expect(keymap.glyphHint(for: .toggleSplit) == "⌘T ⌃␣>S ⌃⌘Y")
    }

    @Test func glyphHintReturnsAlternativesAloneWithoutAMenuChord() {
        let (keymap, diagnostics) = parseKeymap("map ctrl+a>g|ctrl+a>h toggle_sidebar")
        #expect(diagnostics.isEmpty)
        #expect(keymap.glyphHint(for: .toggleSidebar) == "⌃A>G ⌃A>H")
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

    @Test func parseCommandAlternativeShortcutsAreKeptVerbatim() {
        let (keymap, diagnostics) = parseKeymap("command \"Midnight Commander\" ctrl+a>m|cmd+a>m mc")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut == "ctrl+a>m|cmd+a>m")
        #expect(keymap.commands[0].command == "mc")
    }

    @Test func parseCommandDedupesIdenticalAlternatives() {
        let (keymap, diagnostics) = parseKeymap("command \"X\" cmd+e|command+e echo hi")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands[0].shortcut == "cmd+e")
        #expect(keymap.commands[0].command == "echo hi")
    }

    // a rule violation drops the offending alternative alone on either verb, so the modifier-less half cannot
    // take the working one down with it.
    @Test func parseCommandBareAlternativeDropsAloneAndKeepsTheSibling() {
        let (keymap, diagnostics) = parseKeymap("command \"X\" cmd+e|t echo hi")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut == "cmd+e")
        #expect(keymap.commands[0].command == "echo hi")
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message == "command 'X' shortcut 't' must include a modifier; alternative skipped")
    }

    @Test func parseCommandWithNoModifierOnAnyAlternativeStaysPaletteOnly() {
        let (keymap, diagnostics) = parseKeymap("command \"X\" t|y echo hi")
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(keymap.commands[0].command == "t|y echo hi")
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message
            == "command 'X' shortcut 't|y' must include a modifier; treating the line as palette-only")
    }

    // a typo beside a real alternative is a typo, not a shell line: it kills the binding AND says so, rather
    // than folding `cmd+e|f1` silently into the command.
    @Test func parseCommandMalformedAlternativeIsDiagnosedAndLeavesTheLinePaletteOnly() {
        let (keymap, diagnostics) = parseKeymap("command \"X\" cmd+e|f1 echo hi")
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(keymap.commands[0].command == "cmd+e|f1 echo hi")
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message
            == "command 'X' shortcut 'cmd+e|f1' has an invalid alternative; treating the line as palette-only")
    }

    // a binding whose own alternatives are a prefix pair keeps the one that fires: both run the same command,
    // so the ambiguity costs the user nothing and dropping the pair would take a working key away for it.
    @Test func parseCommandAlternativesConflictingWithEachOtherKeepTheFiringOne() {
        let (keymap, diagnostics) = parseKeymap("command \"X\" ctrl+a|ctrl+a>b echo hi")
        #expect(keymap.commands[0].shortcut == "ctrl+a")
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message
            == "custom command 'X' shortcut 'ctrl+a>b' conflicts with custom command 'X'; alternative dropped")
    }

    @Test func parseCommandLeadingShellPipelineIsNotDiagnosedAsABinding() {
        let (keymap, diagnostics) = parseKeymap("command \"X\" ls|grep foo")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(keymap.commands[0].command == "ls|grep foo")
    }

    // accepted imperfection: `a|b` used to fail parseChord outright, so the tail was shell with no
    // diagnostic. it now splits into two bare chords and earns one. the shell line is identical either way.
    @Test func parseCommandPipedShellTokenKeepsItsShellLine() {
        let (keymap, diagnostics) = parseKeymap("command \"X\" a|b echo hi")
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(keymap.commands[0].command == "a|b echo hi")
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("must include a modifier"))
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

    @Test func parseLeaderOnBuiltinBindsTheMonitorAndUnbindsTheMenu() {
        let (keymap, diagnostics) = parseKeymap("map ctrl+a>g toggle_split")
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides.isEmpty)
        #expect(keymap.sequences(for: .toggleSplit) == [[Chord(mods: [.control], key: "a"), Chord(mods: [], key: "g")]])
        // the line declares the whole binding, so ⌘D must not stay live behind the sequence.
        #expect(keymap.equivalent(for: .toggleSplit) == nil)
        #expect(keymap.builtinUnbound == [.toggleSplit])
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
        // exact: a single-alternative rejection is compat-critical wording and must carry no scope suffix.
        #expect(diagnostics[0].message == "bare arrow chord 'left' needs a modifier; map skipped")
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
        #expect(keymap.sequences(for: .newSession).isEmpty)
        #expect(keymap.builtinUnbound.isEmpty)
    }

    // MARK: map alternatives — `|` splits a binding into a menu-bound chord and monitor-bound rest

    @Test func mapAlternativesSplitBetweenMenuAndMonitor() {
        let (keymap, diagnostics) = parseKeymap("map cmd+t|ctrl+space>s toggle_split")
        #expect(diagnostics.isEmpty)
        #expect(keymap.equivalent(for: .toggleSplit) == Chord(mods: [.command], key: "t"))
        #expect(keymap.sequences(for: .toggleSplit) == [[Chord(mods: [.control], key: "space"), Chord(mods: [], key: "s")]])
        #expect(keymap.builtinUnbound.isEmpty)
    }

    @Test func mapTwoSingleChordAlternativesPutTheFirstOnTheMenu() {
        let (keymap, diagnostics) = parseKeymap("map cmd+t|cmd+y toggle_split")
        #expect(diagnostics.isEmpty)
        #expect(keymap.equivalent(for: .toggleSplit) == Chord(mods: [.command], key: "t"))
        #expect(keymap.sequences(for: .toggleSplit) == [[Chord(mods: [.command], key: "y")]])
    }

    @Test func mapSequenceOnlyLineLeavesTheActionWithoutAMenuChord() {
        let (keymap, diagnostics) = parseKeymap("map ctrl+space>s toggle_split")
        #expect(diagnostics.isEmpty)
        #expect(keymap.equivalent(for: .toggleSplit) == nil)
        #expect(keymap.glyphHint(for: .toggleSplit) == "⌃␣>S")
        #expect(keymap.sequences(for: .toggleSplit) == [[Chord(mods: [.control], key: "space"), Chord(mods: [], key: "s")]])
        // an untouched action keeps its shipped default: only the mapped one goes unbound.
        #expect(keymap.equivalent(for: .newSession) == Chord(mods: [.command], key: "n"))
    }

    @Test func mapBareFirstChordOnAMonitorAlternativeIsRejected() {
        let (keymap, diagnostics) = parseKeymap("map cmd+t|y>s toggle_split")
        #expect(keymap.equivalent(for: .toggleSplit) == Chord(mods: [.command], key: "t"))
        #expect(keymap.sequences(for: .toggleSplit).isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message == "chord 'y>s' needs a modifier on its first key; alternative skipped")
    }

    // the cross-section passes must reach the same end as a parse-time rejection: the line bound nothing, so
    // the action keeps the chord the file never asked to move rather than ending up with no binding at all.
    @Test func mapWhoseOnlyAlternativeIsShadowedByABuiltinKeepsTheShippedDefault() {
        let (keymap, diagnostics) = parseKeymap("map ctrl+a new_session\nmap ctrl+a>s toggle_split")
        #expect(keymap.equivalent(for: .toggleSplit) == BuiltinAction.toggleSplit.defaultChord)
        #expect(keymap.sequences(for: .toggleSplit).isEmpty)
        #expect(!keymap.builtinUnbound.contains(.toggleSplit))
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message == "built-in 'toggle_split' chord 'ctrl+a>s' conflicts with a built-in; keybind dropped")
    }

    @Test func mapWhoseOnlyAlternativeLosesAConflictKeepsTheShippedDefault() {
        let (keymap, diagnostics) = parseKeymap("map ctrl+a>s toggle_split\ncommand \"X\" ctrl+a>s echo x")
        #expect(keymap.equivalent(for: .toggleSplit) == BuiltinAction.toggleSplit.defaultChord)
        #expect(keymap.sequences(for: .toggleSplit).isEmpty)
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(diagnostics.count == 2)
    }

    // the one case the restoration must NOT take: being unbound is what freed the default, so another
    // built-in may already hold it and handing it back would double-bind the chord.
    @Test func aStrandedActionStaysUnboundWhenAnotherBuiltinTookItsDefault() {
        let text = """
        map ctrl+a>d toggle_split
        map cmd+d new_session
        map ctrl+a quick_terminal
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.equivalent(for: .newSession) == Chord(mods: [.command], key: "d"))
        #expect(keymap.equivalent(for: .toggleSplit) == nil)
        #expect(keymap.sequences(for: .toggleSplit).isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("conflicts with a built-in"))
    }

    // the menu half losing a collision leaves the alternatives firing, so the line was not skipped.
    @Test func mapWhoseMenuChordCollidesKeepsItsAlternativesAndSaysSo() {
        let (keymap, diagnostics) = parseKeymap("map cmd+w|ctrl+a>w toggle_split")
        #expect(keymap.equivalent(for: .toggleSplit) == BuiltinAction.toggleSplit.defaultChord)
        #expect(keymap.sequences(for: .toggleSplit)
            == [[Chord(mods: [.control], key: "a"), Chord(mods: [], key: "w")]])
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message == "chord conflicts with built-in 'close_session'; alternative skipped")
    }

    @Test func mapWithNoAlternativesLeftStillReportsTheLineAsSkipped() {
        let (keymap, diagnostics) = parseKeymap("map cmd+w toggle_split")
        #expect(keymap.equivalent(for: .toggleSplit) == BuiltinAction.toggleSplit.defaultChord)
        #expect(diagnostics[0].message == "chord conflicts with built-in 'close_session'; map skipped")
    }

    @Test func mapWithOnlyABareSequenceKeepsTheShippedDefault() {
        // every alternative dropped means the line records nothing, exactly as a rejected single chord does.
        let (keymap, diagnostics) = parseKeymap("map y>s toggle_split")
        #expect(keymap.equivalent(for: .toggleSplit) == BuiltinAction.toggleSplit.defaultChord)
        #expect(keymap.builtinUnbound.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message == "chord 'y>s' needs a modifier on its first key; map skipped")
    }

    @Test func mapReservedAlternativeDropsAloneAndLeavesTheSiblingLive() {
        let (keymap, diagnostics) = parseKeymap("map ctrl+1|ctrl+a>s toggle_split")
        #expect(keymap.equivalent(for: .toggleSplit) == nil)
        #expect(keymap.sequences(for: .toggleSplit) == [[Chord(mods: [.control], key: "a"), Chord(mods: [], key: "s")]])
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message == "chord 'ctrl+1' is a reserved shortcut; alternative skipped")
    }

    @Test func mapReservedChordInsideASequenceAlternativeIsRejected() {
        let (keymap, diagnostics) = parseKeymap("map cmd+t|ctrl+a>ctrl+tab toggle_split")
        #expect(keymap.equivalent(for: .toggleSplit) == Chord(mods: [.command], key: "t"))
        #expect(keymap.sequences(for: .toggleSplit).isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("reserved"))
    }

    @Test func mapBareArrowAlternativeIsRejectedWhileTheSiblingSurvives() {
        let (keymap, diagnostics) = parseKeymap("map left|cmd+opt+shift+left previous_session")
        #expect(keymap.equivalent(for: .previousSession) == Chord(mods: [.command, .option, .shift], key: "left"))
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message == "bare arrow chord 'left' needs a modifier; alternative skipped")
    }

    @Test func mapDedupesIdenticalAlternatives() {
        let (keymap, diagnostics) = parseKeymap("map cmd+t|cmd+t toggle_split")
        #expect(diagnostics.isEmpty)
        #expect(keymap.equivalent(for: .toggleSplit) == Chord(mods: [.command], key: "t"))
        #expect(keymap.sequences(for: .toggleSplit).isEmpty)
    }

    @Test func mapMalformedAlternativePoisonsTheWholeLine() {
        let (keymap, diagnostics) = parseKeymap("map cmd+t|cmd+f1 toggle_split")
        #expect(keymap.equivalent(for: .toggleSplit) == BuiltinAction.toggleSplit.defaultChord)
        #expect(keymap.sequences(for: .toggleSplit).isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message == "invalid chord 'cmd+t|cmd+f1'")
    }

    @Test func laterMapLineReplacesTheWholeEarlierBinding() {
        let text = """
        map cmd+t|ctrl+space>s toggle_split
        map ctrl+a>d toggle_split
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.equivalent(for: .toggleSplit) == nil)
        #expect(keymap.sequences(for: .toggleSplit) == [[Chord(mods: [.control], key: "a"), Chord(mods: [], key: "d")]])
    }

    @Test func laterMapLineDropsTheEarlierSequences() {
        let text = """
        map ctrl+a>d toggle_split
        map cmd+t toggle_split
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.equivalent(for: .toggleSplit) == Chord(mods: [.command], key: "t"))
        #expect(keymap.sequences(for: .toggleSplit).isEmpty)
        #expect(keymap.builtinUnbound.isEmpty)
    }

    @Test func mapAlternativesLosingTheirMenuChordToACollisionKeepTheirSequences() {
        // cmd+d is toggle_split's unmoved default, so new_session's menu chord loses — its monitor
        // alternative has nothing to collide with and stays.
        let (keymap, diagnostics) = parseKeymap("map cmd+d|ctrl+a>n new_session")
        #expect(keymap.equivalent(for: .newSession) == Chord(mods: [.command], key: "n"))
        #expect(keymap.sequences(for: .newSession) == [[Chord(mods: [.control], key: "a"), Chord(mods: [], key: "n")]])
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("conflicts with built-in 'toggle_split'"))
    }

    @Test func unboundActionFreesItsDefaultChordForACustomCommand() {
        let text = """
        map ctrl+a>d toggle_split
        command "Split" cmd+d echo split
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut == "cmd+d")
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
        #expect(diagnostics[0].message == "chord 'ctrl+1' is a reserved shortcut; map skipped")
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
        map cmd+f1 new_session
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "e")])
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].name == "Deploy")
        #expect(diagnostics.count == 2)
        #expect(diagnostics[0].line == 2)
        #expect(diagnostics[0].message.contains("unknown verb"))
        #expect(diagnostics[1].line == 4)
        #expect(diagnostics[1].message == "invalid chord 'cmd+f1'")
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

    // MARK: cross-section validation — per alternative, across both verbs

    @Test func commandAlternativeShadowedByABuiltinDropsAloneAndKeepsTheSibling() {
        // cmd+d is toggle_split's shipped default; ctrl+a>g is free.
        let (keymap, diagnostics) = parseKeymap(#"command "Boom" cmd+d|ctrl+a>g echo boom"#)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].shortcut == "ctrl+a>g")
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 0)
        #expect(diagnostics[0].message
            == "custom command 'Boom' shortcut 'cmd+d' conflicts with a built-in; alternative dropped")
    }

    @Test func commandWithEveryAlternativeShadowedEndsUpPaletteOnly() {
        let (keymap, diagnostics) = parseKeymap(#"command "Boom" cmd+d|cmd+n echo boom"#)
        #expect(keymap.commands.count == 1)
        #expect(keymap.commands[0].command == "echo boom")
        #expect(keymap.commands[0].shortcut.isEmpty)
        #expect(diagnostics.count == 2)
        #expect(diagnostics.allSatisfy { $0.message.contains("conflicts with a built-in") })
    }

    @Test func commandAlternativeKeepsItsRawSpellingWhenASiblingDrops() {
        // the survivor is spliced from the raw substrings, never re-rendered from the parsed chord.
        let (keymap, _) = parseKeymap(#"command "Boom" cmd+d|COMMAND+Shift+A echo boom"#)
        #expect(keymap.commands[0].shortcut == "COMMAND+Shift+A")
    }

    @Test func builtinAlternativeShadowedByItsOwnMenuChordIsDropped() {
        // the monitor would arm on the very chord this line puts on the menu, suppressing it.
        let (keymap, diagnostics) = parseKeymap("map cmd+t|cmd+t>s toggle_split")
        #expect(keymap.equivalent(for: .toggleSplit) == Chord(mods: [.command], key: "t"))
        #expect(keymap.sequences(for: .toggleSplit).isEmpty)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].line == 1)
        #expect(diagnostics[0].message
            == "built-in 'toggle_split' chord 'cmd+t>s' conflicts with a built-in; alternative dropped")
    }

    @Test func commandAlternativeConflictingWithABuiltinAlternativeLosesOnlyThatKey() {
        let text = """
        map cmd+t|ctrl+a>s toggle_split
        command "Boom" ctrl+a>s|ctrl+b>s echo boom
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.equivalent(for: .toggleSplit) == Chord(mods: [.command], key: "t"))
        #expect(keymap.sequences(for: .toggleSplit).isEmpty)
        #expect(keymap.commands[0].shortcut == "ctrl+b>s")
        #expect(diagnostics.count == 2)
        #expect(diagnostics.contains {
            $0.message == "custom command 'Boom' shortcut 'ctrl+a>s' conflicts with built-in 'toggle_split'; alternative dropped"
        })
        #expect(diagnostics.contains {
            $0.message == "built-in 'toggle_split' chord 'ctrl+a>s' conflicts with custom command 'Boom'; alternative dropped"
        })
    }

    @Test func builtinVersusBuiltinAlternativesDropBothAndKeepTheirMenuChords() {
        let text = """
        map cmd+t|ctrl+a>s toggle_split
        map cmd+y|ctrl+a>s new_session
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.equivalent(for: .toggleSplit) == Chord(mods: [.command], key: "t"))
        #expect(keymap.equivalent(for: .newSession) == Chord(mods: [.command], key: "y"))
        #expect(keymap.sequences(for: .toggleSplit).isEmpty)
        #expect(keymap.sequences(for: .newSession).isEmpty)
        #expect(diagnostics.count == 2)
        #expect(diagnostics.contains { $0.line == 1 && $0.message.contains("conflicts with built-in 'new_session'") })
        #expect(diagnostics.contains { $0.line == 2 && $0.message.contains("conflicts with built-in 'toggle_split'") })
    }

    @Test func prefixConflictBetweenAlternativesDropsBothSidesAndKeepsSiblings() {
        let text = """
        command "Lead" ctrl+space|cmd+y echo lead
        command "Seq" ctrl+space>s|cmd+u echo seq
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(keymap.commands[0].shortcut == "cmd+y")
        #expect(keymap.commands[1].shortcut == "cmd+u")
        #expect(diagnostics.count == 2)
        #expect(diagnostics.contains { $0.message.contains("shortcut 'ctrl+space'") && $0.message.contains("'Seq'") })
        #expect(diagnostics.contains { $0.message.contains("shortcut 'ctrl+space>s'") && $0.message.contains("'Lead'") })
    }

    // a binding's own prefix pair is settled by its alternative SET, not by writing order: the matcher fires
    // the shorter bind, so every longer sibling is dead whichever side of the `|` it was written on.
    @Test func everyAlternativeShadowedByItsOwnShorterSiblingIsDropped() {
        let (keymap, diagnostics) = parseKeymap(#"command "X" ctrl+a>b|ctrl+a|ctrl+a>c echo hi"#)
        #expect(keymap.commands[0].shortcut == "ctrl+a")
        #expect(diagnostics.map(\.message) == [
            "custom command 'X' shortcut 'ctrl+a>b' conflicts with custom command 'X'; alternative dropped",
            "custom command 'X' shortcut 'ctrl+a>c' conflicts with custom command 'X'; alternative dropped",
        ])
    }

    // reordering ONE binding's alternatives must not decide whether an unrelated binding lives: its own
    // prefix pair settles first, so the cross-target pass sees the same set either way.
    @Test func alternativeOrderInsideOneBindingDoesNotDecideAnotherBindingsFate() {
        let longFirst = parseKeymap("""
        command "A" ctrl+a>b|ctrl+a echo a
        command "B" ctrl+a>c echo b
        """)
        let shortFirst = parseKeymap("""
        command "A" ctrl+a|ctrl+a>b echo a
        command "B" ctrl+a>c echo b
        """)
        #expect(longFirst.keymap.commands.map(\.shortcut) == ["", ""])
        #expect(shortFirst.keymap.commands.map(\.shortcut) == longFirst.keymap.commands.map(\.shortcut))
        #expect(Set(shortFirst.diagnostics.map(\.message)) == Set(longFirst.diagnostics.map(\.message)))
    }

    // the same, one step out: which of two compatible siblings a third binding collides with must not depend
    // on which of them was written first.
    @Test func siblingOrderDoesNotDecideWhichThirdBindingSurvives() {
        func parse(_ alternatives: String) -> [String] {
            parseKeymap("""
            command "A" \(alternatives) echo a
            command "B" ctrl+x echo b
            command "C" ctrl+x>2 echo c
            """).keymap.commands.map(\.shortcut)
        }
        #expect(parse("ctrl+x>1|ctrl+x>2") == parse("ctrl+x>2|ctrl+x>1"))
    }

    // the conflict relation is computed once and every side of it goes, so a bind conflicting with two others
    // takes both down. Under the earlier drop-then-skip rule this same text kept whichever of A and C the file
    // happened to list last.
    @Test func aBindConflictingWithTwoOthersDropsBothOfThemInEitherLineOrder() {
        let forward = parseKeymap("""
        command "A" ctrl+a>b echo a
        command "B" ctrl+a echo b
        command "C" ctrl+a>c echo c
        """)
        let reversed = parseKeymap("""
        command "C" ctrl+a>c echo c
        command "B" ctrl+a echo b
        command "A" ctrl+a>b echo a
        """)
        #expect(forward.keymap.commands.map(\.shortcut) == ["", "", ""])
        #expect(reversed.keymap.commands.map(\.shortcut) == ["", "", ""])
        #expect(forward.diagnostics.count == 3)
        #expect(reversed.diagnostics.count == 3)
    }

    // an alternative whose only conflict is with one that also drops dies with it. That is the accepted price
    // of settling everything in one pass, and it must cost the same whichever side of the `|` it was written on.
    @Test func anAlternativeChargedForAConflictWithADroppedOneGoesInEitherAlternativeOrder() {
        func shortcuts(_ alternatives: String) -> [String] {
            parseKeymap("""
            command "A" \(alternatives) echo a
            command "B" ctrl+a echo b
            """).keymap.commands.map(\.shortcut)
        }
        #expect(shortcuts("ctrl+a|ctrl+a>b") == ["", ""])
        #expect(shortcuts("ctrl+a>b|ctrl+a") == ["", ""])
    }

    // the whole file, not one binding: the same lines in any order must bind the same keys.
    @Test func lineOrderDoesNotDecideWhichBindingsSurvive() {
        let lines = [
            "map cmd+t|ctrl+a>t toggle_split",
            #"command "Boom" ctrl+a>t|ctrl+b>t echo boom"#,
            #"command "Lead" ctrl+c echo lead"#,
            #"command "Seq" ctrl+c>s echo seq"#,
            "map cmd+y|ctrl+d>n new_session",
        ]
        let forward = bindingSummary(parseKeymap(lines.joined(separator: "\n")).keymap)

        #expect(forward.contains("toggle_split=cmd+t"))
        #expect(forward.contains("new_session=cmd+y|ctrl+d>n"))
        #expect(forward.contains("Boom=ctrl+b>t"))
        #expect(forward.contains("Lead="))
        #expect(forward.contains("Seq="))
        #expect(bindingSummary(parseKeymap(lines.reversed().joined(separator: "\n")).keymap) == forward)
        #expect(bindingSummary(parseKeymap(([lines[2], lines[4], lines[0], lines[3], lines[1]])
            .joined(separator: "\n")).keymap) == forward)
    }

    /// Every binding the keymap ended up with, in an order derived from the model rather than from the file, so
    /// two spellings of the same set compare equal.
    private func bindingSummary(_ keymap: Keymap) -> [String] {
        let builtins = BuiltinAction.allCases.compactMap { action -> String? in
            let binds = (keymap.equivalent(for: action).map { [$0.displayString] } ?? [])
                + keymap.sequences(for: action).map(\.displayString)
            return binds.isEmpty ? nil : "\(action.rawValue)=\(binds.joined(separator: "|"))"
        }
        return builtins + keymap.commands.map { "\($0.name)=\($0.shortcut)" }.sorted()
    }

    @Test func singleAlternativeConflictDiagnosticsKeepTodaysWording() {
        let builtin = parseKeymap(#"command "Boom" cmd+d echo boom"#).diagnostics
        #expect(builtin.map(\.message)
            == ["custom command 'Boom' shortcut 'cmd+d' conflicts with a built-in; keybind dropped"])

        let reserved = parseKeymap(#"command "Boom" ctrl+1 echo boom"#).diagnostics
        #expect(reserved.map(\.message)
            == ["custom command 'Boom' shortcut 'ctrl+1' conflicts with a reserved shortcut; keybind dropped"])

        let text = """
        command "First" cmd+shift+e echo one
        command "Second" cmd+shift+e echo two
        """
        #expect(parseKeymap(text).diagnostics.map(\.message) == [
            "custom command 'First' shortcut 'cmd+shift+e' conflicts with custom command 'Second'; keybind dropped",
            "custom command 'Second' shortcut 'cmd+shift+e' conflicts with custom command 'First'; keybind dropped",
        ])
    }

    @Test func unboundActionFreesItsDefaultChordForAnotherBuiltin() {
        // toggle_split keeps no menu chord at all, so the cmd+d it no longer uses stops blocking new_session.
        let text = """
        map ctrl+a>d toggle_split
        map cmd+d new_session
        """
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        #expect(keymap.builtinOverrides[.newSession] == Chord(mods: [.command], key: "d"))
        #expect(keymap.equivalent(for: .toggleSplit) == nil)
        #expect(keymap.sequences(for: .toggleSplit) == [[Chord(mods: [.control], key: "a"), Chord(mods: [], key: "d")]])
    }

    // the compatibility invariant: values below are the pre-alternatives parser's output, captured from it.
    @Test func pipeFreeKeymapParsesExactlyAsItDidBeforeAlternatives() {
        let (keymap, diagnostics) = parseKeymap(pipeFreeKeymapFixture)

        #expect(keymap.builtinOverrides == [.toggleSplit: Chord(mods: [.command, .shift], key: "e"),
                                            .toggleSidebar: Chord(mods: [], key: "t"),
                                            .focusLeftPane: Chord(mods: [.control, .command], key: "left")])
        #expect(keymap.builtinSequences.isEmpty)
        #expect(keymap.builtinUnbound.isEmpty)

        #expect(keymap.commands.map(\.name) == ["Deploy", "Open Notes", "Clash", "First", "Second"])
        #expect(keymap.commands.map(\.shortcut) == ["cmd+shift+y", "", "", "", ""])
        #expect(keymap.commands.map(\.command) == ["./deploy.sh", "vim {AGT_SESSION_PWD}/notes.md",
                                                   "echo clash", "echo one", "echo two"])

        #expect(diagnostics == [
            KeymapDiagnostic(line: 5, message: "chord conflicts with built-in 'close_session'; map skipped"),
            KeymapDiagnostic(line: 0,
                             message: "custom command 'Clash' shortcut 'command+shift+e' conflicts with a built-in; keybind dropped"),
            KeymapDiagnostic(line: 0,
                             message: "custom command 'First' shortcut 'control+shift+g' conflicts with custom command 'Second'; keybind dropped"),
            KeymapDiagnostic(line: 0,
                             message: "custom command 'Second' shortcut 'ctrl+shift+g' conflicts with custom command 'First'; keybind dropped"),
        ])
    }

    @Test func emptyKeymapLeavesEveryBuiltinOnItsShippedDefault() {
        let (keymap, diagnostics) = parseKeymap("")
        #expect(diagnostics.isEmpty)
        for action in BuiltinAction.allCases {
            #expect(keymap.equivalent(for: action) == action.defaultChord)
            #expect(keymap.sequences(for: action).isEmpty)
        }
    }

    @Test func splitAndDashboardShipTheirNewDistinctDefaults() {
        let keymap = parseKeymap("").keymap
        #expect(keymap.equivalent(for: .toggleSplit) == Chord(mods: [.command], key: "d"))
        #expect(keymap.equivalent(for: .toggleHorizontalSplit) == Chord(mods: [.command, .shift], key: "d"))
        #expect(keymap.equivalent(for: .dashboard) == Chord(mods: [.command, .shift], key: "g"))
    }

    @Test func legacyExplicitDashboardBindingKeepsCmdShiftD() {
        let (keymap, diagnostics) = parseKeymap("map cmd+shift+d dashboard")
        #expect(diagnostics.isEmpty)
        #expect(keymap.equivalent(for: .dashboard) == Chord(mods: [.command, .shift], key: "d"))
        #expect(keymap.equivalent(for: .toggleHorizontalSplit) == nil)
        #expect(keymap.builtinUnbound.contains(.toggleHorizontalSplit))
    }

    @Test func existingCmdShiftDCustomCommandIsNotBrokenByHorizontalSplitDefault() {
        let (keymap, diagnostics) = parseKeymap("""
        map ctrl+shift+y dashboard
        command "Old binding" cmd+shift+d echo ok
        """)
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.first?.shortcut == "cmd+shift+d")
        #expect(keymap.equivalent(for: .toggleHorizontalSplit) == nil)
        #expect(keymap.builtinUnbound.contains(.toggleHorizontalSplit))
    }

    @Test func existingCmdShiftGBuiltinBindingIsNotBrokenByDashboardDefault() {
        let (keymap, diagnostics) = parseKeymap("map cmd+shift+g toggle_workspace_filter")
        #expect(diagnostics.isEmpty)
        #expect(keymap.equivalent(for: .toggleWorkspaceFilter) == Chord(mods: [.command, .shift], key: "g"))
        #expect(keymap.equivalent(for: .dashboard) == nil)
        #expect(keymap.builtinUnbound.contains(.dashboard))
    }

    @Test func existingCmdShiftGCustomCommandIsNotBrokenByDashboardDefault() {
        let (keymap, diagnostics) = parseKeymap("command \"Old binding\" cmd+shift+g echo ok")
        #expect(diagnostics.isEmpty)
        #expect(keymap.commands.first?.shortcut == "cmd+shift+g")
        #expect(keymap.equivalent(for: .dashboard) == nil)
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
