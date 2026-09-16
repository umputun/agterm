import XCTest
@testable import agterm

@MainActor
final class GhosttyAppTests: XCTestCase {
    // pins #611: libghostty adopts the user's numeric locale and CoreSVG then mis-sizes SF Symbols.
    func testNumericLocaleIsPinnedAfterGhosttyInit() {
        XCTAssertNotNil(GhosttyApp.shared.app)

        XCTAssertEqual(setlocale(LC_NUMERIC, nil).map { String(cString: $0) }, "C")
    }

    func testTextLocaleKeepsTheAdoptedSetting() {
        XCTAssertNotNil(GhosttyApp.shared.app)

        XCTAssertEqual(setlocale(LC_CTYPE, nil).map { String(cString: $0) }, "ru_RU.UTF-8")
    }

    func testEnvironmentIsLeftForChildProcesses() {
        let env = ProcessInfo.processInfo.environment

        XCTAssertEqual(env["LC_NUMERIC"], "ru_RU.UTF-8")
        XCTAssertEqual(env["LC_CTYPE"], "ru_RU.UTF-8")
        XCTAssertEqual(env["LC_ALL"] ?? "", "")
    }
}
