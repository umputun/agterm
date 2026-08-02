import agtermCore
import XCTest
@testable import agterm

/// `NSTrackingArea` does not retain its owner, so a probe that leaves the window without handing its area
/// back leaves the split messaging a freed view on the next mouse move.
@MainActor
final class SplitRatioAccessorTests: XCTestCase {
    private var window: NSWindow!
    private var split: NSSplitView!
    private var probe: SplitRatioAccessor.SplitProbeView!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            split.isVertical = true
            split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)))
            split.addArrangedSubview(NSView(frame: NSRect(x: 201, y: 0, width: 199, height: 200)))
            window.contentView?.addSubview(split)
            probe = SplitRatioAccessor.SplitProbeView(session: Session(initialCwd: NSTemporaryDirectory()))
            split.arrangedSubviews[0].addSubview(probe)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            probe = nil
            split = nil
            window.orderOut(nil)
            window = nil
        }
        try await super.tearDown()
    }

    private func trackingAreasOwnedByProbe() -> Int {
        split.trackingAreas.filter { $0.owner as AnyObject? === probe }.count
    }

    func testArmsTheSplitOnce() {
        probe.layout()
        probe.layout()
        XCTAssertEqual(trackingAreasOwnedByProbe(), 1)
    }

    func testHandsTheTrackingAreaBackWhenLeavingTheWindow() {
        probe.layout()
        probe.removeFromSuperview()
        XCTAssertEqual(trackingAreasOwnedByProbe(), 0)
    }

    func testRearmsAfterAReHost() {
        probe.layout()
        probe.removeFromSuperview()
        split.arrangedSubviews[0].addSubview(probe)
        probe.layout()
        XCTAssertEqual(trackingAreasOwnedByProbe(), 1)
    }

    private func move(toX x: CGFloat) throws {
        split.setPosition(200, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: x, y: 100),
                                                     modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 0, pressure: 0))
        probe.mouseMoved(with: event)
    }

    private func moveOverDivider() throws { try move(toX: 200 + split.dividerThickness / 2) }

    func testPaintsTheResizeCursorOverItsOwnDivider() throws {
        probe.layout()
        NSCursor.arrow.set()
        try moveOverDivider()
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
    }

    /// The tracking area covers the whole split, not the band, so every move over a pane arrives here too.
    func testLeavesTheCursorAloneOverAPane() throws {
        probe.layout()
        NSCursor.arrow.set()
        try move(toX: 50)
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
    }

    /// A background session's split is laid out at the full frame and its tracking area still fires, so its
    /// divider column sits over whatever session IS on screen.
    func testLeavesTheCursorAloneWhileOffScreen() throws {
        probe.layout()
        probe.deckVisible = false
        NSCursor.arrow.set()
        try moveOverDivider()
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
    }

    /// The real split is inset by the sidebar and the titlebar, and `hitTest` takes the point in the
    /// receiver's SUPERVIEW space, so an origin-zero split cannot tell a correct conversion from a missing one.
    func testPaintsAtTheRightPlaceWhenTheSplitIsInset() throws {
        split.frame = NSRect(x: 40, y: 10, width: 360, height: 180)
        split.layoutSubtreeIfNeeded()
        probe.layout()
        NSCursor.arrow.set()
        try move(toX: 40 + 200 + split.dividerThickness / 2)
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
        NSCursor.arrow.set()
        try move(toX: 200) // where the divider would be if the inset were dropped
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
    }

    /// A palette scrim, the search bar or the compact titlebar strip covers the band without touching the
    /// deck's own gates.
    func testLeavesTheCursorAloneUnderChrome() throws {
        probe.layout()
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView?.addSubview(chrome)
        NSCursor.arrow.set()
        try moveOverDivider()
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
    }

    func testLeavesTheCursorAloneWhileSuspended() throws {
        probe.layout()
        probe.suspended = true
        NSCursor.arrow.set()
        try moveOverDivider()
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
    }
}
