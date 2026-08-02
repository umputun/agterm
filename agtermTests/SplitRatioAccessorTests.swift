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
}
