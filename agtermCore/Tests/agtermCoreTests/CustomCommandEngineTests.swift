import Foundation
import Testing
@testable import agtermCore

struct CustomCommandEngineTests {
    private let ctrlA = Chord(mods: .control, key: "a")
    private let g = Chord(mods: [], key: "g")
    private let x = Chord(mods: [], key: "x")
    private let cmdShiftE = Chord(mods: [.command, .shift], key: "e")

    @Test func firesSimpleCommand() {
        let command = CustomCommand(name: "edit", command: "zed {AGT_SESSION_PWD}", shortcut: "cmd+shift+e")
        var engine = CustomCommandEngine(commands: [command])

        #expect(engine.advance(cmdShiftE) == .fired(command))
        #expect(!engine.isArmed)
    }

    @Test func armsThenFiresLeaderCommand() {
        let command = CustomCommand(name: "git", command: "git status", shortcut: "ctrl+a>g")
        var engine = CustomCommandEngine(commands: [command])

        #expect(engine.advance(ctrlA) == .armed)
        #expect(engine.isArmed)
        #expect(engine.advance(g) == .fired(command))
        #expect(!engine.isArmed)
    }

    @Test func unmatchedChordPassesThrough() {
        let command = CustomCommand(name: "edit", command: "zed", shortcut: "cmd+shift+e")
        var engine = CustomCommandEngine(commands: [command])

        #expect(engine.advance(ctrlA) == .unmatched)
        #expect(!engine.isArmed)
    }

    @Test func resetAbandonsLeaderSequence() {
        let command = CustomCommand(name: "git", command: "git status", shortcut: "ctrl+a>g")
        var engine = CustomCommandEngine(commands: [command])

        #expect(engine.advance(ctrlA) == .armed)
        engine.reset()
        #expect(!engine.isArmed)
        #expect(engine.advance(g) == .unmatched)
    }

    @Test func paletteOnlyCommandNeverMatchesAChord() {
        let command = CustomCommand(name: "palette", command: "touch /tmp/x", shortcut: "")
        var engine = CustomCommandEngine(commands: [command])

        #expect(engine.advance(cmdShiftE) == .unmatched)
        #expect(engine.advance(ctrlA) == .unmatched)
    }

    @Test func invalidShortcutCommandNeverMatchesAChord() {
        let command = CustomCommand(name: "bad", command: "echo bad", shortcut: "ctrl+missing")
        var engine = CustomCommandEngine(commands: [command])

        #expect(engine.advance(ctrlA) == .unmatched)
    }

    @Test func wrongLeaderContinuationCanRestartAsFreshLeader() {
        let command = CustomCommand(name: "git", command: "git status", shortcut: "ctrl+a>g")
        var engine = CustomCommandEngine(commands: [command])

        #expect(engine.advance(ctrlA) == .armed)
        #expect(engine.advance(ctrlA) == .armed)
        #expect(engine.advance(g) == .fired(command))
    }

    @Test func wrongLeaderContinuationCanFireSimpleCommand() {
        let sequence = CustomCommand(name: "git", command: "git status", shortcut: "ctrl+a>g")
        let simple = CustomCommand(name: "edit", command: "zed", shortcut: "cmd+shift+e")
        var engine = CustomCommandEngine(commands: [sequence, simple])

        #expect(engine.advance(ctrlA) == .armed)
        #expect(engine.advance(cmdShiftE) == .fired(simple))
        #expect(!engine.isArmed)
    }

    @Test func emptyEngineUnmatches() {
        var engine = CustomCommandEngine(commands: [])

        #expect(engine.advance(x) == .unmatched)
        #expect(!engine.isArmed)
    }
}
