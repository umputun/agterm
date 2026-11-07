import XCTest
@testable import agterm
import agtermCore

final class DocumentProbeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-document-probe-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func failure(_ result: Result<String, DocumentProbe.Failure>) -> DocumentProbe.Failure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    func testAnHtmlFileLoadsAsItsPage() async throws {
        let path = dir.appendingPathComponent("pr.html").path
        try Data("<h1>pr</h1>".utf8).write(to: URL(fileURLWithPath: path))

        let page = try XCTUnwrap(DocumentPage.page(Data("<h1>pr</h1>".utf8)))
        XCTAssertEqual(DocumentProbe.load(path: path), .success(page))
        let detached = await DocumentProbe.loadDetached(path: path)
        XCTAssertEqual(detached, .success(page))
    }

    func testAFileOverTheCapIsTooLarge() throws {
        let url = dir.appendingPathComponent("big.html")
        try Data(count: DocumentPage.maxBytes + 1).write(to: url)

        XCTAssertEqual(failure(DocumentProbe.load(path: url.path)), .tooLarge(url.path))
    }

    func testABinaryFileIsNotText() throws {
        let path = dir.appendingPathComponent("blob.html").path
        try Data([0x3C, 0x00, 0x3E]).write(to: URL(fileURLWithPath: path))

        XCTAssertEqual(failure(DocumentProbe.load(path: path)), .notText(path))
    }

    func testAFifoADirectoryAndAMissingFileAreUnreadable() throws {
        let fifo = dir.appendingPathComponent("pipe.html").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let folder = dir.appendingPathComponent("sub.html")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = dir.appendingPathComponent("missing.html").path

        for path in [fifo, folder.path, missing] {
            XCTAssertEqual(failure(DocumentProbe.load(path: path)), .unreadable(path), path)
        }
    }
}
