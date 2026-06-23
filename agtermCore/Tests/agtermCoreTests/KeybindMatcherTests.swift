import Foundation
import Testing
@testable import agtermCore

struct KeybindMatcherTests {
    private let ctrlA = Chord(mods: .control, key: "a")
    private let b = Chord(mods: [], key: "b")
    private let c = Chord(mods: [], key: "c")
    private let cmdShiftU = Chord(mods: [.command, .shift], key: "u")

    @Test func simpleChordFires() {
        let id = UUID()
        var matcher = KeybindMatcher([([cmdShiftU], id)])
        #expect(matcher.advance(cmdShiftU) == .fired(id))
        #expect(!matcher.isArmed)
    }

    @Test func unmatchedSingleChord() {
        let id = UUID()
        var matcher = KeybindMatcher([([cmdShiftU], id)])
        #expect(matcher.advance(ctrlA) == .unmatched)
        #expect(!matcher.isArmed)
    }

    @Test func sequenceFiresOnSecondChord() {
        let id = UUID()
        var matcher = KeybindMatcher([([ctrlA, b], id)])
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.isArmed)
        #expect(matcher.advance(b) == .fired(id))
        #expect(!matcher.isArmed)
    }

    @Test func wrongSecondChordResetsAndUnmatches() {
        let id = UUID()
        var matcher = KeybindMatcher([([ctrlA, b], id)])
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(c) == .unmatched)
        #expect(!matcher.isArmed)
        // after reset the leader can be re-armed.
        #expect(matcher.advance(ctrlA) == .armed)
    }

    @Test func resetClearsPending() {
        let id = UUID()
        var matcher = KeybindMatcher([([ctrlA, b], id)])
        #expect(matcher.advance(ctrlA) == .armed)
        matcher.reset()
        #expect(!matcher.isArmed)
        // the follow-key alone now no longer completes the sequence.
        #expect(matcher.advance(b) == .unmatched)
    }

    @Test func twoSequencesSharingLeader() {
        let idB = UUID()
        let idC = UUID()
        var matcher = KeybindMatcher([([ctrlA, b], idB), ([ctrlA, c], idC)])
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(b) == .fired(idB))

        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(c) == .fired(idC))
    }

    @Test func simpleAndSequenceCoexist() {
        let simpleID = UUID()
        let seqID = UUID()
        var matcher = KeybindMatcher([([cmdShiftU], simpleID), ([ctrlA, b], seqID)])
        #expect(matcher.advance(cmdShiftU) == .fired(simpleID))
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(b) == .fired(seqID))
    }

    @Test func rePressingLeaderWhileArmedReArms() {
        // armed on ctrl+a, a second ctrl+a is not a valid continuation but IS a fresh leader: it
        // restarts the sequence rather than abandoning it, so the next 'b' still completes.
        let id = UUID()
        var matcher = KeybindMatcher([([ctrlA, b], id)])
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.isArmed)
        #expect(matcher.advance(b) == .fired(id))
    }

    @Test func wrongChordWhileArmedThatIsItselfASimpleBindFires() {
        // armed on ctrl+a, a chord that completes no sequence but is itself a simple bind fires it
        // (the press is not dropped just because a leader was pending).
        let seqID = UUID()
        let simpleID = UUID()
        var matcher = KeybindMatcher([([ctrlA, b], seqID), ([cmdShiftU], simpleID)])
        #expect(matcher.advance(ctrlA) == .armed)
        #expect(matcher.advance(cmdShiftU) == .fired(simpleID))
        #expect(!matcher.isArmed)
    }

    @Test func emptyMatcherUnmatches() {
        var matcher = KeybindMatcher([])
        #expect(matcher.advance(ctrlA) == .unmatched)
        #expect(!matcher.isArmed)
    }
}
