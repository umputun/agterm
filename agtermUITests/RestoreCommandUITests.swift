import Darwin
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
    private var splitMarker: URL!
    private var overrideMarker: URL!
    private var socketPath: String!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        marker = stateDir.appendingPathComponent("restore-marker")
        splitMarker = stateDir.appendingPathComponent("restore-split-marker")
        overrideMarker = stateDir.appendingPathComponent("restore-override-marker")
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        // short socket path in the runner's temp dir: under the ~104-byte sun_path limit AND inside the
        // runner sandbox (the long per-test stateDir subdir + /tmp both fail).
        socketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("agtermr-\(UUID().uuidString.prefix(8)).sock")
        app.launchEnvironment["AGTERM_CONTROL_SOCKET"] = socketPath
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
    }

    func testRestoreReRunsForegroundCommand() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        runTeeMarker()

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

        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "session restored")
        RunLoop.current.run(until: Date().addingTimeInterval(2)) // give any (incorrect) re-run a chance to fire
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "with the flag off, the foreground command must not be re-run")
    }

    func testRestoreReRunsShellScriptWrapper() throws {
        // the real `cld` launcher is a `#!/bin/sh` wrapper whose foreground is `/bin/sh <script>`. This
        // stands in with `sh -c 'tee …; true'` (a compound list keeps sh the foreground, with a payload
        // arg) because the XCUITest runner cannot drop an executable script the sandboxed app may run.
        seedRestoreFlag(true)
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session row")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeText("sh -c 'tee \(marker.path); true'\n")
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "the `sh -c` wrapper's tee should create the marker on start")

        try FileManager.default.removeItem(at: marker)
        gracefulQuit()
        app.launchForUITest()
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "restore should re-run the captured `sh -c` wrapper and recreate the marker")
    }

    func testRestoreSkipsIdleShellPane() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        // the idle login shell (argv0 `-/bin/zsh`) must not be captured even with the flag on
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        gracefulQuit()
        XCTAssertTrue(capturedForegroundCommands().isEmpty,
                      "an idle login-shell pane must not be captured as a foreground command, got \(capturedForegroundCommands())")
    }

    // the quit-time capture reads the pane's process-GROUP leader, which for a command session is unreadable
    // setuid-root `login`, so NOTHING is captured and the re-run can only come from `initialCommand`. This
    // does not pin that split on its own: were the capture to descend, it would type `tee <marker>` into the
    // login shell, recreating the marker this asserts on.
    func testRestoreReRunsCommandSession() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 30), "control server up")
        let created = try sendCommand(#"{"cmd":"session.new","args":{"command":"tee \#(marker.path)"}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new --command should succeed: \(created)")
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "the --command `tee` should create its marker on start")

        try FileManager.default.removeItem(at: marker)
        gracefulQuit()
        app.launchForUITest()
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "restore should re-run the persisted --command (via the exec path) and recreate the marker")
    }

    func testRestoreOffLeavesCommandSessionAPlainShell() throws {
        seedRestoreFlag(false)
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 30), "control server up")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.new","args":{"command":"tee \#(marker.path)"}}"#)["ok"] as? Bool,
                       true, "session.new --command should succeed")
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) }, "marker created on start")

        try FileManager.default.removeItem(at: marker)
        gracefulQuit()
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "session restored")
        RunLoop.current.run(until: Date().addingTimeInterval(2)) // give any (incorrect) re-run a chance to fire
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "with the flag off, a restored --command session must not re-run its command")
    }

    // MARK: - session.restore override

    // BOTH markers are deleted before quitting, so the proof is two-sided: the override's marker reappears
    // and the captured command's does not (testRestoreReRunsForegroundCommand proves it would otherwise).
    func testRestoreOverrideBeatsCapturedCommand() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        runTeeMarker()
        try pinRestore(mode: "set", command: touchLine(overrideMarker))
        assertOverrideHasNotFired("pinning is write-now/consume-next-launch: it must not run in the live session")

        try FileManager.default.removeItem(at: marker)
        gracefulQuit()
        app.launchForUITest()

        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.overrideMarker.path) },
                      "the pinned override should run on restore and recreate its marker")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the captured foreground command must not run when an override is pinned")
    }

    // one relaunch cannot prove stickiness — it passes even against an implementation that nils the
    // persisted field on consume — so this runs two.
    func testRestoreOverrideStaysPinnedAcrossTwoRelaunches() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        try pinRestore(mode: "set", command: touchLine(overrideMarker))

        gracefulQuit()
        app.launchForUITest()
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.overrideMarker.path) },
                      "the pinned override should fire on the first relaunch")

        // `touch` exits, so this quit captures nothing — only the sticky override can recreate the marker
        try FileManager.default.removeItem(at: overrideMarker)
        gracefulQuit()
        XCTAssertTrue(capturedForegroundCommands().isEmpty,
                      "the override's `touch` exits, so nothing may be captured: \(capturedForegroundCommands())")
        app.launchForUITest()
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.overrideMarker.path) },
                      "the override must fire again on the second relaunch — it is sticky, not consumed")
    }

    func testRestoreOverrideNonePinsPlainShell() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        runTeeMarker()
        try pinRestore(mode: "none")

        try FileManager.default.removeItem(at: marker)
        gracefulQuit()
        app.launchForUITest()

        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "session restored")
        RunLoop.current.run(until: Date().addingTimeInterval(3)) // give any (incorrect) re-run a chance to fire
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "a pane pinned to nothing must restore a plain shell, not the captured command")
    }

    func testRestoreOverrideClearRestoresCapture() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        runTeeMarker()
        try pinRestore(mode: "set", command: touchLine(overrideMarker))
        try pinRestore(mode: "clear")

        try FileManager.default.removeItem(at: marker)
        try? FileManager.default.removeItem(at: overrideMarker)
        gracefulQuit()
        app.launchForUITest()

        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "clearing the override restores auto-capture, so the captured `tee` re-runs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: overrideMarker.path),
                       "a cleared override must not run")
    }

    // the response says the setting is off up front; a hook author would otherwise see a silent no-op.
    func testRestoreOverrideDoesNotFireWithRestoreOff() throws {
        seedRestoreFlag(false)
        app.launchForUITest()
        let pinned = try pinRestore(mode: "set", command: touchLine(overrideMarker))
        let note = (pinned["result"] as? [String: Any])?["text"] as? String ?? ""
        XCTAssertTrue(note.contains("off"), "pinning while the setting is off should say so: \(pinned)")

        gracefulQuit()
        app.launchForUITest()

        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "session restored")
        RunLoop.current.run(until: Date().addingTimeInterval(3)) // give any (incorrect) re-run a chance to fire
        XCTAssertFalse(FileManager.default.fileExists(atPath: overrideMarker.path),
                       "with the restore setting off, a pinned override must not run")
    }

    // the split pane has its own override slot and its own restore path — `makeSplitSurface` bypasses
    // `restorePlan` entirely. The main pane, pinned to nothing, still restores its own capture.
    func testRestoreOverrideOnSplitPane() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 30), "control server up")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","args":{"mode":"on"}}"#)["ok"] as? Bool, true,
                       "session.split on should succeed")
        XCTAssertTrue(try typeIntoPane("tee \(marker.path)\n", pane: "left", file: marker),
                      "the main pane's `tee` should create its marker")
        XCTAssertTrue(try typeIntoPane("tee \(splitMarker.path)\n", pane: "right", file: splitMarker),
                      "the split pane's `tee` should create its marker")
        try pinRestore(mode: "set", command: touchLine(overrideMarker), pane: "right")

        try FileManager.default.removeItem(at: marker)
        try FileManager.default.removeItem(at: splitMarker)
        gracefulQuit()
        app.launchForUITest()

        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.overrideMarker.path) },
                      "the right pane's pinned override should run on restore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: splitMarker.path),
                       "the right pane's captured command must not run when its override is pinned")
        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "the main pane is unaffected: its own captured command still restores")
    }

    // a split HIDDEN at quit is not rebuilt, so its override describes a pane that no longer exists. The
    // SECOND relaunch is what proves the drop: quitting with the fresh split SHOWN would otherwise re-arm
    // the stale pin into an unrelated pane's shell.
    func testRestoreOverrideHiddenSplitDoesNotFireOnFreshSplit() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 30), "control server up")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","args":{"mode":"on"}}"#)["ok"] as? Bool, true,
                       "session.split on should succeed")
        try pinRestore(mode: "set", command: touchLine(overrideMarker), pane: "right")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","args":{"mode":"off"}}"#)["ok"] as? Bool, true,
                       "session.split off should hide the split")

        gracefulQuit()
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 30), "session restored")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertNil(try firstSessionNode()["splitRestoreCommand"],
                     "the split is gone, so its override is dropped rather than left unclearable on `tree`")

        openFreshSplit()
        RunLoop.current.run(until: Date().addingTimeInterval(3)) // give any (incorrect) fire a chance
        XCTAssertFalse(FileManager.default.fileExists(atPath: overrideMarker.path),
                       "a split opened mid-session must be a plain shell — the pinned override must not fire")

        gracefulQuit()
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 30), "session restored")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: overrideMarker.path),
                       "the dropped override must not re-arm into the fresh split on a later launch")
        XCTAssertNil(try firstSessionNode()["splitRestoreCommand"], "and it must still read back as unpinned")
    }

    // `makeSplitSurface` decides with `restoreInput` alone, so the nil-override branch needs its own
    // guard — the override tests all exercise the other one.
    func testSplitPaneRestoresCapturedCommandWithoutOverride() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 30), "control server up")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","args":{"mode":"on"}}"#)["ok"] as? Bool, true,
                       "session.split on should succeed")
        XCTAssertTrue(try typeIntoPane("tee \(splitMarker.path)\n", pane: "right", file: splitMarker),
                      "the split pane's `tee` should create its marker")

        try FileManager.default.removeItem(at: splitMarker)
        gracefulQuit()
        app.launchForUITest()

        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.splitMarker.path) },
                      "with no override pinned, the split pane re-runs its captured foreground command")
    }

    // Exiting by closing the LAST window must capture the running command like ⌘Q: the close path tears
    // surfaces down in `willClose` BEFORE the auto-quit reaches `applicationWillTerminate`, so the
    // quit-time capture alone finds no surfaces and silently dropped every running command — the
    // `willClose` capture (skipped only under `isTerminating`) is what re-runs `tee` here.
    func testWindowCloseExitCapturesRunningCommand() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        runTeeMarker()

        try FileManager.default.removeItem(at: marker)
        let windowID = try firstWindowID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.close","target":"\#(windowID)"}"#)["ok"] as? Bool,
                       true, "closing the last window begins the auto-quit exit")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15),
                      "the app must auto-quit after its last window closes — relaunching over a hung exit would fake the capture")
        app.launchForUITest()

        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.marker.path) },
                      "a close-the-window exit must capture the running `tee` and re-run it on relaunch")
    }

    // the willClose capture is scoped to the app-exit close, so closing a NON-last window persists no
    // capture at all — and a mid-process reopen comes back a plain shell (replay is clean-exit →
    // next-launch only). The override variant below can't catch this: it pins an idle pane, so nothing
    // is captured.
    func testWindowCloseCapturedCommandDoesNotReplayOnMidRunReopen() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        runTeeMarker()
        let windowID = try firstWindowID()

        XCTAssertEqual(try sendCommand(#"{"cmd":"window.new"}"#)["ok"] as? Bool, true,
                       "a second window keeps the app alive while the first is closed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.close","target":"\#(windowID)"}"#)["ok"] as? Bool, true,
                       "closing the tee-running window while another stays open is NOT the app exit")
        XCTAssertTrue(capturedForegroundCommands().isEmpty,
                      "a non-last-window close must persist no capture — its stale argv could replay via the launch fallback: \(capturedForegroundCommands())")
        try FileManager.default.removeItem(at: marker)
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.select","target":"\#(windowID)"}"#)["ok"] as? Bool, true,
                       "selecting the closed window reopens it in the same run")

        // `session-row` is app-scoped and window 2 already shows one, so waiting for the FIRST match
        // would resolve instantly against the wrong window — wait for both windows' rows instead.
        XCTAssertTrue(poll { self.app.staticTexts.matching(identifier: "session-row").count >= 2 },
                      "both windows' session rows present after the reopen")
        RunLoop.current.run(until: Date().addingTimeInterval(3)) // give any (incorrect) replay a chance to fire
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "a mid-run window reopen must come back a plain shell — the captured `tee` must not re-run")
    }

    // the all-closed exit: window 1's command is running when the window is closed mid-session (no
    // capture — not the exit), the exit is closing window 2 (captured), and the relaunch must replay
    // ONLY window 2's command. Guards two failure modes at once: window 1's stale state replaying, and
    // the reopen fallback opening windows.first (the oldest entry) instead of the pinned exit window,
    // which would silently drop window 2's replay.
    func testAllClosedExitReplaysOnlyTheExitWindowsCapture() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        runTeeMarker()
        let window1 = try firstWindowID()

        XCTAssertEqual(try sendCommand(#"{"cmd":"window.new"}"#)["ok"] as? Bool, true, "second window opens")
        XCTAssertTrue(poll { self.app.staticTexts.matching(identifier: "session-row").count >= 2 },
                      "window 2's seeded session row appears")
        XCTAssertTrue(try typeIntoPane("tee \(splitMarker.path)\n", pane: "left", file: splitMarker),
                      "window 2's `tee` should create its marker (active session is window 2's)")

        XCTAssertEqual(try sendCommand(#"{"cmd":"window.close","target":"\#(window1)"}"#)["ok"] as? Bool, true,
                       "closing window 1 mid-session is not the exit")
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.removeItem(at: splitMarker)

        let window2 = try onlyOpenWindowID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.close","target":"\#(window2)"}"#)["ok"] as? Bool, true,
                       "closing window 2 is the app exit")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "the app auto-quits after its last window closes")
        app.launchForUITest()

        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.splitMarker.path) },
                      "the exit window's captured command must replay on relaunch")
        RunLoop.current.run(until: Date().addingTimeInterval(2)) // give any (incorrect) replay a chance
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the mid-session-closed window's command must not replay")
    }

    // a window reopen reloads its store through the same `restore(from:)` the bootstrap uses, but must NOT
    // arm: that would execute every sticky override the moment a user closes and reopens a window.
    func testWindowReopenDoesNotArmTheOverride() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        try pinRestore(mode: "set", command: touchLine(overrideMarker))
        let windowID = try firstWindowID()

        XCTAssertEqual(try sendCommand(#"{"cmd":"window.new"}"#)["ok"] as? Bool, true,
                       "a second window keeps the app alive while the first is closed")
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.close","target":"\#(windowID)"}"#)["ok"] as? Bool, true,
                       "closing the pinned session's window drops its store")
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.select","target":"\#(windowID)"}"#)["ok"] as? Bool, true,
                       "selecting it again reopens the window and reloads the store")

        assertOverrideHasNotFired("a mid-process window reopen is not a launch restore, so nothing may fire")
    }

    // `terminate()` is SIGKILL — no `applicationWillTerminate`, so neither the capture nor the quit-flush
    // runs, and only `setRestoreCommand`'s eager `save()` can carry the override to the next launch.
    func testRestoreOverrideSurvivesForceQuit() throws {
        seedRestoreFlag(true)
        app.launchForUITest()
        try pinRestore(mode: "set", command: touchLine(overrideMarker))
        assertOverrideHasNotFired("the pin must not run in the live session")

        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 10)
        app.launchForUITest()

        XCTAssertTrue(poll { FileManager.default.fileExists(atPath: self.overrideMarker.path) },
                      "the override must be persisted eagerly enough to survive a force quit")
    }

    // MARK: - Helpers

    /// The shell line a pinned override runs: `touch <file>`, which EXITS. That leaves the pane at its
    /// prompt, so the next quit captures nothing and only the sticky override can recreate the file.
    private func touchLine(_ file: URL) -> String { "/usr/bin/touch \(file.path)" }

    /// Pin/clear the active session's restore-command override over the control socket, asserting the
    /// request succeeded. `mode` is `set` | `none` | `clear`; `pane` defaults to the main pane.
    @discardableResult
    private func pinRestore(mode: String, command: String? = nil, pane: String? = nil) throws -> [String: Any] {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 30), "control server up")
        var args: [String: Any] = ["mode": mode]
        if let command { args["command"] = command }
        if let pane { args["pane"] = pane }
        let obj: [String: Any] = ["cmd": "session.restore", "args": args]
        let response = try sendCommand(String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self))
        XCTAssertEqual(response["ok"] as? Bool, true, "session.restore \(mode) should succeed: \(response)")
        return response
    }

    /// Assert the pinned override has NOT run: it is written now and consumed on the NEXT launch, so it
    /// must never touch the live session. The drain gives an (incorrect) immediate fire time to land.
    private func assertOverrideHasNotFired(_ message: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: overrideMarker.path), message)
    }

    /// Open a fresh split with ⌘D, retrying until `tree` reports one. A single keystroke can be dropped
    /// while a freshly launched window settles, the same reason `runTeeMarker` retries its injection.
    private func openFreshSplit() {
        for _ in 0..<3 {
            app.typeKey("d", modifierFlags: .command)
            if poll({ self.treeReportsSplit() }, timeout: 5) { return }
        }
        XCTFail("⌘D should open a fresh split")
    }

    /// Inject `text` into `pane` of the active session, retrying until `file` appears. A freshly spawned
    /// pane's shell may not be reading yet (and a just-created split may not be realized at all), so the
    /// marker file is the readiness signal.
    private func typeIntoPane(_ text: String, pane: String, file: URL) throws -> Bool {
        let obj: [String: Any] = ["cmd": "session.type", "args": ["text": text, "pane": pane]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        for _ in 0..<5 {
            _ = try? sendCommand(line)
            if poll({ FileManager.default.fileExists(atPath: file.path) }, timeout: 4) { return true }
        }
        return false
    }

    /// The id of the single window `window.list` reports OPEN — after other windows were closed,
    /// `firstWindowID` would return the closed first entry instead.
    private func onlyOpenWindowID() throws -> String {
        let response = try sendCommand(#"{"cmd":"window.list"}"#)
        let result = try XCTUnwrap(response["result"] as? [String: Any], "window.list should carry a result")
        let windows = try XCTUnwrap(result["windows"] as? [[String: Any]], "result should list windows")
        let open = windows.filter { $0["open"] as? Bool == true }
        XCTAssertEqual(open.count, 1, "exactly one open window expected: \(windows)")
        return try XCTUnwrap(open.first?["id"] as? String)
    }

    /// The id of the only open window, for the close/reopen round trip.
    private func firstWindowID() throws -> String {
        let response = try sendCommand(#"{"cmd":"window.list"}"#)
        let result = try XCTUnwrap(response["result"] as? [String: Any], "window.list should carry a result")
        let windows = try XCTUnwrap(result["windows"] as? [[String: Any]], "result should list windows")
        return try XCTUnwrap(windows.first?["id"] as? String, "one open window")
    }

    /// Whether `tree` reports the seeded session as having a split (`splitFocused` is present only then).
    private func treeReportsSplit() -> Bool {
        guard let node = try? firstSessionNode() else { return false }
        return node["splitFocused"] != nil
    }

    /// The single seeded session's node from a `tree` response.
    private func firstSessionNode() throws -> [String: Any] {
        let response = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(response["result"] as? [String: Any], "tree should carry a result")
        let tree = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(tree["workspaces"] as? [[String: Any]], "tree should list workspaces")
        return try XCTUnwrap((workspaces.first?["sessions"] as? [[String: Any]])?.first, "one seeded session")
    }

    /// Every persisted `foregroundCommand` across the window snapshots written at quit (the capture oracle).
    private func capturedForegroundCommands() -> [[String]] {
        let windowsDir = stateDir.appendingPathComponent("windows")
        guard let files = try? FileManager.default.contentsOfDirectory(at: windowsDir, includingPropertiesForKeys: nil)
        else { return [] }
        var result: [[String]] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let workspaces = obj["workspaces"] as? [[String: Any]] else { continue }
            for ws in workspaces {
                for s in (ws["sessions"] as? [[String: Any]]) ?? [] {
                    if let fg = s["foregroundCommand"] as? [String] { result.append(fg) }
                    if let fg = s["splitForegroundCommand"] as? [String] { result.append(fg) }
                }
            }
        }
        return result
    }

    /// Seed `restoreRunningCommand` into the isolated `settings.json` before launch.
    private func seedRestoreFlag(_ on: Bool) {
        let json = #"{"restoreRunningCommand":\#(on)}"#
        try? Data(json.utf8).write(to: stateDir.appendingPathComponent("settings.json"))
    }

    /// Type `tee <marker>` into the focused terminal and confirm it created the marker (so it is the live
    /// foreground process — `tee` opens its output file on start, then blocks reading the terminal).
    /// The injection is RETRIED: a freshly realized surface's shell may not be reading yet when the first
    /// keystrokes land. ⌃U clears the line editor first so a half-typed line can't build a bogus path.
    private func runTeeMarker() {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session row")
        for attempt in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(1)) // let the shell reach its prompt
            if attempt > 0 { app.typeKey("u", modifierFlags: .control) }
            app.typeText("tee \(marker.path)\n")
            if poll({ FileManager.default.fileExists(atPath: self.marker.path) }, timeout: 6) { return }
        }
        XCTFail("the foreground `tee` should create its marker file on start (terminal must be focused)")
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

    /// Send one newline-delimited JSON request to the control socket and return the decoded response.
    private func sendCommand(_ line: String) throws -> [String: Any] {
        let fd = try connect(to: socketPath)
        defer { close(fd) }
        var payload = Data(line.utf8)
        payload.append(UInt8(ascii: "\n"))
        try writeAll(fd, payload)
        let data = readResponseLine(fd)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(obj, "response should be a JSON object, got: \(String(data: data, encoding: .utf8) ?? "<binary>")")
    }

    private func connect(to path: String) throws -> Int32 {
        guard path.utf8.count < 104 else { // sun_path limit; guard before copying, like SocketClient.connect
            throw posixError("socket path too long (\(path.utf8.count) bytes)", ENAMETOOLONG)
        }
        let deadline = Date().addingTimeInterval(15)
        var lastErrno: Int32 = 0
        repeat {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw posixError("socket", errno) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = path.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                    pathBytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
                }
            }
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return fd }
            lastErrno = errno
            close(fd)
            usleep(200_000)
        } while Date() < deadline
        throw posixError("connect(\(path))", lastErrno)
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n <= 0 { throw posixError("write", errno) }
                offset += n
            }
        }
    }

    private func readResponseLine(_ fd: Int32) -> Data {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue } // a signal interrupted the blocking read; retry
                return buffer
            }
            if n == 0 { return buffer } // EOF
            if byte == UInt8(ascii: "\n") { return buffer }
            buffer.append(byte)
        }
    }

    private func posixError(_ op: String, _ code: Int32) -> NSError {
        NSError(domain: "control-socket", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(op) failed: \(String(cString: strerror(code)))"])
    }
}
