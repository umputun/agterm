import Foundation
import Testing
@testable import agtermCore

struct WindowGeometryTests {
    // under host-free Foundation CGSize/CGPoint members are Double; compare against Double to avoid the
    // Double/CGFloat implicit-conversion the #expect macro mis-captures (and to dodge the missing overlay
    // Equatable conformance). margin is converted via Double() for the same reason.
    private func expectSize(_ size: CGSize, _ width: Double, _ height: Double) {
        #expect(size.width == width)
        #expect(size.height == height)
    }

    private func expectPoint(_ point: CGPoint, _ x: Double, _ y: Double) {
        #expect(point.x == x)
        #expect(point.y == y)
    }

    private func display() -> CGRect {
        CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 1920, height: 1080))
    }

    @Test func clampSizeBoundsOversizedRequestToMax() {
        let result = WindowGeometry.clampSize(CGSize(width: 5000, height: 4000),
                                              min: CGSize(width: 400, height: 300),
                                              max: CGSize(width: 1000, height: 800))
        expectSize(result, 1000, 800)
    }

    @Test func clampSizeBoundsTinyRequestToMin() {
        let result = WindowGeometry.clampSize(CGSize(width: 100, height: 50),
                                              min: CGSize(width: 400, height: 300),
                                              max: CGSize(width: 1000, height: 800))
        expectSize(result, 400, 300)
    }

    @Test func clampSizeLeavesInRangeRequestUnchanged() {
        let result = WindowGeometry.clampSize(CGSize(width: 700, height: 500),
                                              min: CGSize(width: 400, height: 300),
                                              max: CGSize(width: 1000, height: 800))
        expectSize(result, 700, 500)
    }

    @Test func clampSizeWithMinGreaterThanMaxReturnsMax() {
        // degenerate range (a window minSize larger than the visible frame): the documented `lo > hi`
        // branch makes the upper bound (max) win in each dimension.
        let result = WindowGeometry.clampSize(CGSize(width: 2000, height: 1500),
                                              min: CGSize(width: 1200, height: 900),
                                              max: CGSize(width: 800, height: 600))
        expectSize(result, 800, 600)
    }

    @Test func clampOriginLeavesOnScreenOriginUnchanged() {
        let result = WindowGeometry.clampOrigin(CGPoint(x: 100, y: 100),
                                                windowSize: CGSize(width: 800, height: 600),
                                                displayFrame: display())
        expectPoint(result, 100, 100)
    }

    @Test func clampOriginKeepsOffScreenRightAtLeastPartiallyVisible() {
        let result = WindowGeometry.clampOrigin(CGPoint(x: 5000, y: 100),
                                                windowSize: CGSize(width: 800, height: 600),
                                                displayFrame: display())
        // maxX = 1920 - margin; y stays in range and is unchanged.
        expectPoint(result, 1920 - Double(WindowGeometry.visibleMargin), 100)
    }

    @Test func clampOriginKeepsOffScreenBottomLeftAtLeastPartiallyVisible() {
        // AppKit y-up: x=-5000 is off the LEFT, y=-5000 is off the BOTTOM (below the origin).
        let result = WindowGeometry.clampOrigin(CGPoint(x: -5000, y: -5000),
                                                windowSize: CGSize(width: 800, height: 600),
                                                displayFrame: display())
        // minX = margin - width; minY = margin - height.
        expectPoint(result, Double(WindowGeometry.visibleMargin) - 800, Double(WindowGeometry.visibleMargin) - 600)
    }

    @Test func clampOriginKeepsOffScreenTopAtLeastPartiallyVisible() {
        // AppKit y-up: a large +y pushes the window off the TOP, so the origin clamps to maxY (the y-max edge).
        let result = WindowGeometry.clampOrigin(CGPoint(x: 100, y: 5000),
                                                windowSize: CGSize(width: 800, height: 600),
                                                displayFrame: display())
        // maxY = 1080 - margin; x stays in range and is unchanged.
        expectPoint(result, 100, 1080 - Double(WindowGeometry.visibleMargin))
    }
}
