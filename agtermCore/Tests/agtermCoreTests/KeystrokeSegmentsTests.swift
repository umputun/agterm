import Testing
@testable import agtermCore

struct KeystrokeSegmentsTests {
    @Test func emptyTextProducesNoKeystrokes() {
        #expect(KeystrokeSegments.split("") == [])
    }

    @Test func textWithoutLineEndingsStaysOneTextRun() {
        #expect(KeystrokeSegments.split("echo hi") == [.text("echo hi")])
    }

    @Test func lineFeedsBecomeReturnKeystrokes() {
        #expect(KeystrokeSegments.split("one\ntwo\n") == [
            .text("one"),
            .returnKey,
            .text("two"),
            .returnKey,
        ])
    }

    @Test func carriageReturnsBecomeReturnKeystrokes() {
        #expect(KeystrokeSegments.split("one\rtwo") == [
            .text("one"),
            .returnKey,
            .text("two"),
        ])
    }

    @Test func crlfBecomesOneReturnKeystroke() {
        #expect(KeystrokeSegments.split("one\r\ntwo") == [
            .text("one"),
            .returnKey,
            .text("two"),
        ])
    }

    @Test func blankLinesStillSendReturns() {
        #expect(KeystrokeSegments.split("\n\nmiddle\n\n") == [
            .returnKey,
            .returnKey,
            .text("middle"),
            .returnKey,
            .returnKey,
        ])
    }
}
