import XCTest
@testable import agterm

/// An `NSSplitView` that records the divider rects AppKit's own `resetCursorRects` registers.
final class RecordingSplit: NSSplitView {
    private(set) var dividerRects: [NSRect] = []

    override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
        if !rect.isEmpty { dividerRects.append(rect) }
        super.addCursorRect(rect, cursor: cursor)
    }

    /// Rebuilds the window's cursor rects and returns what this split registered in that pass.
    func rebuildCursorRects() -> [NSRect] {
        dividerRects = []
        window?.resetCursorRects()
        return dividerRects
    }
}

@MainActor
final class SplitCursorRectsTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            window.orderOut(nil)
            window = nil
        }
        try await super.tearDown()
    }

    private func makeSplit(y: CGFloat = 0) -> RecordingSplit {
        let split = RecordingSplit(frame: NSRect(x: 0, y: y, width: 400, height: 100))
        split.isVertical = true
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        split.adjustSubviews()
        window.contentView?.addSubview(split)
        return split
    }

    func testAnUnmanagedSplitKeepsItsDividerRect() {
        let split = makeSplit()
        SplitCursorRects.setSuppressed(false, for: split)
        XCTAssertEqual(split.rebuildCursorRects().count, 1)
    }

    func testASuppressedSplitRegistersNoDividerRect() {
        let split = makeSplit()
        XCTAssertEqual(split.rebuildCursorRects().count, 1)
        SplitCursorRects.setSuppressed(true, for: split)
        XCTAssertTrue(split.rebuildCursorRects().isEmpty)
        XCTAssertTrue(split.rebuildCursorRects().isEmpty)
    }

    func testLiftingSuppressionRestoresTheDividerRect() {
        let split = makeSplit()
        SplitCursorRects.setSuppressed(true, for: split)
        XCTAssertTrue(split.rebuildCursorRects().isEmpty)
        SplitCursorRects.setSuppressed(false, for: split)
        XCTAssertEqual(split.rebuildCursorRects().count, 1)
    }

    func testSuppressingOneSplitLeavesAnotherAlone() {
        let hidden = makeSplit()
        let shown = makeSplit(y: 100)
        SplitCursorRects.setSuppressed(true, for: hidden)
        window.resetCursorRects()
        XCTAssertTrue(hidden.rebuildCursorRects().isEmpty)
        XCTAssertEqual(shown.rebuildCursorRects().count, 1)
    }
}
