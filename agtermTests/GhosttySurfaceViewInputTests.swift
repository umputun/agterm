import XCTest
@testable import agterm

@MainActor
final class GhosttySurfaceViewInputTests: XCTestCase {
    private var surface: GhosttySurfaceView!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory()) }
    }

    override func tearDown() async throws {
        await MainActor.run { surface = nil }
        try await super.tearDown()
    }

    func testSelectedRangeIsAnEmptyInsertionPointWithoutAComposition() {
        XCTAssertFalse(surface.hasMarkedText())
        XCTAssertEqual(surface.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testSelectedRangeIsTheImeSelectionWhileComposing() {
        surface._markedRange = NSRange(location: 0, length: 5)
        surface._selectedRange = NSRange(location: 5, length: 0)
        XCTAssertEqual(surface.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testSelectedRangeDropsTheStaleImeSelectionOnceCompositionEnds() {
        surface._markedRange = NSRange(location: 0, length: 5)
        surface._selectedRange = NSRange(location: 5, length: 0)
        surface._markedRange = NSRange(location: NSNotFound, length: 0)
        XCTAssertEqual(surface.selectedRange(), NSRange(location: 0, length: 0))
    }
}
