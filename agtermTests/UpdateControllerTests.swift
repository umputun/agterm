@testable import agterm
import XCTest

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testNoUpdaterWithoutFeed() {
        XCTAssertFalse(UpdateController(feed: nil).isAvailable)
        XCTAssertFalse(UpdateController(feed: "").isAvailable)
    }

    func testDebugBuildCarriesNoFeed() {
        XCTAssertFalse(UpdateController().isAvailable)
    }
}
