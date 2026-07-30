import XCTest

/// Drives the Ctrl-Tab most-recently-used session switcher. XCUITest's `typeKey` presses and
/// releases the modifier around the key, so a single `typeKey("\t", .control)` sends
/// Ctrl-down → Tab → Ctrl-up — exactly the begin-then-release-commit path — and lands on the
/// previously visited session. Asserted through the persisted `selectedSessionID`.
@MainActor
final class SessionSwitcherUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    func testCtrlTabSwitchesToPreviousSession() throws {
        let first = try XCTUnwrap(firstSessionID())

        // the new session becomes selected, making the MRU order [second, first].
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["New Session"].click()
        XCTAssertTrue(poll { self.sessionCount() == 2 }, "a second session should be added")
        let second = try XCTUnwrap(selectedID())
        XCTAssertNotEqual(second, first, "the new session should be selected after add")

        app.typeKey("\t", modifierFlags: .control)
        XCTAssertTrue(poll { self.selectedID() == first }, "Ctrl+Tab should switch to the previously visited session")

        // the commit moved `first` to the MRU front, so another Ctrl+Tab goes back to `second`.
        app.typeKey("\t", modifierFlags: .control)
        XCTAssertTrue(poll { self.selectedID() == second }, "a second Ctrl+Tab should switch back")
    }

    // MARK: - Helpers

    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(150_000)
        }
        return false
    }

    private func snapshot() -> [String: Any]? {
        let file = stateDir.windowSnapshotFile()
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func workspaces() -> [[String: Any]] { snapshot()?["workspaces"] as? [[String: Any]] ?? [] }
    private func sessionCount() -> Int { workspaces().reduce(0) { $0 + (($1["sessions"] as? [[String: Any]])?.count ?? 0) } }
    private func selectedID() -> String? { snapshot()?["selectedSessionID"] as? String }
    private func firstSessionID() -> String? { (workspaces().first?["sessions"] as? [[String: Any]])?.first?["id"] as? String }
}
