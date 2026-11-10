import Foundation
import Testing
@testable import agtermCore

struct ImageHeaderTests {
    struct Sample: Sendable, CustomTestStringConvertible {
        let name: String
        let bytes: [UInt8]
        var expected: ImagePixels?

        var testDescription: String { name }
    }

    private enum Fixture {
        static func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        static func be32(_ value: Int) -> [UInt8] { be16(value >> 16) + be16(value & 0xFFFF) }
        static func le16(_ value: Int) -> [UInt8] { be16(value).reversed() }
        static func le24(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF)] }
        static func le32(_ value: Int) -> [UInt8] { be32(value).reversed() }

        static func png(width: Int, height: Int, chunk: String = "IHDR") -> [UInt8] {
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + be32(13) + Array(chunk.utf8)
                + be32(width) + be32(height) + [8, 6, 0, 0, 0] + [0x1F, 0x15, 0xC4, 0x89]
        }

        static func gif(width: Int, height: Int) -> [UInt8] {
            Array("GIF89a".utf8) + le16(width) + le16(height) + [0xF7, 0, 0]
        }

        static func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
            [0xFF, marker] + be16(payload.count + 2) + payload
        }

        static func sof(_ marker: UInt8, width: Int, height: Int) -> [UInt8] {
            segment(marker, [8] + be16(height) + be16(width) + [3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
        }

        static let app0 = segment(0xE0, Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
        static let dqt = segment(0xDB, [0] + [UInt8](repeating: 1, count: 64))
        static let sos = segment(0xDA, [1, 1, 0, 0, 0x3F, 0]) + [0x12, 0x34, 0xFF, 0xD9]

        static func jpeg(_ segments: [UInt8]...) -> [UInt8] {
            [0xFF, 0xD8] + segments.flatMap { $0 } + sos
        }

        static func exif(orientation: Int, little: Bool) -> [UInt8] {
            let u16 = little ? le16 : be16
            let u32 = little ? le32 : be32
            let make = u16(0x010F) + u16(2) + u32(4) + Array("abc\0".utf8)
            let rotation = u16(0x0112) + u16(3) + u32(1) + u16(orientation) + [0, 0]
            let tiff = Array((little ? "II" : "MM").utf8) + u16(42) + u32(8) + u16(2) + make + rotation + u32(0)
            return segment(0xE1, Array("Exif\0\0".utf8) + tiff)
        }

        static func webp(_ fourcc: String, _ payload: [UInt8]) -> [UInt8] {
            Array("RIFF".utf8) + le32(12 + payload.count) + Array("WEBP".utf8) + Array(fourcc.utf8) + le32(payload.count) + payload
        }

        static func vp8(width: Int, height: Int, startCode: [UInt8] = [0x9D, 0x01, 0x2A]) -> [UInt8] {
            webp("VP8 ", [0x50, 0x2A, 0x00] + startCode + le16(width) + le16(height) + [0, 0])
        }

        static func vp8l(width: Int, height: Int, signature: UInt8 = 0x2F) -> [UInt8] {
            webp("VP8L", [signature] + le32((width - 1) | (height - 1) << 14 | 1 << 28) + [0, 0, 0])
        }

        static func vp8x(width: Int, height: Int) -> [UInt8] {
            webp("VP8X", [0x10, 0, 0, 0] + le24(width - 1) + le24(height - 1))
        }
    }

    static let readable = [
        Sample(name: "png", bytes: Fixture.png(width: 1200, height: 800), expected: ImagePixels(width: 1200, height: 800)),
        Sample(name: "gif", bytes: Fixture.gif(width: 320, height: 240), expected: ImagePixels(width: 320, height: 240)),
        Sample(name: "jpeg baseline", bytes: Fixture.jpeg(Fixture.dqt, Fixture.sof(0xC0, width: 640, height: 480)),
               expected: ImagePixels(width: 640, height: 480)),
        Sample(name: "jpeg progressive behind app0", bytes: Fixture.jpeg(Fixture.app0, Fixture.sof(0xC2, width: 1920, height: 1080)),
               expected: ImagePixels(width: 1920, height: 1080)),
        Sample(name: "jpeg with fill bytes and a standalone marker",
               bytes: Fixture.jpeg([0xFF, 0xFF, 0xFF, 0x01], Fixture.app0, [0xFF], Fixture.sof(0xC1, width: 30, height: 20)),
               expected: ImagePixels(width: 30, height: 20)),
        Sample(name: "webp vp8 with scale bits", bytes: Fixture.vp8(width: 0x4000 | 400, height: 0x8000 | 300),
               expected: ImagePixels(width: 400, height: 300)),
        Sample(name: "webp vp8l", bytes: Fixture.vp8l(width: 16_384, height: 1), expected: ImagePixels(width: 16_384, height: 1)),
        Sample(name: "webp vp8x", bytes: Fixture.vp8x(width: 20_000, height: 3), expected: ImagePixels(width: 20_000, height: 3)),
        Sample(name: "jpeg exif 6 little-endian", bytes: Fixture.jpeg(Fixture.exif(orientation: 6, little: true), Fixture.sof(0xC0, width: 4032, height: 3024)),
               expected: ImagePixels(width: 3024, height: 4032)),
        Sample(name: "jpeg exif 6 big-endian", bytes: Fixture.jpeg(Fixture.exif(orientation: 6, little: false), Fixture.sof(0xC0, width: 4032, height: 3024)),
               expected: ImagePixels(width: 3024, height: 4032)),
        Sample(name: "jpeg exif 8 after app0", bytes: Fixture.jpeg(Fixture.app0, Fixture.exif(orientation: 8, little: false), Fixture.sof(0xC2, width: 50, height: 10)),
               expected: ImagePixels(width: 10, height: 50)),
        Sample(name: "jpeg exif 3", bytes: Fixture.jpeg(Fixture.exif(orientation: 3, little: true), Fixture.sof(0xC0, width: 4032, height: 3024)),
               expected: ImagePixels(width: 4032, height: 3024)),
        Sample(name: "jpeg exif out of range", bytes: Fixture.jpeg(Fixture.exif(orientation: 9, little: true), Fixture.sof(0xC0, width: 40, height: 30)),
               expected: ImagePixels(width: 40, height: 30)),
        Sample(name: "jpeg xmp app1", bytes: Fixture.jpeg(Fixture.segment(0xE1, Array("http://ns.adobe.com/xap/1.0/\0".utf8)), Fixture.sof(0xC0, width: 40, height: 30)),
               expected: ImagePixels(width: 40, height: 30)),
    ]

    @Test(arguments: readable)
    func headerReportsThePixelSizeWithOrientationApplied(_ sample: Sample) {
        #expect(ImageHeader.pixels(Data(sample.bytes)) == sample.expected)
    }

    @Test(arguments: [
        Sample(name: "text", bytes: Array("hello, world".utf8)),
        Sample(name: "empty", bytes: []),
        Sample(name: "riff that is not webp", bytes: Array("RIFF\u{4}\0\0\0WAVEfmt ".utf8)),
        Sample(name: "png truncated", bytes: Array(Fixture.png(width: 10, height: 10).prefix(22))),
        Sample(name: "png without ihdr", bytes: Fixture.png(width: 10, height: 10, chunk: "IDAT")),
        Sample(name: "png zero width", bytes: Fixture.png(width: 0, height: 10)),
        Sample(name: "gif truncated", bytes: Array(Fixture.gif(width: 10, height: 10).prefix(9))),
        Sample(name: "gif zero height", bytes: Fixture.gif(width: 10, height: 0)),
        Sample(name: "jpeg truncated in sof", bytes: Array(Fixture.jpeg(Fixture.sof(0xC0, width: 10, height: 10)).prefix(8))),
        Sample(name: "jpeg zero height", bytes: Fixture.jpeg(Fixture.sof(0xC0, width: 10, height: 0))),
        Sample(name: "jpeg segment past the end", bytes: [0xFF, 0xD8, 0xFF, 0xE0, 0x10, 0x00] + Fixture.sof(0xC0, width: 10, height: 10)),
        Sample(name: "jpeg segment length below two", bytes: [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01] + Fixture.sof(0xC0, width: 10, height: 10)),
        Sample(name: "jpeg garbage between segments", bytes: Fixture.jpeg(Fixture.app0, [0x00], Fixture.sof(0xC0, width: 10, height: 10))),
        Sample(name: "jpeg without sof", bytes: Fixture.jpeg(Fixture.app0)),
        Sample(name: "jpeg sof without sos", bytes: [0xFF, 0xD8] + Fixture.sof(0xC0, width: 10, height: 10)),
        Sample(name: "webp vp8 truncated", bytes: Array(Fixture.vp8(width: 10, height: 10).prefix(28))),
        Sample(name: "webp vp8 bad start code", bytes: Fixture.vp8(width: 10, height: 10, startCode: [0x9D, 0x01, 0x2B])),
        Sample(name: "webp vp8 zero width", bytes: Fixture.vp8(width: 0, height: 10)),
        Sample(name: "webp vp8l bad signature", bytes: Fixture.vp8l(width: 10, height: 10, signature: 0x2E)),
        Sample(name: "webp vp8x truncated", bytes: Array(Fixture.vp8x(width: 10, height: 10).prefix(29))),
        Sample(name: "webp chunk size past the end",
               bytes: Array(Fixture.vp8x(width: 10, height: 10).prefix(16)) + Fixture.le32(64) + Fixture.vp8x(width: 10, height: 10).dropFirst(20)),
        Sample(name: "webp unknown chunk", bytes: Fixture.webp("ALPH", [UInt8](repeating: 0, count: 10))),
    ])
    func unreadableHeaderReportsNothing(_ sample: Sample) {
        #expect(ImageHeader.pixels(Data(sample.bytes)) == nil)
    }

    @Test(arguments: readable)
    func everyTruncationOfAHeaderReportsNothingOrTheFullSize(_ sample: Sample) {
        for length in 0..<sample.bytes.count {
            let pixels = ImageHeader.pixels(Data(sample.bytes.prefix(length)))
            #expect(pixels == nil || pixels == sample.expected, "prefix \(length)")
        }
    }

    // regression: a Data slice keeps its parent's indices, so offset reads must start at startIndex
    @Test(arguments: readable)
    func sliceOfALargerBufferReportsTheSameSize(_ sample: Sample) {
        let buffer = Data([0xAA, 0xBB, 0xCC] + sample.bytes)
        #expect(ImageHeader.pixels(buffer[3...]) == sample.expected)
    }
}
