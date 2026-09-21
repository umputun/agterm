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

    @Test(arguments: [
        ("echo hi", Array("echo hi".utf8)),
        ("\n", [UInt8(0x0D)]),
        ("one\r\ntwo\rthree\n", Array("one\rtwo\rthree\r".utf8)),
        ("caf\u{E9}", Array("caf\u{E9}".utf8)),
        ("", []),
    ])
    func ptyBytesSendOneCarriageReturnPerLineEnding(text: String, bytes: [UInt8]) {
        #expect(KeystrokeSegments.ptyBytes(text) == bytes)
    }
}
