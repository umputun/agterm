import agtermCore
import XCTest
@testable import agterm

/// `NSTrackingArea` does not retain its owner, so a probe that leaves the window without handing its area
/// back leaves the split messaging a freed view on the next mouse move.
@MainActor
final class SplitRatioAccessorTests: XCTestCase {
    private var window: NSWindow!
    private var split: NSSplitView!
    private var session: Session!
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
            session = Session(initialCwd: NSTemporaryDirectory())
            probe = SplitRatioAccessor.SplitProbeView(session: session)
            split.arrangedSubviews[0].addSubview(probe)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            probe = nil
            session = nil
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

    private func press(atX x: CGFloat, count: Int, y: CGFloat = 100, windowNumber: Int? = nil) throws -> Bool {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: y),
                                                     modifierFlags: [], timestamp: 0,
                                                     windowNumber: windowNumber ?? window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: count, pressure: 1))
        return probe.consumes(event)
    }

    private func dividerX() throws -> CGFloat {
        try XCTUnwrap(split.arrangedSubviews.first).frame.maxX + split.dividerThickness / 2
    }

    private func doubleClickDivider() throws -> Bool {
        _ = try press(atX: dividerX(), count: 1)
        return try press(atX: dividerX(), count: 2)
    }

    private func leftWidth() -> CGFloat { split.arrangedSubviews[0].frame.width }

    /// Off-center starting point for the gesture, standing in for a user's drag.
    private func offsetDivider(to position: CGFloat) {
        split.setPosition(position, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        probe.layout()
    }

    func testDoubleClickOnTheDividerRestoresTheEvenSplit() throws {
        probe.layout()
        offsetDivider(to: 300)
        XCTAssertTrue(try doubleClickDivider())
        XCTAssertEqual(leftWidth(), 200, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(session.splitRatio), AppStore.splitRatioDefault, accuracy: 0.01)
    }

    func testSingleClickOnTheDividerIsLeftToTheSplitsOwnDrag() throws {
        probe.layout()
        offsetDivider(to: 300)
        XCTAssertFalse(try press(atX: dividerX(), count: 1))
        XCTAssertEqual(leftWidth(), 300, accuracy: 1)
    }

    func testDoubleClickOverAPaneIsLeftToTheTerminal() throws {
        probe.layout()
        offsetDivider(to: 300)
        _ = try press(atX: 50, count: 1)
        XCTAssertFalse(try press(atX: 50, count: 2))
        XCTAssertEqual(leftWidth(), 300, accuracy: 1)
    }

    /// macOS reports `clickCount == 2` for a re-grab close enough in time and space to the last press, so
    /// nudging the divider and grabbing it again must keep the adjustment instead of throwing it away.
    func testRegrabAfterANudgeDragKeepsTheAdjustment() throws {
        probe.layout()
        offsetDivider(to: 300)
        _ = try press(atX: dividerX(), count: 1)
        offsetDivider(to: 320) // the nudge-drag that first press started
        XCTAssertFalse(try press(atX: dividerX(), count: 2))
        XCTAssertEqual(leftWidth(), 320, accuracy: 1)
    }

    func testLeavesDividerClicksAloneWhileOffScreen() throws {
        probe.layout()
        offsetDivider(to: 300)
        probe.deckVisible = false
        XCTAssertFalse(try doubleClickDivider())
        XCTAssertEqual(leftWidth(), 300, accuracy: 1)
    }

    func testLeavesDividerClicksAloneUnderChrome() throws {
        probe.layout()
        offsetDivider(to: 300)
        window.contentView?.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200)))
        XCTAssertFalse(try doubleClickDivider())
        XCTAssertEqual(leftWidth(), 300, accuracy: 1)
    }

    func testLeavesDividerClicksAloneWhileSuspended() throws {
        probe.layout()
        offsetDivider(to: 300)
        probe.suspended = true
        XCTAssertFalse(try doubleClickDivider())
        XCTAssertEqual(leftWidth(), 300, accuracy: 1)
    }

    /// Compact toolbar mode: the split spans the full window height and its divider is masked out of the top
    /// strip, which the titlebar row's own full-width `WindowControlArea` covers. A press up there belongs to
    /// the titlebar, while the divider below the strip still resets — the band is partly covered, not gone.
    func testCompactTitlebarStripDeclinesWhileTheRestOfTheDividerResets() throws {
        probe.titlebarHeight = 30
        probe.layout()
        offsetDivider(to: 300)
        window.contentView?.addSubview(NSView(frame: NSRect(x: 0, y: 170, width: 400, height: 30)))

        _ = try press(atX: dividerX(), count: 1, y: 185)
        XCTAssertFalse(try press(atX: dividerX(), count: 2, y: 185))
        XCTAssertEqual(leftWidth(), 300, accuracy: 1)

        XCTAssertTrue(try doubleClickDivider())
        XCTAssertEqual(leftWidth(), 200, accuracy: 1)
    }

    /// The monitor is shared by every split in the app, so a probe must decline an event that did not come
    /// from its own split's window.
    func testDeclinesAnEventFromAnotherWindow() throws {
        probe.layout()
        offsetDivider(to: 300)
        XCTAssertFalse(try press(atX: dividerX(), count: 1, windowNumber: 0))
        XCTAssertFalse(try press(atX: dividerX(), count: 2, windowNumber: 0))
        XCTAssertEqual(leftWidth(), 300, accuracy: 1)
    }
}
