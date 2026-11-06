import XCTest
@testable import agterm
import agtermCore

final class TextProbeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-text-probe-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func failure<T>(_ result: Result<T, TextProbe.Failure>) -> TextProbe.Failure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    func testAPlainFileLoadsAndPassesTheCheck() throws {
        let path = dir.appendingPathComponent("main.go").path
        try Data("package main\n".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertEqual(TextProbe.load(path: path), .success("package main\n"))
        XCTAssertNoThrow(try TextProbe.check(path: path).get())
    }

    func testALogOverTheWholeFileCapPassesTheLogCheckAndLoadsItsEnd() throws {
        let url = dir.appendingPathComponent("big.log")
        let line = String(repeating: "x", count: 99) + "\n"
        try Data(String(repeating: line, count: (TextPage.maxBytes / 100) + 10).utf8).write(to: url)

        XCTAssertEqual(failure(TextProbe.check(path: url.path)), .tooLarge(url.path))
        XCTAssertNoThrow(try TextProbe.checkLog(path: url.path).get())
        let read = try XCTUnwrap(TextProbe.loadLog(path: url.path, tail: 3).get())
        let size = ((TextPage.maxBytes / 100) + 10) * 100
        XCTAssertEqual(read.snapshot, LogTail.Snapshot(text: line + line + line, lines: 3, clipped: false, startOffset: size - 300))
    }

    func testTheLogCheckReadsOnlyTheRequestedTail() throws {
        let url = dir.appendingPathComponent("mixed.log")
        try Data(Array("bad".utf8) + [0] + Array("line\ngood\n".utf8)).write(to: url)

        XCTAssertNoThrow(try TextProbe.checkLog(path: url.path, tail: 1).get())
        XCTAssertEqual(failure(TextProbe.checkLog(path: url.path, tail: 2)), .notText(url.path))
    }

    func testABinaryOrMissingLogFailsTheLogCheck() throws {
        let binary = dir.appendingPathComponent("core.log").path
        try Data([0x61, 0x00, 0x62]).write(to: URL(fileURLWithPath: binary))
        let missing = dir.appendingPathComponent("gone.log").path

        XCTAssertEqual(failure(TextProbe.checkLog(path: binary)), .notText(binary))
        XCTAssertEqual(failure(TextProbe.checkLog(path: missing)), .unreadable(missing))
    }

    func testAFifoADirectoryAndAMissingFileAreUnreadable() throws {
        let fifo = dir.appendingPathComponent("pipe.log").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let folder = dir.appendingPathComponent("sub.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = dir.appendingPathComponent("missing.txt").path

        for path in [fifo, folder.path, missing] {
            XCTAssertEqual(failure(TextProbe.check(path: path)), .unreadable(path), path)
        }
    }

    func testASymlinkToAFifoIsUnreadable() throws {
        let fifo = dir.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let link = dir.appendingPathComponent("link.txt").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fifo)

        XCTAssertEqual(failure(TextProbe.check(path: link)), .unreadable(link))
    }

    func testAnOversizedFileIsRefusedBeforeItIsRead() throws {
        let big = dir.appendingPathComponent("big.log")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(TextPage.maxBytes + 1))
        try handle.close()

        XCTAssertEqual(failure(TextProbe.check(path: big.path)), .tooLarge(big.path))
    }

    func testBinaryAndInvalidUTF8ContentFailTheCheck() throws {
        let nul = dir.appendingPathComponent("nul.txt")
        try Data([0x61, 0x00, 0x62]).write(to: nul)
        let invalid = dir.appendingPathComponent("bad.txt")
        try Data([0xFF, 0xFE, 0x61]).write(to: invalid)

        XCTAssertEqual(failure(TextProbe.check(path: nul.path)), .notText(nul.path))
        XCTAssertEqual(failure(TextProbe.check(path: invalid.path)), .notText(invalid.path))
    }

    func testBytesInHandAreJudgedLikeAFile() {
        XCTAssertEqual(try? TextProbe.text(Data("let x = 1\n".utf8), path: "/o/a.swift").get(), "let x = 1\n")
        XCTAssertEqual(failure(TextProbe.text(Data([0x61, 0x00, 0x62]), path: "/o/nul.txt")), .notText("/o/nul.txt"))
        XCTAssertEqual(failure(TextProbe.text(Data([0xFF, 0xFE, 0x61]), path: "/o/bad.txt")), .notText("/o/bad.txt"))
    }

    func testTheDetachedCheckMatchesTheCheck() async throws {
        let path = dir.appendingPathComponent("a.txt").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        let nul = dir.appendingPathComponent("b.txt")
        try Data([0x00]).write(to: nul)

        let ok = await TextProbe.checkDetached(path: path)
        let refused = await TextProbe.checkDetached(path: nul.path)

        XCTAssertNoThrow(try ok.get())
        XCTAssertEqual(failure(refused), .notText(nul.path))
    }
}
