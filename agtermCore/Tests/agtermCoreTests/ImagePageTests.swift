import Foundation
import Testing
@testable import agtermCore

struct ImagePageTests {
    struct Case: Sendable {
        let width: Double
        let height: Double
        let factor: Double
        let expected: OverlayPointSize
    }

    struct Rotation: Sendable {
        let orientation: Int
        let scale: Double
        let width: Double
        let height: Double
    }

    @Test(arguments: [
        Rotation(orientation: 1, scale: 2, width: 600, height: 400),
        Rotation(orientation: 1, scale: 1, width: 1200, height: 800),
        Rotation(orientation: 6, scale: 2, width: 400, height: 600),
        Rotation(orientation: 8, scale: 1, width: 800, height: 1200),
        Rotation(orientation: 3, scale: 1, width: 1200, height: 800),
        Rotation(orientation: 1, scale: 0, width: 1200, height: 800),
    ])
    func naturalSizeIsDisplayPixelsWithRotationApplied(_ test: Rotation) {
        let natural = ImagePage.natural(pixelWidth: 1200, pixelHeight: 800, orientation: test.orientation, scale: test.scale)
        #expect(natural.width == test.width)
        #expect(natural.height == test.height)
    }

    @Test(arguments: [
        Case(width: 600, height: 400, factor: 1, expected: OverlayPointSize(width: 600, height: 400)),
        Case(width: 600, height: 400, factor: 1.5, expected: OverlayPointSize(width: 900, height: 600)),
        Case(width: 100, height: 50, factor: 1, expected: OverlayPointSize(width: 240, height: 120)),
        Case(width: 3000.5, height: 300, factor: 1, expected: OverlayPointSize(width: 3001, height: 300)),
    ])
    func pointsFollowTheZoomAndScaleANarrowPictureUpToTheMinimumWidth(_ test: Case) {
        #expect(ImagePage.points(natural: (test.width, test.height), zoom: test.factor) == test.expected)
    }

    // regression: a picture capped on one axis kept its natural size on the other, leaving empty bands
    @Test(arguments: [
        Case(width: 3000, height: 300, factor: 1, expected: OverlayPointSize(width: 800, height: 80)),
        Case(width: 600, height: 3000, factor: 1, expected: OverlayPointSize(width: 122, height: 611)),
        Case(width: 600, height: 400, factor: 1, expected: OverlayPointSize(width: 600, height: 400)),
        Case(width: 1000, height: 1000, factor: 1, expected: OverlayPointSize(width: 611, height: 611)),
        Case(width: 100, height: 50, factor: 1, expected: OverlayPointSize(width: 240, height: 120)),
    ])
    func thePanelKeepsThePicturesAspectInsideTheCap(_ test: Case) {
        let bounds = HudPaneFrame(x: 0, y: 0, width: 1000, height: 800)
        #expect(ImagePage.points(natural: (test.width, test.height), zoom: test.factor, bounds: bounds) == test.expected)
    }

    @Test(arguments: [
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0], "image/png"),
        ([0xFF, 0xD8, 0xFF, 0xE0, 0], "image/jpeg"),
        (Array("GIF89a..".utf8), "image/gif"),
        (Array("GIF87a..".utf8), "image/gif"),
        (Array("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8), "image/webp"),
        (Array("<svg xmlns=".utf8), nil),
        (Array("<html><body>".utf8), nil),
        (Array("RIFF\u{0}\u{0}\u{0}\u{0}WAVEfmt ".utf8), nil),
        ([0x89, 0x50, 0x4E], nil),
        ([], nil),
    ] as [([UInt8], String?)])
    func signatureNamesOnlyTheFourRasterFormats(_ bytes: [UInt8], _ expected: String?) {
        #expect(ImagePage.mimeType(sniffing: Data(bytes)) == expected)
    }

    @Test(arguments: [(10_000, 10_000, true), (10_000, 10_001, false), (12_000, 12_000, false), (Int.max, 2, false)])
    func pixelLimitRefusesADecompressionBombsPromisedSize(_ width: Int, _ height: Int, _ allowed: Bool) {
        #expect(ImagePage.allowsPixels(width: width, height: height) == allowed)
    }

    @Test func htmlEmbedsTheDataAndFillsThePage() {
        let html = ImagePage.html(data: Data([1, 2, 3]), mimeType: "image/png")
        #expect(html.contains("src=\"data:image/png;base64,AQID\""))
        #expect(html.contains("width:100%;height:100%;object-fit:contain"))
    }
}
