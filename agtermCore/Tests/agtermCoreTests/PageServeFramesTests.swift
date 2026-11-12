import Foundation
import Testing
@testable import agtermCore

struct PageServeFramesTests {
    static let frames: [PageServeFrame] = [
        .resource(id: 1, path: "/Users/u/docs/img/a b.png"),
        .head(id: 1, mimeType: "image/png"),
        .chunk(id: 1, data: Data([0, 1, 2, 255, 10, 13])),
        .end(id: 1),
        .failure(id: 2, error: "file is outside the page's folder"),
        .cancel(id: 3),
        .bridge(id: 4, request: #"{"cmd":"session.overlay.submit","args":{"value":"done\nwith newline"}}"#),
        .bridge(id: 5, request: #"{"cmd":"session.future.thing","args":{"newArgument":[1,{"x":true}]}}"#),
        .reply(id: 5, response: #"{"ok":true,"result":{"id":"s1","futureField":{"nested":1}}}"#),
        .logTail(id: 6, stamp: nil),
        .logTail(id: 7, stamp: stamp),
        .logHead(id: 7, stamp: stamp, offset: 1_048_577),
        .logUnchanged(id: 8),
    ]

    static let stamp = BoundedFile.FileStamp(device: 16_777_231, inode: UInt64.max - 1, size: 3_145_728,
                                             modifiedSeconds: 1_789_000_000, modifiedNanoseconds: 999_999_999)

    @Test func aLogTailWithoutAStampSendsNoStampKey() throws {
        let line = String(decoding: try PageServeCodec.encode(.logTail(id: 1, stamp: nil)), as: UTF8.self)

        #expect(!line.contains("stamp"))
        #expect(line.contains(#""kind":"log.tail""#))
    }

    @Test func anUnknownLogKindIsRefused() {
        let line = Data(#"{"id":1,"kind":"log.rewind"}"#.utf8)

        #expect(throws: PresentationCodec.FrameError.self) { try PageServeCodec.decode(line) }
    }

    @Test(arguments: frames)
    func everyFrameSurvivesARoundTrip(_ frame: PageServeFrame) throws {
        let line = try PageServeCodec.encode(frame)

        #expect(line.last == UInt8(ascii: "\n"))
        #expect(!line.dropLast().contains(UInt8(ascii: "\n")))
        #expect(try PageServeCodec.decode(line.dropLast()) == frame)
    }

    @Test func aFullChunkFitsOneLineAndALargerOneIsRefusedBothWays() throws {
        let full = PageServeFrame.chunk(id: .max, data: Data(repeating: 0xFF, count: PageServeCodec.maxChunkBytes))
        let line = try PageServeCodec.encode(full)
        #expect(line.count < PageServeCodec.maxFrameBytes)
        #expect(try PageServeCodec.decode(line.dropLast()) == full)

        let over = Data(repeating: 0xFF, count: PageServeCodec.maxChunkBytes + 1)
        #expect(throws: PresentationCodec.FrameError.oversize(over.count)) { try PageServeCodec.encode(.chunk(id: 1, data: over)) }
        let wire = Data(#"{"data":"\#(over.base64EncodedString())","id":1,"kind":"chunk"}"#.utf8)
        #expect(throws: PresentationCodec.FrameError.oversize(over.count)) { try PageServeCodec.decode(wire) }
    }

    @Test func aBridgeRequestTooLargeForALineIsRefused() {
        let value = String(repeating: "x", count: PageServeCodec.maxFrameBytes)
        let frame = PageServeFrame.bridge(id: 1, request: #"{"cmd":"session.overlay.submit","args":{"value":"\#(value)"}}"#)
        #expect(throws: PresentationCodec.FrameError.self) { try PageServeCodec.encode(frame) }
    }

    @Test(arguments: ["not json", #"{"id":1}"#, #"{"kind":"resource","id":1}"#, #"{"kind":"future","id":1}"#])
    func aMalformedLineIsRefused(_ line: String) {
        #expect(throws: PresentationCodec.FrameError.self) { try PageServeCodec.decode(Data(line.utf8)) }
    }

    @Test func anOversizeLineIsRefusedBeforeDecoding() {
        let line = Data(repeating: UInt8(ascii: " "), count: PageServeCodec.maxFrameBytes + 1)
        #expect(throws: PresentationCodec.FrameError.oversize(line.count)) { try PageServeCodec.decode(line) }
    }
}
