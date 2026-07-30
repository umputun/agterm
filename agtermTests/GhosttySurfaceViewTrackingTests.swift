import XCTest
@testable import agterm

/// Content view whose hit resolution the test supplies directly, standing in for the real window
/// hierarchy: `ownsPointer` only asks who owns a point, so the geometry that would produce the answer is
/// beside the point here.
private final class StubContentView: NSView {
    var hitResult: NSView?
    override func hitTest(_ point: NSPoint) -> NSView? { hitResult }
}

/// Pins the chrome-versus-surface split that keeps the resize cursor over the dividers (issue #324).
/// Returning true for chrome puts the flicker back; returning false for a sibling pane silences the
/// visible terminal's own cursor instead. Neither shows up in any other test.
@MainActor
final class GhosttySurfaceViewTrackingTests: XCTestCase {
    private var window: NSWindow!
    private var content: StubContentView!
    private var surface: GhosttySurfaceView!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            content = StubContentView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            window.contentView = content
            // both surfaces stay at their zero init frame, so `viewDidMoveToWindow` parks in
            // `pendingSurfaceCreation` instead of spawning a libghostty surface and a shell.
            surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            content.addSubview(surface)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            surface.removeFromSuperview()
            surface = nil
            window.orderOut(nil)
            window = nil
            content = nil
        }
        try await super.tearDown()
    }

    func testDeclinesWhenChromeOwnsThePoint() {
        content.hitResult = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 200))
        XCTAssertFalse(surface.ownsPointer(at: NSPoint(x: 10, y: 100)))
    }

    func testOwnsThePointWhenTheHitIsItself() {
        content.hitResult = surface
        XCTAssertTrue(surface.ownsPointer(at: NSPoint(x: 10, y: 100)))
    }

    func testOwnsThePointWhenTheHitIsItsOwnDescendant() {
        let child = NSView(frame: .zero)
        surface.addSubview(child)
        content.hitResult = child
        XCTAssertTrue(surface.ownsPointer(at: NSPoint(x: 10, y: 100)))
    }

    /// The eager deck stacks every session at one frame, so a hit can resolve to a sibling pane. That is
    /// `deckVisible`'s question, not this one: keeping it "owned" degrades to the pre-#324 behavior rather
    /// than leaving the visible terminal with no cursor writer at all.
    func testOwnsThePointWhenTheHitIsASiblingSurface() {
        let sibling = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        content.addSubview(sibling)
        content.hitResult = sibling
        XCTAssertTrue(surface.ownsPointer(at: NSPoint(x: 10, y: 100)))
        sibling.removeFromSuperview()
    }

    func testOwnsThePointWhenNothingIsHit() {
        content.hitResult = nil
        XCTAssertTrue(surface.ownsPointer(at: NSPoint(x: 10, y: 100)))
    }

    func testOwnsThePointWhenDetachedFromAnyWindow() {
        let detached = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        XCTAssertTrue(detached.ownsPointer(at: NSPoint(x: 10, y: 100)))
        XCTAssertTrue(detached.ownsPointer())
    }
}
