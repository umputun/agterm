import XCTest
@testable import agterm

@MainActor
final class GhosttySurfaceViewTests: XCTestCase {
    private var surface: GhosttySurfaceView!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            // never in a window, so a real frame cannot spawn a libghostty surface and a shell
            surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            surface.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        }
    }

    override func tearDown() async throws {
        await MainActor.run { surface = nil }
        try await super.tearDown()
    }

    func testTakesHitsWhileOnScreen() {
        XCTAssertTrue(surface.hitTest(NSPoint(x: 100, y: 100)) === surface)
    }

    func testRefusesHitsWhileOffScreen() {
        surface.deckVisible = false
        XCTAssertNil(surface.hitTest(NSPoint(x: 100, y: 100)))
    }

    func testRefusesHitsWhileViewOnly() {
        surface.viewOnly = true
        XCTAssertNil(surface.hitTest(NSPoint(x: 100, y: 100)))
    }

    /// The divider case of issue #324: a hidden deck entry stacked over chrome answered for it.
    func testOffScreenSurfaceLetsTheChromeBeneathItAnswer() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        container.addSubview(chrome)
        container.addSubview(surface)
        surface.deckVisible = false
        XCTAssertTrue(container.hitTest(NSPoint(x: 100, y: 100)) === chrome)
        surface.deckVisible = true
        XCTAssertTrue(container.hitTest(NSPoint(x: 100, y: 100)) === surface)
        surface.removeFromSuperview()
    }
}
