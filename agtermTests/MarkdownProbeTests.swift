import AppKit
import XCTest
@testable import agterm
import agtermCore

final class MarkdownProbeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-md-probe-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAPlainFileLoadsWithNoImages() throws {
        let path = try write("# Title\n\ntext\n", name: "notes.md")

        let probe = try XCTUnwrap(try? MarkdownProbe.load(path: path).get())

        XCTAssertEqual(probe.markdown, "# Title\n\ntext\n")
        XCTAssertEqual(probe.images, MarkdownPage.Embedded())
        XCTAssertNoThrow(try MarkdownProbe.check(path: path).get())
    }

    func testAFifoAMissingFileAndNonUTF8AreRefused() throws {
        let fifo = dir.appendingPathComponent("pipe.md").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let missing = dir.appendingPathComponent("missing.md").path
        let binary = dir.appendingPathComponent("bin.md")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: binary)

        XCTAssertEqual(failure(fifo), MarkdownProbe.Failure.unreadable(fifo).description)
        XCTAssertEqual(failure(missing), MarkdownProbe.Failure.unreadable(missing).description)
        XCTAssertEqual(failure(binary.path), MarkdownProbe.Failure.notText(binary.path).description)
        guard case .failure = MarkdownProbe.check(path: fifo) else { return XCTFail("a fifo passed the check") }
    }

    func testAnOversizedFileIsRefusedByTheCheckAndTheLoad() throws {
        let big = dir.appendingPathComponent("big.md")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(MarkdownPage.maxBytes + 1))
        try handle.close()

        XCTAssertEqual(failure(big.path), MarkdownProbe.Failure.tooLarge(big.path).description)
        guard case .failure(.tooLarge) = MarkdownProbe.check(path: big.path) else { return XCTFail("the check passed") }
    }

    func testAPictureInTheFolderIsEmbeddedOnceForEachReference() throws {
        let png = try writePNG(name: "shot.png")
        let path = try write("![a](shot.png) ![b](./shot.png) ![c](https://x.io/r.png)", name: "doc.md")

        let probe = try XCTUnwrap(try? MarkdownProbe.load(path: path).get())

        let uri = "data:image/png;base64,\(try Data(contentsOf: URL(fileURLWithPath: png)).base64EncodedString())"
        XCTAssertEqual(probe.images, MarkdownPage.Embedded(uris: [uri], references: ["shot.png": 0, "./shot.png": 0]))
    }

    // regression: every alias of one picture carried its own copy of the data URI
    func testManyAliasesOfOnePictureCarryOneCopy() throws {
        _ = try writePNG(name: "shot.png")
        let aliases = (0..<200).map { "![a](\(String(repeating: "./", count: $0))shot.png)" }.joined(separator: " ")
        let path = try write(aliases, name: "doc.md")

        let probe = try XCTUnwrap(try? MarkdownProbe.load(path: path).get())

        XCTAssertEqual(probe.images.uris.count, 1)
        XCTAssertEqual(probe.images.references.count, 200)
        XCTAssertEqual(Set(probe.images.references.values), [0])
    }

    func testABadSignatureIsLeftOut() throws {
        try Data("<svg/>".utf8).write(to: dir.appendingPathComponent("logo.png"))
        let path = try write("![l](logo.png)", name: "doc.md")

        XCTAssertEqual(try XCTUnwrap(try? MarkdownProbe.load(path: path).get()).images, MarkdownPage.Embedded())
    }

    func testThePixelBudgetLeavesOutAPictureThatWouldExceedItButNotALaterSmallOne() throws {
        try writeLargePNG(name: "a.png")
        try writeLargePNG(name: "b.png")
        _ = try writePNG(name: "c.png")
        let path = try write("![a](a.png) ![b](b.png) ![c](c.png)", name: "doc.md")

        let probe = try XCTUnwrap(try? MarkdownProbe.load(path: path).get())

        XCTAssertEqual(Set(probe.images.references.keys), ["a.png", "c.png"])
        XCTAssertEqual(probe.images.uris.count, 2)
    }

    func testTheByteBudgetLeavesOutAPictureThatWouldExceedIt() throws {
        let half = MarkdownPage.maxImageBytes / 2 + 1
        for name in ["a.png", "b.png"] {
            let url = URL(fileURLWithPath: try writePNG(name: name))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(half))
            try handle.close()
        }
        let path = try write("![a](a.png) ![b](b.png)", name: "doc.md")

        let probe = try XCTUnwrap(try? MarkdownProbe.load(path: path).get())

        XCTAssertEqual(Set(probe.images.references.keys), ["a.png"])
        XCTAssertEqual(probe.images.uris.count, 1)
    }

    // regression: a budget used up exactly ended the loop, dropping later aliases of an embedded picture
    func testAnAliasAfterTheSpentBudgetStillShowsItsPicture() throws {
        let url = URL(fileURLWithPath: try writePNG(name: "a.png"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(MarkdownPage.maxImageBytes))
        try handle.close()
        _ = try writePNG(name: "b.png")
        let path = try write("![a](a.png) ![b](b.png) ![c](./a.png)", name: "doc.md")

        let probe = try XCTUnwrap(try? MarkdownProbe.load(path: path).get())

        XCTAssertEqual(probe.images.references, ["a.png": 0, "./a.png": 0])
        XCTAssertEqual(probe.images.uris.count, 1)
    }

    // regression: every distinct reference was read and probed, failures costing no budget
    func testFailedProbesSpendTheProbeCapAndAnEmbeddedAliasStillResolves() throws {
        _ = try writePNG(name: "a.png")
        let bad = (1..<MarkdownPage.maxImages).map { "bad\($0).png" }
        for name in bad { _ = try write("x", name: name) }
        _ = try writePNG(name: "late.png")
        let refs = (["a.png"] + bad + ["late.png", "./a.png"]).map { "![x](\($0))" }
        let path = try write(refs.joined(separator: " "), name: "doc.md")

        let probe = try XCTUnwrap(try? MarkdownProbe.load(path: path).get())

        XCTAssertEqual(probe.images.references, ["a.png": 0, "./a.png": 0])
        XCTAssertEqual(probe.images.uris.count, 1)
    }

    private func failure(_ path: String) -> String? {
        guard case .failure(let failure) = MarkdownProbe.load(path: path) else { return nil }
        return failure.description
    }

    func testAnEmbeddingFedFromAnyReaderKeepsOneCopyAndSpendsTheByteBudget() throws {
        let png = try Data(contentsOf: URL(fileURLWithPath: try writePNG(name: "a.png")))
        let probe = try XCTUnwrap(try? ImageProbe.probe(png, path: "/o/a.png").get())
        let images = MarkdownPage.remoteImageReferences(in: "![a](a.png) ![s](./a.png) ![b](b.png)", folder: "/o")
        XCTAssertEqual(images.map(\.path), ["/o/a.png", "/o/a.png", "/o/b.png"])
        let (first, alias, refused) = (images[0], images[1], images[2])
        var embedding = MarkdownEmbedding()

        XCTAssertEqual(embedding.room(for: first), MarkdownPage.maxImageBytes)
        embedding.add(first, (probe, png))
        XCTAssertNil(embedding.room(for: alias))
        XCTAssertEqual(embedding.room(for: refused), MarkdownPage.maxImageBytes - png.count)
        embedding.add(refused, nil)
        XCTAssertNil(embedding.room(for: refused))

        XCTAssertEqual(embedding.embedded.uris.count, 1)
        XCTAssertEqual(embedding.embedded.references, ["a.png": 0, "./a.png": 0])
    }

    private func write(_ text: String, name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    private func writePNG(name: String) throws -> String {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = dir.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url.path
    }

    private func writeLargePNG(name: String) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8000, pixelsHigh: 8000,
                                                 bitsPerSample: 1, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
                                                 colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent(name))
    }
}
