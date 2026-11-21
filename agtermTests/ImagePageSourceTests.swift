import XCTest
@testable import agterm

@MainActor
final class ImagePageSourceTests: XCTestCase {
    private let pageID = UUID()

    private func body(_ source: ImagePageSource, _ path: String) async throws -> (String, Data) {
        let resource = try await source.source(path)
        var data = Data()
        for try await chunk in resource.chunks { data.append(chunk) }
        return (resource.mimeType, data)
    }

    private func assertNothing(_ source: ImagePageSource, _ path: String, line: UInt = #line) async {
        do {
            _ = try await source.source(path)
            XCTFail("\(path) was served", line: line)
        } catch {}
    }

    func testAStagedPictureIsServedOnceFromItsLoadAddress() async throws {
        let source = ImagePageSource(pageID: pageID)
        let url = try XCTUnwrap(source.stage(Data([1, 2, 3]), mimeType: "image/png", load: 2))
        XCTAssertEqual(url.scheme, HtmlPageSchemeHandler.scheme)
        XCTAssertEqual(url.host, pageID.uuidString.lowercased())

        let (mime, data) = try await body(source, url.path)
        XCTAssertEqual(mime, "image/png")
        XCTAssertEqual(data, Data([1, 2, 3]))
        await assertNothing(source, url.path)
    }

    func testANewerLoadKeepsItsPictureWhenTheOlderAddressIsAsked() async throws {
        let source = ImagePageSource(pageID: pageID)
        let older = try XCTUnwrap(source.stage(Data([1]), mimeType: "image/png", load: 1))
        let newer = try XCTUnwrap(source.stage(Data([2]), mimeType: "image/gif", load: 2))

        await assertNothing(source, older.path)
        let (mime, data) = try await body(source, newer.path)
        XCTAssertEqual(mime, "image/gif")
        XCTAssertEqual(data, Data([2]))
    }

    func testClearDropsAPictureNobodyTook() async throws {
        let source = ImagePageSource(pageID: pageID)
        let url = try XCTUnwrap(source.stage(Data([1]), mimeType: "image/png", load: 1))
        source.clear()
        await assertNothing(source, url.path)
    }

    func testAnotherPathGetsNothing() async throws {
        let source = ImagePageSource(pageID: pageID)
        _ = source.stage(Data([1]), mimeType: "image/png", load: 1)
        await assertNothing(source, "/image/2")
        await assertNothing(source, "/style.css")
    }
}
