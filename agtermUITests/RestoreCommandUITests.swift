import XCTest

/// End-to-end for the restore-running-command feature: capture a pane's foreground command at quit and
/// re-run it on relaunch. The marker is `tee <file>` — a NON-shell process (so it isn't filtered as a
/// shell prompt) that creates its output file on start and blocks reading the terminal. Re-running it
/// recreates the file, so a delete-then-relaunch-then-exists cycle is the observable proof of re-run.
@MainActor
final class RestoreCommandUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var marker: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        marker = stateDir.appendingPathComponent("restore-marker")
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    func testRestoreReRunsForegroundCommand() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        runTeeMarker()

        // delete the marker, quit (applicationWillTerminate captures the foreground `tee`), relaunch.
        try FileManager.default.removeItem(at: marker)
        gracefulQuit()
        app.launchForUITest()

        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "restore should re-run the captured foreground `tee` command and recreate the marker")
    }

    func testRestoreOffDoesNotReRun() throws {
        seedRestoreFlag(false)
        app.launchForUITest()
        runTeeMarker()

        try FileManager.default.removeItem(at: marker)
        gracefulQuit()
        app.launchForUITest()

        // flag off → nothing captured at quit → `tee` is not re-run → the marker stays gone.
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "session restored")
        RunLoop.current.run(until: Date().addingTimeInterval(2)) // give any (incorrect) re-run a chance to fire
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "with the flag off, the foreground command must not be re-run")
    }

    // MARK: - Helpers

    /// Seed `restoreRunningCommand` into the isolated `settings.json` before launch.
    private func seedRestoreFlag(_ on: Bool) {
        let json = #"{"restoreRunningCommand":\#(on)}"#
        try? Data(json.utf8).write(to: stateDir.appendingPathComponent("settings.json"))
    }

    /// Type `tee <marker>` into the focused terminal and confirm it created the marker (so it is the live
    /// foreground process — `tee` opens its output file on start, then blocks reading the terminal).
    private func runTeeMarker() {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session row")
        RunLoop.current.run(until: Date().addingTimeInterval(1)) // let the shell reach its prompt
        app.typeText("tee \(marker.path)\n")
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "the foreground `tee` should create its marker file on start (terminal must be focused)")
    }

    /// Quit via ⌘Q so `applicationWillTerminate` fires the capture. `XCUIApplication.terminate()` hard-kills
    /// and skips it; the quit-confirm modal is auto-skipped under XCUITest.
    private func gracefulQuit() {
        app.typeKey("q", modifierFlags: .command)
        _ = app.wait(for: .notRunning, timeout: 10)
    }

    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }
}
