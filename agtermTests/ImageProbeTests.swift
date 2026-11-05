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

    func testATailOfASmallFileStartsAtItsFirstByte() throws {
        let path = dir.appendingPathComponent("small.log").path
        try Data("one\ntwo\n".utf8).write(to: URL(fileURLWithPath: path))

        let read = try XCTUnwrap(BoundedFile.readTail(path: path, maxBytes: 64).get())

        XCTAssertEqual(read.data, Data("one\ntwo\n".utf8))
        XCTAssertEqual(read.offset, 0)
        XCTAssertEqual(read.stamp.size, 8)
    }

    func testATailOfALargeFileReadsTheWindowAndTheByteBeforeIt() throws {
        let path = dir.appendingPathComponent("big.log").path
        try Data("0123456789abcdef".utf8).write(to: URL(fileURLWithPath: path))

        let read = try XCTUnwrap(BoundedFile.readTail(path: path, maxBytes: 4).get())

        XCTAssertEqual(read.data, Data("bcdef".utf8))
        XCTAssertEqual(read.offset, 11)
    }

    func testATailIgnoresTheWholeFileCapAndMeasuresASymlinkAtItsTarget() throws {
        let big = dir.appendingPathComponent("huge.log")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(TextPage.maxBytes * 2))
        try handle.close()
        let link = dir.appendingPathComponent("link.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)

        let read = try XCTUnwrap(BoundedFile.readTail(path: link.path, maxBytes: 16).get())

        XCTAssertEqual(read.data.count, 17)
        XCTAssertEqual(read.stamp.size, TextPage.maxBytes * 2)
    }

    func testATailOfAFifoOrADeviceIsRefused() throws {
        let fifo = dir.appendingPathComponent("pipe.log").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let device = dir.appendingPathComponent("zero.log")
        try FileManager.default.createSymbolicLink(atPath: device.path, withDestinationPath: "/dev/zero")

        for path in [fifo, device.path] {
            XCTAssertEqual(BoundedFile.readTail(path: path, maxBytes: 16).failure, .unreadable, path)
        }
    }

    func testATailStampChangesWhenTheFileGrowsOrIsReplaced() throws {
        let url = dir.appendingPathComponent("app.log")
        try Data("a\n".utf8).write(to: url)
        let first = try XCTUnwrap(BoundedFile.readTail(path: url.path, maxBytes: 64).get()).stamp
        XCTAssertEqual(try XCTUnwrap(BoundedFile.readTail(path: url.path, maxBytes: 64).get()).stamp, first)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("b\n".utf8))
        try handle.close()
        let grown = try XCTUnwrap(BoundedFile.readTail(path: url.path, maxBytes: 64).get()).stamp
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("app.log.1"))
        try Data("a\nb\n".utf8).write(to: url)
        let replaced = try XCTUnwrap(BoundedFile.readTail(path: url.path, maxBytes: 64).get()).stamp

        XCTAssertNotEqual(grown, first)
        XCTAssertNotEqual(replaced.inode, grown.inode)
    }

    func testATailOfAnUnchangedFileReadsNothing() throws {
        let url = dir.appendingPathComponent("app.log")
        try Data("a\n".utf8).write(to: url)
        let stamp = try XCTUnwrap(BoundedFile.readTail(path: url.path, maxBytes: 64).get()).stamp

        XCTAssertNil(try BoundedFile.readTail(path: url.path, maxBytes: 64, unchangedFrom: stamp).get())
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("b\n".utf8))
        try handle.close()
        XCTAssertEqual(try BoundedFile.readTail(path: url.path, maxBytes: 64, unchangedFrom: stamp).get()?.data, Data("a\nb\n".utf8))
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

    func testBytesInHandAreJudgedLikeAFile() throws {
        let png = try Data(contentsOf: URL(fileURLWithPath: try writePNG(width: 12, height: 7, name: "a.png")))
        let probe = try XCTUnwrap(try? ImageProbe.probe(png, path: "/o/a.png").get())
        XCTAssertEqual(probe.pixelWidth, 12)
        XCTAssertEqual(probe.pixelHeight, 7)
        guard case .failure(let markup) = ImageProbe.probe(Data("<svg/>".utf8), path: "/o/logo.png") else {
            return XCTFail("markup accepted as a picture")
        }
        XCTAssertEqual(markup.description, "not a png, jpg, gif or webp image: /o/logo.png")
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10_001, pixelsHigh: 10_000,
                                                 bitsPerSample: 1, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
                                                 colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0))
        let huge = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        guard case .failure(let bomb) = ImageProbe.probe(huge, path: "/o/bomb.png") else { return XCTFail("bomb accepted") }
        XCTAssertEqual(bomb.description, "image too large (over 100 megapixels): /o/bomb.png")
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

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
