import Foundation
import Testing
@testable import agtermCore

struct CommandFailureTests {
    @Test func detailTakesTheLastNonblankLine() {
        let tail = Array("first failure\nsecond failure\n\n   \n".utf8)
        #expect(CommandFailure.detail(fromTail: tail) == "second failure")
    }

    @Test func detailReadsALastLineWithNoNewline() {
        #expect(CommandFailure.detail(fromTail: Array("only line".utf8)) == "only line")
    }

    @Test func detailIsNilWithoutUsableOutput() {
        #expect(CommandFailure.detail(fromTail: []) == nil)
        #expect(CommandFailure.detail(fromTail: Array("\n  \n".utf8)) == nil)
    }

    @Test func detailStripsEscapeSequencesThatWouldPaintOutsideThePanel() {
        let tail = Array("\u{1b}[31mred error\u{1b}[0m".utf8)
        #expect(CommandFailure.detail(fromTail: tail) == "red error")
    }

    @Test func detailSkipsALastLineThatIsNothingButAColourReset() {
        let tail = Array("real error\n\u{1b}[0m\n".utf8)
        #expect(CommandFailure.detail(fromTail: tail) == "real error")
    }

    @Test func detailSkipsALastLineThatIsNothingButControlCharacters() {
        let tail = Array("real error\n\u{07}\n".utf8)
        #expect(CommandFailure.detail(fromTail: tail) == "real error")
    }

    @Test func detailDropsAnOscSequenceWholeRatherThanShowingItsPayload() {
        let tail = Array("\u{1b}]0;a title\u{07}plain error".utf8)
        #expect(CommandFailure.detail(fromTail: tail) == "plain error")
    }

    @Test func detailDecodesATailCutMidScalar() {
        var bytes = Array("ошибка".utf8)
        bytes.removeFirst()
        let detail = CommandFailure.detail(fromTail: bytes)
        #expect(detail != nil)
        #expect(detail?.contains("шибка") == true)
    }

    @Test func detailIsCappedToWhatAHudAccepts() throws {
        let detail = try #require(CommandFailure.detail(fromTail: Array(String(repeating: "e", count: 400).utf8)))
        #expect(HudLayout.textLength(detail) <= HudSpec.maxTextLength)
    }

    @Test func detailCapsAMultiScalarGraphemeByScalarsNotCharacters() throws {
        // a ZWJ family stays four scalars after NFC, so 100 of them are 400 units of a 256 cap.
        let tail = Array(String(repeating: "👨‍👩‍👧", count: 100).utf8)
        let detail = try #require(CommandFailure.detail(fromTail: tail))
        #expect(!detail.isEmpty)
        #expect(HudLayout.textLength(detail) <= HudSpec.maxTextLength)
        #expect(detail.unicodeScalars.count < String(repeating: "👨‍👩‍👧", count: 100).unicodeScalars.count)
    }

    @Test func messageNamesTheCommandAndTheReason() {
        #expect(CommandFailure.message(name: "Agent Reset", reason: "exit 69") == "Agent Reset: exit 69")
    }

    @Test func messageStripsControlCharactersFromTheName() {
        #expect(CommandFailure.message(name: "Agent\u{07}Reset", reason: "exit 1") == "AgentReset: exit 1")
    }

    @Test func messageTruncatesTheNameAndKeepsTheReason() {
        let message = CommandFailure.message(name: String(repeating: "n", count: 400), reason: "exit 1")
        #expect(HudLayout.textLength(message) <= HudSpec.maxTextLength)
        #expect(message.hasSuffix(": exit 1"), "the reason is the half that says what happened")
        #expect(message.hasPrefix("nnn"))
    }

    @Test func messageKeepsTheReasonAloneWhenItFillsTheCapByItself() {
        let reason = String(repeating: "r", count: 400)
        let message = CommandFailure.message(name: "probe", reason: reason)
        #expect(HudLayout.textLength(message) <= HudSpec.maxTextLength)
        #expect(message.hasPrefix("rrr"))
    }
}
