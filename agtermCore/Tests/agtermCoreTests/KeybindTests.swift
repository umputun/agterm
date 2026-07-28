import Foundation
import Testing
@testable import agtermCore

struct KeybindTests {
    // the character counterpart of namedKey(forKeyCode:) must cover the SAME vocabulary, or a menu key
    // equivalent renders with its key missing and stops comparing against the chord the keymap resolved.
    @Test func namedKeyForKeyEquivalentCoversEveryBindableNamedKey() {
        let characters: [String: String] = [
            "\u{F700}": "up", "\u{F701}": "down", "\u{F702}": "left", "\u{F703}": "right",
            "\r": "return", "\t": "tab", " ": "space", "\u{7F}": "delete",
        ]
        for (character, expected) in characters {
            #expect(namedKey(forKeyEquivalent: character) == expected)
        }
        #expect(Set(characters.values) == bindableNamedKeys,
                "the character map and the file grammar must name the same keys")
    }

    @Test func namedKeyForKeyEquivalentIgnoresOrdinaryAndEmptyKeys() {
        #expect(namedKey(forKeyEquivalent: "w") == nil)
        #expect(namedKey(forKeyEquivalent: "") == nil)
        #expect(namedKey(forKeyEquivalent: "ab") == nil, "only a single scalar can be a named key")
    }

    @Test func parseSimpleChord() {
        let kb = parseKeybind("cmd+shift+e")
        #expect(kb == [Chord(mods: [.command, .shift], key: "e")])
    }

    @Test func parseBareKeyHasNoModifiers() {
        let kb = parseKeybind("a")
        #expect(kb == [Chord(mods: [], key: "a")])
    }

    @Test func parseFullSequence() {
        let kb = parseKeybind("ctrl+a>b")
        #expect(kb == [Chord(mods: .control, key: "a"), Chord(mods: [], key: "b")])
    }

    @Test func parseSequenceWithModifierOnEachChord() {
        let kb = parseKeybind("ctrl+a>cmd+b")
        #expect(kb == [Chord(mods: .control, key: "a"), Chord(mods: .command, key: "b")])
    }

    @Test func parseEveryModifierWordVariant() {
        #expect(parseKeybind("control+x") == [Chord(mods: .control, key: "x")])
        #expect(parseKeybind("ctrl+x") == [Chord(mods: .control, key: "x")])
        #expect(parseKeybind("command+x") == [Chord(mods: .command, key: "x")])
        #expect(parseKeybind("cmd+x") == [Chord(mods: .command, key: "x")])
        #expect(parseKeybind("option+x") == [Chord(mods: .option, key: "x")])
        #expect(parseKeybind("opt+x") == [Chord(mods: .option, key: "x")])
        #expect(parseKeybind("alt+x") == [Chord(mods: .option, key: "x")])
        #expect(parseKeybind("shift+x") == [Chord(mods: .shift, key: "x")])
    }

    @Test func parseAllModifiersTogether() {
        let kb = parseKeybind("ctrl+cmd+opt+shift+k")
        #expect(kb == [Chord(mods: [.control, .command, .option, .shift], key: "k")])
    }

    @Test func parseIsCaseInsensitive() {
        #expect(parseKeybind("CMD+Shift+E") == [Chord(mods: [.command, .shift], key: "e")])
        #expect(parseKeybind("CTRL+A>B") == [Chord(mods: .control, key: "a"), Chord(mods: [], key: "b")])
    }

    @Test func parseTrimsWhitespaceAroundTokens() {
        #expect(parseKeybind("ctrl + a > b") == [Chord(mods: .control, key: "a"), Chord(mods: [], key: "b")])
    }

    @Test func parseNamedKey() {
        #expect(parseKeybind("ctrl+space") == [Chord(mods: .control, key: "space")])
    }

    @Test func parseArrowKeys() {
        // the exact lines from the report that motivated arrow support (#278).
        #expect(parseKeybind("cmd+shift+left") == [Chord(mods: [.command, .shift], key: "left")])
        #expect(parseKeybind("cmd+shift+right") == [Chord(mods: [.command, .shift], key: "right")])
        #expect(parseKeybind("cmd+opt+up") == [Chord(mods: [.command, .option], key: "up")])
        #expect(parseKeybind("ctrl+opt+down") == [Chord(mods: [.control, .option], key: "down")])
    }

    @Test func parseArrowKeysIsCaseInsensitiveAndWorksBareAndInLeaders() {
        #expect(parseKeybind("CMD+SHIFT+LEFT") == [Chord(mods: [.command, .shift], key: "left")])
        // a bare arrow parses; the modifier requirement is a `map`/`command` rule, not a grammar one.
        #expect(parseKeybind("up") == [Chord(mods: [], key: "up")])
        #expect(parseKeybind("ctrl+a>left") == [Chord(mods: .control, key: "a"), Chord(mods: [], key: "left")])
    }

    @Test func parseStillRejectsNamedKeysTheRunnerCannotProduce() {
        // guards against over-widening the named-key set: only the documented names are bindable, and
        // `esc` stays reserved as the leader abort.
        #expect(parseKeybind("cmd+esc") == nil)
        #expect(parseKeybind("cmd+f1") == nil)
        #expect(parseKeybind("cmd+home") == nil)
        #expect(parseKeybind("cmd+end") == nil)
        #expect(parseKeybind("cmd+pageup") == nil)
        #expect(parseKeybind("cmd+arrowleft") == nil)
    }

    @Test func namedKeyForKeyCodeCoversExactlyTheBindableNamedKeys() {
        // the keyCode→name map is what the app-side monitors use; a name the grammar accepts but the map
        // can't produce would parse in the file and never fire (the shifted-symbol failure mode).
        let produced = Set((0...127).compactMap { namedKey(forKeyCode: UInt16($0)) })
        #expect(produced == bindableNamedKeys)
        #expect(namedKey(forKeyCode: 123) == "left")
        #expect(namedKey(forKeyCode: 124) == "right")
        #expect(namedKey(forKeyCode: 125) == "down")
        #expect(namedKey(forKeyCode: 126) == "up")
        // a key that carries a normal character resolves from the event, not here.
        #expect(namedKey(forKeyCode: 0) == nil)
    }

    @Test func latinKeyCoversEveryAnsiLetterAndDigit() {
        let produced = (0...127).compactMap { latinKey(forKeyCode: UInt16($0)) }
        #expect(produced.count == Set(produced).count, "a physical position must map to one Latin key")
        let letters = Set("abcdefghijklmnopqrstuvwxyz".map(String.init))
        let digits = Set("0123456789".map(String.init))
        #expect(letters.isSubset(of: Set(produced)))
        #expect(digits.isSubset(of: Set(produced)))
        #expect(Set(produced).subtracting(letters).subtracting(digits) == ["=", "-", "]", "[", "'", ";", "\\", ",", "/", ".", "`"])
    }

    @Test func latinKeyValuesAreAllSpellableAsChords() {
        // a fallback the grammar can't spell would fire nothing, the same failure mode the named keys have.
        for key in (0...127).compactMap({ latinKey(forKeyCode: UInt16($0)) }) {
            #expect(parseKeybind("cmd+\(key)") == [Chord(mods: .command, key: key)], "cmd+\(key) must parse")
        }
    }

    @Test func latinKeyAndNamedKeyNeverClaimTheSameKeyCode() {
        // the monitors resolve named keys FIRST, so an overlap would silently shadow one of the two maps.
        for code in 0...127 where namedKey(forKeyCode: UInt16(code)) != nil {
            #expect(latinKey(forKeyCode: UInt16(code)) == nil, "keyCode \(code) is claimed twice")
        }
    }

    // every entry of the table, pinned one by one. The aggregate tests above hold under any permutation of
    // the 47 entries, and the real kVK_ANSI_* constants are non-monotonic at 4/5 (h/g), 22/23 (6/5) and
    // 25/26/28/29 (9/7/8/0) — where a transposition is both easiest to make and hardest to eyeball. A swap
    // would bind a chord to the wrong physical key on every non-Latin layout.
    @Test func latinKeyMapsEachKeyCodeToItsOwnAnsiCharacter() {
        let table: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
            24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
            31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        ]
        for (code, expected) in table {
            #expect(latinKey(forKeyCode: code) == expected, "keyCode \(code) must be '\(expected)'")
        }
        let mapped = Set((0...127).compactMap { latinKey(forKeyCode: UInt16($0)) != nil ? UInt16($0) : nil })
        #expect(mapped == Set(table.keys), "the table and the function must claim the same key codes")
    }

    @Test func chordKeyKeepsTheProducedCharacterOnAnASCIICapableLayout() {
        #expect(chordKey(forKeyCode: 31, produced: "o", layoutIsASCIICapable: true) == "o")
        #expect(chordKey(forKeyCode: 8, produced: "j", layoutIsASCIICapable: true) == "j",
                "Dvorak keeps its own letter positions")
        #expect(chordKey(forKeyCode: 44, produced: "/", layoutIsASCIICapable: true) == "/")
        #expect(chordKey(forKeyCode: 0, produced: "A", layoutIsASCIICapable: true) == "a",
                "the base key is always lowercased")
        #expect(chordKey(forKeyCode: 19, produced: "é", layoutIsASCIICapable: true) == "é",
                "a Latin layout binds what it types, so French cmd+é still fires")
    }

    @Test func chordKeyResolvesAnyNonASCIILayoutByPhysicalPosition() {
        #expect(chordKey(forKeyCode: 31, produced: "щ", layoutIsASCIICapable: false) == "o")
        #expect(chordKey(forKeyCode: 17, produced: "е", layoutIsASCIICapable: false) == "t")
        #expect(chordKey(forKeyCode: 6, produced: "я", layoutIsASCIICapable: false) == "z")
        // the positions the per-key ASCII test got wrong: Greek types ';' on Q and Hebrew types '/' there,
        // so a letter chord stayed dead on the layouts this exists to serve.
        #expect(chordKey(forKeyCode: 12, produced: ";", layoutIsASCIICapable: false) == "q", "Greek Q")
        #expect(chordKey(forKeyCode: 12, produced: "/", layoutIsASCIICapable: false) == "q", "Hebrew Q")
        #expect(chordKey(forKeyCode: 13, produced: "'", layoutIsASCIICapable: false) == "w", "Hebrew-PC W")
        // and the punctuation the standard Russian layout re-homes: '/' types '.', which used to be kept.
        #expect(chordKey(forKeyCode: 44, produced: ".", layoutIsASCIICapable: false) == "/")
    }

    // two physical keys must never resolve to one chord key: the second would fire a binding aimed at the
    // first AND be swallowed by the monitor. Fixtures are the produced characters measured with
    // UCKeyTranslate against the real layout data.
    @Test func chordKeyNeverCollapsesTwoPositionsOntoOneKeyOnANonASCIILayout() {
        let hebrew: [UInt16: String] = [39: ",", 43: "ת", 44: ".", 47: "ץ"]
        let greek: [UInt16: String] = [12: ";", 41: ""]
        let russianWin: [UInt16: String] = [44: ".", 47: "ю"]
        for layout in [hebrew, greek, russianWin] {
            let keys = layout.map { chordKey(forKeyCode: $0.key, produced: $0.value, layoutIsASCIICapable: false) }
            #expect(keys.allSatisfy { $0 != nil })
            #expect(Set(keys.compactMap { $0 }).count == layout.count, "positions collapsed: \(keys)")
        }
    }

    // the ISO key types a layout-dependent character from a position the table does not claim, so keeping
    // it would alias the table position that types the same thing — one binding fired from two keys.
    @Test func chordKeyDropsTheISOSectionKeyOnANonASCIILayout() {
        #expect(chordKey(forKeyCode: 10, produced: "\\", layoutIsASCIICapable: false) == nil,
                "Ukrainian-PC types a backslash here, which keyCode 42 already owns")
        #expect(chordKey(forKeyCode: 10, produced: ";", layoutIsASCIICapable: false) == nil,
                "Hebrew-PC types a semicolon here, which keyCode 41 already owns")
        #expect(chordKey(forKeyCode: 10, produced: "§", layoutIsASCIICapable: true) == "§",
                "on a Latin layout it binds what it types, exactly as before")
    }

    @Test func chordKeyResolvesAPositionThatProducedNothing() {
        #expect(chordKey(forKeyCode: 31, produced: nil, layoutIsASCIICapable: false) == "o")
        #expect(chordKey(forKeyCode: 41, produced: "", layoutIsASCIICapable: false) == ";",
                "a dead key at a table position resolves to its Latin key, not to nil")
        // the ASCII-capable branch never consults the table, so a table position that produced nothing is
        // nil there. US-International puts a dead acute on keyCode 39, which reports "" while composing.
        #expect(chordKey(forKeyCode: 39, produced: "", layoutIsASCIICapable: true) == nil)
        #expect(chordKey(forKeyCode: 31, produced: nil, layoutIsASCIICapable: true) == nil)
    }

    @Test func chordKeyReturnsNilWithoutAUsableBaseKey() {
        #expect(chordKey(forKeyCode: 63, produced: nil, layoutIsASCIICapable: false) == nil,
                "the fn key carries no Latin key")
        #expect(chordKey(forKeyCode: 63, produced: nil, layoutIsASCIICapable: true) == nil)
        #expect(chordKey(forKeyCode: 49, produced: " ", layoutIsASCIICapable: true) == nil,
                "space is a named key, never a produced base key")
    }

    @Test func bindableArrowKeysIsASubsetOfBindableNamedKeys() {
        #expect(bindableArrowKeys.isSubset(of: bindableNamedKeys))
        #expect(bindableArrowKeys == ["left", "right", "up", "down"])
    }

    @Test func parseRejectsEmptyString() {
        #expect(parseKeybind("") == nil)
    }

    @Test func parseRejectsTrailingPlus() {
        #expect(parseKeybind("ctrl+") == nil)
    }

    @Test func parseRejectsLeadingPlus() {
        #expect(parseKeybind("+a") == nil)
    }

    @Test func parseRejectsTrailingChevron() {
        #expect(parseKeybind("ctrl+a>") == nil)
    }

    @Test func parseRejectsModifierOnly() {
        // no base key after the modifiers.
        #expect(parseKeybind("ctrl+cmd") == nil)
    }

    @Test func parseRejectsMultipleBaseKeys() {
        #expect(parseKeybind("a+b") == nil)
    }

    @Test func parseRejectsTwoBaseKeysFromUnknownModifierWord() {
        // "fn" is not a recognized modifier; with ctrl+a it parses as two base keys (fn and a).
        #expect(parseKeybind("fn+ctrl+a") == nil)
    }

    @Test func parseRejectsUnknownModifierWithRealKey() {
        // a word that is neither a known modifier nor sharing the chord with another base key is
        // itself taken as the base key, so pairing it with a real key is two base keys → nil.
        #expect(parseKeybind("super+x") == nil)
        #expect(parseKeybind("hyper+x") == nil)
    }

    @Test func noConflictsForDistinctShortcuts() {
        let cmds = [CustomCommand(name: "a", command: "", shortcut: "cmd+a"),
                    CustomCommand(name: "b", command: "", shortcut: "cmd+b")]
        #expect(keybindConflicts(cmds).isEmpty)
    }

    @Test func detectsDuplicateShortcut() {
        let a = CustomCommand(name: "a", command: "", shortcut: "cmd+a")
        let b = CustomCommand(name: "b", command: "", shortcut: "CMD+A")
        let conflicts = keybindConflicts([a, b])
        #expect(conflicts == [KeybindConflict(first: a.id, second: b.id)])
    }

    @Test func detectsPrefixOverlap() {
        let leader = CustomCommand(name: "leader", command: "", shortcut: "ctrl+a")
        let seq = CustomCommand(name: "seq", command: "", shortcut: "ctrl+a>b")
        let conflicts = keybindConflicts([leader, seq])
        #expect(conflicts == [KeybindConflict(first: leader.id, second: seq.id)])
    }

    @Test func detectsPrefixOverlapRegardlessOfOrder() {
        // the longer bind listed first still conflicts with the shorter prefix.
        let seq = CustomCommand(name: "seq", command: "", shortcut: "ctrl+a>b")
        let leader = CustomCommand(name: "leader", command: "", shortcut: "ctrl+a")
        let conflicts = keybindConflicts([seq, leader])
        #expect(conflicts == [KeybindConflict(first: seq.id, second: leader.id)])
    }

    @Test func detectsThreeWayOverlap() {
        // ctrl+a, ctrl+a>b, ctrl+a>b>c — every shorter bind is a prefix of every longer one, so all
        // three pairs conflict.
        let leader = CustomCommand(name: "leader", command: "", shortcut: "ctrl+a")
        let two = CustomCommand(name: "two", command: "", shortcut: "ctrl+a>b")
        let three = CustomCommand(name: "three", command: "", shortcut: "ctrl+a>b>c")
        let conflicts = keybindConflicts([leader, two, three])
        #expect(conflicts.count == 3)
        #expect(conflicts.contains(KeybindConflict(first: leader.id, second: two.id)))
        #expect(conflicts.contains(KeybindConflict(first: leader.id, second: three.id)))
        #expect(conflicts.contains(KeybindConflict(first: two.id, second: three.id)))
    }

    @Test func siblingSequencesSharingLeaderDoNotConflict() {
        // ctrl+a>b and ctrl+a>c share a leader but neither is a prefix of the other.
        let b = CustomCommand(name: "b", command: "", shortcut: "ctrl+a>b")
        let c = CustomCommand(name: "c", command: "", shortcut: "ctrl+a>c")
        #expect(keybindConflicts([b, c]).isEmpty)
    }

    @Test func skipsEmptyAndUnparseableShortcuts() {
        let paletteOnly = CustomCommand(name: "p", command: "", shortcut: "")
        let invalid = CustomCommand(name: "i", command: "", shortcut: "ctrl+")
        let valid = CustomCommand(name: "v", command: "", shortcut: "cmd+a")
        #expect(keybindConflicts([paletteOnly, invalid, valid]).isEmpty)
    }

    @Test func isReservedMonitorChordMatchesTheMonitorPredicates() {
        // Ctrl-Tab switcher: Tab while Control is held, with ANY other modifiers (it checks
        // .contains(.control), not exact equality), so all four combinations are reserved.
        #expect(isReservedMonitorChord(Chord(mods: [.control], key: "tab")))
        #expect(isReservedMonitorChord(Chord(mods: [.control, .shift], key: "tab")))
        #expect(isReservedMonitorChord(Chord(mods: [.control, .option], key: "tab")))
        #expect(isReservedMonitorChord(Chord(mods: [.control, .command], key: "tab")))
        // Ctrl-1/2 pane shortcuts: 1/2 only when Control is the SOLE modifier.
        #expect(isReservedMonitorChord(Chord(mods: [.control], key: "1")))
        #expect(isReservedMonitorChord(Chord(mods: [.control], key: "2")))
    }

    @Test func isReservedMonitorChordRejectsNonMonitorChords() {
        // tab without control is fine; 1/2 with an extra modifier is NOT reserved (the monitor needs
        // control alone); 3 is never reserved.
        #expect(!isReservedMonitorChord(Chord(mods: [.command], key: "tab")))
        #expect(!isReservedMonitorChord(Chord(mods: [], key: "tab")))
        #expect(!isReservedMonitorChord(Chord(mods: [.control, .shift], key: "1")))
        #expect(!isReservedMonitorChord(Chord(mods: [.control, .command], key: "2")))
        #expect(!isReservedMonitorChord(Chord(mods: [.control], key: "3")))
        #expect(!isReservedMonitorChord(Chord(mods: [.command, .shift], key: "e")))
    }

    @Test func chordDisplayStringRoundTripsKittySyntax() {
        #expect(Chord(mods: [.command, .shift], key: "e").displayString == "cmd+shift+e")
        #expect(Chord(mods: [], key: "a").displayString == "a")
        #expect(Chord(mods: [.control], key: "tab").displayString == "ctrl+tab")
        // fixed ctrl+cmd+opt+shift modifier order regardless of insertion order.
        #expect(Chord(mods: [.shift, .option, .command, .control], key: "x").displayString == "ctrl+cmd+opt+shift+x")
        // every displayString parses back to the same single chord.
        let chord = Chord(mods: [.command, .option], key: "n")
        #expect(parseKeybind(chord.displayString) == [chord])
    }

    @Test func chordGlyphStringRendersMacOSGlyphs() {
        #expect(Chord(mods: [.command], key: "n").glyphString == "⌘N")
        // macOS order is ⌃⌥⇧⌘, so option/shift render BEFORE command.
        #expect(Chord(mods: [.command, .option], key: "n").glyphString == "⌥⌘N")
        #expect(Chord(mods: [.command, .shift], key: "n").glyphString == "⇧⌘N")
        #expect(Chord(mods: [.control], key: "p").glyphString == "⌃P")
        // fixed macOS ⌃⌥⇧⌘ modifier order regardless of insertion order.
        #expect(Chord(mods: [.shift, .option, .command, .control], key: "x").glyphString == "⌃⌥⇧⌘X")
        // symbols are left as-is; named keys render as their glyphs.
        #expect(Chord(mods: [.command], key: "+").glyphString == "⌘+")
        #expect(Chord(mods: [.control], key: "tab").glyphString == "⌃⇥")
        #expect(Chord(mods: [.command], key: "return").glyphString == "⌘↩")
        #expect(Chord(mods: [.command, .option], key: "left").glyphString == "⌥⌘←")
        #expect(Chord(mods: [.command, .option], key: "right").glyphString == "⌥⌘→")
        #expect(Chord(mods: [.command, .option], key: "up").glyphString == "⌥⌘↑")
        #expect(Chord(mods: [.control, .option], key: "down").glyphString == "⌃⌥↓")
    }

    @Test func arrowChordsRoundTripThroughDisplayString() {
        for key in bindableArrowKeys {
            let chord = Chord(mods: [.command, .shift], key: key)
            #expect(chord.displayString == "cmd+shift+\(key)")
            #expect(parseKeybind(chord.displayString) == [chord])
        }
    }
}
