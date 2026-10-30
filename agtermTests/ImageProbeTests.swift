import AppKit
import XCTest
@testable import agterm
import agtermCore

final class ImageProbeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-image-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAPictureLoadsWithItsSizeAndSniffedType() throws {
        let path = try writePNG(width: 30, height: 20, name: "shot.jpg")

        let (probe, data) = try XCTUnwrap(try? ImageProbe.load(path: path).get())

        XCTAssertEqual(probe.pixelWidth, 30)
        XCTAssertEqual(probe.pixelHeight, 20)
        XCTAssertEqual(probe.mimeType, "image/png")
        XCTAssertEqual(data, try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    // regression: the cap measured a symlink's own size and then read its whole target
    func testASymlinkIsMeasuredAtItsTarget() throws {
        let big = dir.appendingPathComponent("big.png")
        let png = try Data(contentsOf: URL(fileURLWithPath: try writePNG(width: 4, height: 4, name: "small.png")))
        try png.write(to: big)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ImagePage.maxBytes + 1))
        try handle.close()
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)

        XCTAssertEqual(failure(link.path), ImageProbe.Failure.tooLarge(link.path).description)
    }

    func testAFifoIsRefusedWithoutBlocking() {
        let fifo = dir.appendingPathComponent("pipe.png").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)

        XCTAssertEqual(failure(fifo), ImageProbe.Failure.unreadable(fifo).description)
    }

    func testADeviceBehindASymlinkIsRefused() throws {
        let link = dir.appendingPathComponent("zero.png")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev/zero")

        XCTAssertEqual(failure(link.path), ImageProbe.Failure.unreadable(link.path).description)
    }

    func testMarkupNamedAsAPictureIsRefusedBeforeImageIO() throws {
        let svg = dir.appendingPathComponent("logo.png")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><script>1</script></svg>"#.utf8).write(to: svg)

        XCTAssertEqual(failure(svg.path), ImageProbe.Failure.notAnImage(svg.path).description)
    }

    func testAMissingFileIsUnreadable() {
        let path = dir.appendingPathComponent("missing.png").path
        XCTAssertEqual(failure(path), ImageProbe.Failure.unreadable(path).description)
    }

    private func failure(_ path: String) -> String? {
        guard case .failure(let failure) = ImageProbe.load(path: path) else { return nil }
        return failure.description
    }

    private func writePNG(width: Int, height: Int, name: String) throws -> String {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = dir.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url.path
    }
}
