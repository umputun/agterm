import XCTest

extension XCUIApplication {
    /// Launch, then explicitly bring the app to the foreground and assert it got there. Required on
    /// macOS 14+: `XCUIApplication.launch()` may leave the app `runningBackground` (Apple's headers
    /// say "whichever is appropriate"), and the app cannot self-activate over the test runner because
    /// `NSApp.activate()` is cooperative. `XCUIApplication.activate()` is the test-runner-level
    /// foregrounding (the programmatic equivalent of a Dock click) — without it the window never
    /// becomes key and every interaction (click/drag/adjust) silently no-ops.
    func launchForeground(file: StaticString = #filePath, line: UInt = #line) {
        launch()
        activate()
        XCTAssertTrue(wait(for: .runningForeground, timeout: 10),
                      "app should be foreground after launch", file: file, line: line)
    }

    /// The single entry point every UI test setUp should use. Sets the force-sidebar sentinel via
    /// ENVIRONMENT (not launch arguments — those trip the macOS 15+ no-window-at-launch bug,
    /// FB11763863), then launches and brings the app to the foreground. Caller sets `AGTERM_STATE_DIR`
    /// (and any test-specific env) before calling.
    func launchForUITest(file: StaticString = #filePath, line: UInt = #line) {
        launchEnvironment["AGTERM_UITEST_FORCE_SIDEBAR_VISIBLE"] = "1"
        launchForeground(file: file, line: line)
    }

    /// A palette or picker row by item id, shared by every palette test. `PaletteRow` carries its
    /// identifier on the row and SwiftUI propagates it to every text child with none of its own, so a row
    /// WITH a subtitle answers to it twice. This stays lazy — `firstMatch` resolves when the query runs,
    /// while eager resolution before the row exists breaks the existence waits. A test that must CLICK the
    /// row needs the hittable match instead; see `ControlPickUITests.clickPaletteRow`.
    func paletteRow(_ id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: "palette-item-\(id)").firstMatch
    }
}

extension XCUIElement {
    /// Polls until the element both exists and is hittable, or the timeout elapses. `waitForExistence`
    /// only checks presence in the accessibility tree (true even when the window is backgrounded), so
    /// interaction-based tests must wait for `isHittable` to know the element can actually be driven.
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return exists && isHittable
    }
}

extension URL {
    /// The persisted single-window snapshot file under an isolated `AGTERM_STATE_DIR`. Per-window state
    /// now lives in `windows/<uuid>.json` (the `WindowLibrary` layout), not the legacy
    /// `workspaces.json`; a single-window test has exactly one such file. Falls back to the legacy
    /// path until the first window file is written, so callers can poll it the same way they polled
    /// `workspaces.json` before. `self` is the state directory.
    func windowSnapshotFile() -> URL {
        let windowsDir = appendingPathComponent("windows", isDirectory: true)
        if let first = (try? FileManager.default.contentsOfDirectory(at: windowsDir, includingPropertiesForKeys: nil))?
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first {
            return first
        }
        return appendingPathComponent("workspaces.json")
    }

    /// Polls the hermetic window snapshot (`windowSnapshotFile()`) until `extract` maps the parsed
    /// snapshot object to `expected`, or the timeout elapses. `self` is the state directory. `extract`
    /// returns nil when the snapshot isn't yet in the wanted shape (file missing, key absent), which
    /// keeps polling. Shared by the session/workspace order pollers so they don't each re-implement the
    /// read-JSON → map → compare → 200ms-sleep loop.
    func pollSnapshot<T: Equatable>(equals expected: T, timeout: TimeInterval,
                                    extract: (([String: Any]) -> T?)) -> Bool {
        let file = windowSnapshotFile()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               extract(obj) == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }
}
