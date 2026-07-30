import XCTest

/// End-to-end test for per-terminal font-size persistence. The terminal surface is a Metal
/// `GhosttySurfaceView` with no readable accessibility text, so this uses the persisted
/// snapshot file as the oracle: changing the font (cmd +/-) writes the new size to
/// `workspaces.json`, and the value must survive a relaunch.
@MainActor
final class FontSizeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    func testFontSizeChangePersistsAndRestoresAcrossRelaunch() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let baseline = try XCTUnwrap(pollFontSize(timeout: 8), "the terminal should report a font size on launch")

        for _ in 0..<4 {
            app.typeKey("=", modifierFlags: .command)
            usleep(250_000)
        }
        let increased = try XCTUnwrap(pollFontSize(where: { $0 > baseline }, timeout: 8),
                                      "increasing the font (cmd +) should grow the persisted size")
        XCTAssertGreaterThan(increased, baseline)

        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 20), "session should restore")

        let restored = try XCTUnwrap(pollFontSize(where: { abs($0 - increased) < 0.5 }, timeout: 8),
                                     "the increased font size should be restored on relaunch")
        XCTAssertEqual(restored, increased, accuracy: 0.5)
    }

    /// Polls the hermetic snapshot file until the first session's `fontSize` satisfies
    /// `predicate` (default: any non-nil value), returning it or nil on timeout.
    private func pollFontSize(where predicate: (Double) -> Bool = { _ in true }, timeout: TimeInterval) -> Double? {
        let file = stateDir.windowSnapshotFile()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let size = currentFontSize(file), predicate(size) { return size }
            usleep(200_000)
        }
        return nil
    }

    private func currentFontSize(_ file: URL) -> Double? {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = obj["workspaces"] as? [[String: Any]],
              let sessions = workspaces.first?["sessions"] as? [[String: Any]],
              let size = sessions.first?["fontSize"] as? Double
        else { return nil }
        return size
    }
}
