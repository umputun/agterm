import XCTest
@testable import agterm
import agtermCore

@MainActor
final class LinkHoverLabelTests: XCTestCase {
    private var savedSessionName: ((UUID, LinkPolicy.ClickOrigin, UUID?) -> String?)!

    override func setUp() async throws {
        try await super.setUp()
        savedSessionName = LinkOpener.shared.sessionName
    }

    override func tearDown() async throws {
        LinkOpener.shared.sessionName = savedSessionName
        try await super.tearDown()
    }

    func testAHoveredLinkSetsTheLabelAndAnEmptyOneClearsIt() {
        let view = GhosttySurfaceView(workingDirectory: "/tmp")
        let model = LinkHoverModel()
        model.adopt(view)

        view.applyLinkHover("https://example.com/a")
        XCTAssertEqual(model.label, "https://example.com/a")

        view.applyLinkHover("")
        XCTAssertNil(model.label)
    }

    func testASessionLinkIsNamedThroughTheClickResolution() {
        let view = GhosttySurfaceView(workingDirectory: "/tmp")
        let model = LinkHoverModel()
        model.adopt(view)
        let target = UUID()
        LinkOpener.shared.sessionName = { id, _, _ in id == target ? "build" : nil }

        view.applyLinkHover("agterm://session/\(target.uuidString)")

        XCTAssertEqual(model.label, "Session: build")
    }

    func testMovingToAnotherHostClearsTheLabelItLeaves() {
        let view = GhosttySurfaceView(workingDirectory: "/tmp")
        let (deck, zoom) = (LinkHoverModel(), LinkHoverModel())
        deck.adopt(view)
        view.applyLinkHover("https://example.com/a")

        deck.adopt(view)
        XCTAssertEqual(deck.label, "https://example.com/a")
        zoom.adopt(view)
        view.applyLinkHover("https://example.com/b")

        XCTAssertNil(deck.label)
        XCTAssertEqual(zoom.label, "https://example.com/b")
    }

    func testTeardownClearsTheLabel() {
        let view = GhosttySurfaceView(workingDirectory: "/tmp")
        let model = LinkHoverModel()
        model.adopt(view)
        view.applyLinkHover("https://example.com/a")

        view.destroySurface()
        XCTAssertNil(model.label)

        view.applyLinkHover("https://example.com/b")
        XCTAssertNil(model.label, "a hover queued before teardown")
    }
}
