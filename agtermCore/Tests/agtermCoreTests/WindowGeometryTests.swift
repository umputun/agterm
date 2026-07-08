import Foundation
import Testing
@testable import agtermCore

struct WindowGeometryTests {
    private func expectSize(_ size: WindowGeometry.Size, _ width: Double, _ height: Double) {
        #expect(size.width == width)
        #expect(size.height == height)
    }

    private func expectPoint(_ point: WindowGeometry.Point, _ x: Double, _ y: Double) {
        #expect(point.x == x)
        #expect(point.y == y)
    }

    private func expectRect(_ rect: WindowGeometry.Rect, _ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        expectPoint(rect.origin, x, y)
        expectSize(rect.size, width, height)
    }

    private func display() -> WindowGeometry.Rect {
        WindowGeometry.Rect(origin: WindowGeometry.Point(x: 0, y: 0),
                            size: WindowGeometry.Size(width: 1920, height: 1080))
    }

    @Test func clampSizeBoundsOversizedRequestToMax() {
        let result = WindowGeometry.clampSize(WindowGeometry.Size(width: 5000, height: 4000),
                                              min: WindowGeometry.Size(width: 400, height: 300),
                                              max: WindowGeometry.Size(width: 1000, height: 800))
        expectSize(result, 1000, 800)
    }

    @Test func clampSizeBoundsTinyRequestToMin() {
        let result = WindowGeometry.clampSize(WindowGeometry.Size(width: 100, height: 50),
                                              min: WindowGeometry.Size(width: 400, height: 300),
                                              max: WindowGeometry.Size(width: 1000, height: 800))
        expectSize(result, 400, 300)
    }

    @Test func clampSizeLeavesInRangeRequestUnchanged() {
        let result = WindowGeometry.clampSize(WindowGeometry.Size(width: 700, height: 500),
                                              min: WindowGeometry.Size(width: 400, height: 300),
                                              max: WindowGeometry.Size(width: 1000, height: 800))
        expectSize(result, 700, 500)
    }

    @Test func clampSizeWithMinGreaterThanMaxReturnsMax() {
        // degenerate range (a window minSize larger than the visible frame): the documented `lo > hi`
        // branch makes the upper bound (max) win in each dimension.
        let result = WindowGeometry.clampSize(WindowGeometry.Size(width: 2000, height: 1500),
                                              min: WindowGeometry.Size(width: 1200, height: 900),
                                              max: WindowGeometry.Size(width: 800, height: 600))
        expectSize(result, 800, 600)
    }

    @Test func clampOriginLeavesOnScreenOriginUnchanged() {
        let result = WindowGeometry.clampOrigin(WindowGeometry.Point(x: 100, y: 100),
                                                windowSize: WindowGeometry.Size(width: 800, height: 600),
                                                displayFrame: display())
        expectPoint(result, 100, 100)
    }

    @Test func clampOriginKeepsOffScreenRightAtLeastPartiallyVisible() {
        let result = WindowGeometry.clampOrigin(WindowGeometry.Point(x: 5000, y: 100),
                                                windowSize: WindowGeometry.Size(width: 800, height: 600),
                                                displayFrame: display())
        // maxX = 1920 - margin; y stays in range and is unchanged.
        expectPoint(result, 1920 - WindowGeometry.visibleMargin, 100)
    }

    @Test func clampOriginKeepsOffScreenBottomLeftAtLeastPartiallyVisible() {
        // AppKit y-up: x=-5000 is off the LEFT, y=-5000 is off the BOTTOM (below the origin).
        let result = WindowGeometry.clampOrigin(WindowGeometry.Point(x: -5000, y: -5000),
                                                windowSize: WindowGeometry.Size(width: 800, height: 600),
                                                displayFrame: display())
        // minX = margin - width; minY = margin - height.
        expectPoint(result, WindowGeometry.visibleMargin - 800, WindowGeometry.visibleMargin - 600)
    }

    @Test func clampOriginKeepsOffScreenTopAtLeastPartiallyVisible() {
        // AppKit y-up: a large +y pushes the window off the TOP, so the origin clamps to maxY (the y-max edge).
        let result = WindowGeometry.clampOrigin(WindowGeometry.Point(x: 100, y: 5000),
                                                windowSize: WindowGeometry.Size(width: 800, height: 600),
                                                displayFrame: display())
        // maxY = 1080 - margin; x stays in range and is unchanged.
        expectPoint(result, 100, 1080 - WindowGeometry.visibleMargin)
    }

    @Test func bestDisplayIndexChoosesLargestOverlapAcrossDisplays() {
        let displays = [
            WindowGeometry.Rect(origin: WindowGeometry.Point(x: 0, y: 0),
                                size: WindowGeometry.Size(width: 1920, height: 1080)),
            WindowGeometry.Rect(origin: WindowGeometry.Point(x: 1920, y: 0),
                                size: WindowGeometry.Size(width: 1920, height: 1080))
        ]
        let frame = WindowGeometry.Rect(origin: WindowGeometry.Point(x: 1800, y: 100),
                                        size: WindowGeometry.Size(width: 400, height: 500))

        #expect(WindowGeometry.bestDisplayIndex(for: frame, among: displays) == 1)
    }

    @Test func bestDisplayIndexReturnsNilWhenFrameOverlapsNoDisplay() {
        let frame = WindowGeometry.Rect(origin: WindowGeometry.Point(x: 5000, y: 100),
                                        size: WindowGeometry.Size(width: 800, height: 600))

        #expect(WindowGeometry.bestDisplayIndex(for: frame, among: [display()]) == nil)
    }

    @Test func constrainShrinksOversizedFrameToDisplay() {
        let frame = WindowGeometry.Rect(origin: WindowGeometry.Point(x: 100, y: 100),
                                        size: WindowGeometry.Size(width: 5000, height: 4000))
        let result = WindowGeometry.constrain(frame: frame,
                                              min: WindowGeometry.Size(width: 640, height: 400),
                                              displayFrame: display())

        expectRect(result, 0, 0, 1920, 1080)
    }

    @Test func constrainFullyContainsOffScreenRightFrame() {
        let frame = WindowGeometry.Rect(origin: WindowGeometry.Point(x: 5000, y: 100),
                                        size: WindowGeometry.Size(width: 800, height: 600))
        let result = WindowGeometry.constrain(frame: frame,
                                              min: WindowGeometry.Size(width: 640, height: 400),
                                              displayFrame: display())

        expectRect(result, 1920 - 800, 100, 800, 600)
    }

    @Test func constrainFullyContainsFrameAboveDisplaySoTitlebarIsReachable() {
        let frame = WindowGeometry.Rect(origin: WindowGeometry.Point(x: 100, y: 5000),
                                        size: WindowGeometry.Size(width: 800, height: 600))
        let result = WindowGeometry.constrain(frame: frame,
                                              min: WindowGeometry.Size(width: 640, height: 400),
                                              displayFrame: display())

        expectRect(result, 100, 1080 - 600, 800, 600)
    }

    @Test func constrainClampsOriginAgainstShrunkOversizedFrame() {
        let frame = WindowGeometry.Rect(origin: WindowGeometry.Point(x: 5000, y: 100),
                                        size: WindowGeometry.Size(width: 5000, height: 4000))
        let result = WindowGeometry.constrain(frame: frame,
                                              min: WindowGeometry.Size(width: 640, height: 400),
                                              displayFrame: display())

        expectRect(result, 0, 0, 1920, 1080)
    }
}
