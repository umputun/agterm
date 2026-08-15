import Darwin
import XCTest

/// End-to-end tests for the multi-window scene: seed `AGTERM_STATE_DIR` with a `windows.json` index +
/// per-window snapshot files, launch the real app, and assert on two oracles — the live window count
/// (`app.windows`) and the persisted index.
///
/// Per-window sidebar content isn't asserted across BOTH windows — the test-only force-sidebar fixup
/// reliably expands only the key window's sidebar — so per-window-store resolution is proven by one
/// seeded workspace rendering plus the two-window count.
///
/// The seed is raw JSON (the UI-test target doesn't link `agtermCore`) matching the `WindowsIndex` and
/// `Snapshot` Codable shapes.
@MainActor
final class MultiWindowUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    /// The control socket the app binds. Kept under NSTemporaryDirectory so it fits `sun_path`'s
    /// ~104-byte limit, like `ControlAPIUITests`.
    private var socketPath: String!
    /// A temp dir the spawned shell writes env-probe marker files into, short-pathed like the socket.
    private var markerDir: URL!
    private var windowAID = UUID()
    private var windowBID = UUID()
    /// The selected session id seeded per window by `seedTwoWindowsWithSelection`.
    private var selectedByWindow: [UUID: UUID] = [:]
    /// The single session id seeded per window by `seedTwoWindowsWithKnownSessions`, used by the
    /// distinct-store test to target each window's own session over the control socket.
    private var sessionByWindow: [UUID: UUID] = [:]

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-multiwin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        socketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("agtermm-\(UUID().uuidString.prefix(8)).sock")
        markerDir = URL(fileURLWithPath: (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("agtermm-mark-\(UUID().uuidString.prefix(8))"), isDirectory: true)
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
        if let markerDir { try? FileManager.default.removeItem(at: markerDir) }
    }

    // MARK: - Seeding

    /// Writes `windows/<id>.json` (a `Snapshot`) with one workspace (named `workspaceName`) holding
    /// one session.
    private func writeWindowFile(_ id: UUID, workspaceName: String) throws {
        let windowsDir = stateDir.appendingPathComponent("windows", isDirectory: true)
        try FileManager.default.createDirectory(at: windowsDir, withIntermediateDirectories: true)
        let snapshot: [String: Any] = [
            "version": 1,
            "selectedSessionID": UUID().uuidString,
            "workspaces": [[
                "id": UUID().uuidString,
                "name": workspaceName,
                "sessions": [[
                    "id": UUID().uuidString,
                    "customName": "\(workspaceName)-session",
                    "cwd": NSHomeDirectory(),
                ]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        try data.write(to: windowsDir.appendingPathComponent("\(id.uuidString).json"))
    }

    /// Writes `windows.json` marking both seeded windows open, frontmost = window A.
    private func writeIndex() throws {
        let index: [String: Any] = [
            "version": 1,
            "frontmost": windowAID.uuidString,
            "windows": [
                ["id": windowAID.uuidString, "name": "win-a", "isOpen": true],
                ["id": windowBID.uuidString, "name": "win-b", "isOpen": true],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: index)
        try data.write(to: stateDir.appendingPathComponent("windows.json"))
    }

    private func seedTwoWindows() throws {
        try writeWindowFile(windowAID, workspaceName: "alpha-ws")
        try writeWindowFile(windowBID, workspaceName: "beta-ws")
        try writeIndex()
    }

    /// Writes `windows/<id>.json` with one workspace holding one session whose id is KNOWN (recorded
    /// in `sessionByWindow`), so the distinct-store test can target each window's own session by id
    /// over the control socket and inject into it.
    private func writeWindowFileWithKnownSession(_ id: UUID, workspaceName: String) throws {
        let windowsDir = stateDir.appendingPathComponent("windows", isDirectory: true)
        try FileManager.default.createDirectory(at: windowsDir, withIntermediateDirectories: true)
        let session = UUID()
        sessionByWindow[id] = session
        let snapshot: [String: Any] = [
            "version": 1,
            "selectedSessionID": session.uuidString,
            "workspaces": [[
                "id": UUID().uuidString,
                "name": workspaceName,
                "sessions": [[
                    "id": session.uuidString,
                    "customName": "\(workspaceName)-session",
                    "cwd": NSHomeDirectory(),
                ]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        try data.write(to: windowsDir.appendingPathComponent("\(id.uuidString).json"))
    }

    /// Seeds two windows (each with a known single session id) + the index marking both open.
    private func seedTwoWindowsWithKnownSessions() throws {
        try writeWindowFileWithKnownSession(windowAID, workspaceName: "alpha-ws")
        try writeWindowFileWithKnownSession(windowBID, workspaceName: "beta-ws")
        try writeIndex()
    }

    /// Writes `windows/<id>.json` with TWO sessions in one workspace, selecting the SECOND, and records the
    /// selected id in `selectedByWindow` so the reopen-all test can assert selection survives a relaunch.
    private func writeWindowFileWithSelection(_ id: UUID, workspaceName: String) throws {
        let windowsDir = stateDir.appendingPathComponent("windows", isDirectory: true)
        try FileManager.default.createDirectory(at: windowsDir, withIntermediateDirectories: true)
        let firstSession = UUID()
        let selected = UUID()
        selectedByWindow[id] = selected
        let snapshot: [String: Any] = [
            "version": 1,
            "selectedSessionID": selected.uuidString,
            "workspaces": [[
                "id": UUID().uuidString,
                "name": workspaceName,
                "sessions": [
                    ["id": firstSession.uuidString, "customName": "\(workspaceName)-first", "cwd": NSHomeDirectory()],
                    ["id": selected.uuidString, "customName": "\(workspaceName)-selected", "cwd": NSHomeDirectory()],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        try data.write(to: windowsDir.appendingPathComponent("\(id.uuidString).json"))
    }

    /// Seeds two windows (each with a known selected second session) + the index marking both open.
    private func seedTwoWindowsWithSelection() throws {
        try writeWindowFileWithSelection(windowAID, workspaceName: "alpha-ws")
        try writeWindowFileWithSelection(windowBID, workspaceName: "beta-ws")
        try writeIndex()
    }

    /// Reads `selectedSessionID` from a window's per-window snapshot file, or nil if absent.
    private func windowSelectedSessionID(_ id: UUID) -> UUID? {
        let file = stateDir.appendingPathComponent("windows", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let str = obj["selectedSessionID"] as? String else { return nil }
        return UUID(uuidString: str)
    }

    /// Writes a single-window index (window A only, open + frontmost) and its per-window file. Used by
    /// the File-menu window-action tests, which need a known one-window baseline.
    private func seedOneWindow() throws {
        try writeWindowFile(windowAID, workspaceName: "alpha-ws")
        let index: [String: Any] = [
            "version": 1,
            "frontmost": windowAID.uuidString,
            "windows": [["id": windowAID.uuidString, "name": "win-a", "isOpen": true]],
        ]
        let data = try JSONSerialization.data(withJSONObject: index)
        try data.write(to: stateDir.appendingPathComponent("windows.json"))
    }

    /// The window entries (id, name, isOpen) from `windows.json`, in file order.
    private func indexWindows() -> [(id: UUID, name: String, isOpen: Bool)]? {
        let file = stateDir.appendingPathComponent("windows.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = obj["windows"] as? [[String: Any]] else { return nil }
        return windows.compactMap { entry in
            guard let idStr = entry["id"] as? String, let id = UUID(uuidString: idStr),
                  let name = entry["name"] as? String else { return nil }
            return (id, name, (entry["isOpen"] as? Bool) ?? false)
        }
    }

    /// Polls `windows.json` until `predicate` holds over its window entries.
    private func pollIndexWindows(timeout: TimeInterval, _ predicate: ([(id: UUID, name: String, isOpen: Bool)]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let windows = indexWindows(), predicate(windows) { return true }
            usleep(200_000)
        }
        return false
    }

    private func launch() {
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchEnvironment["AGTERM_CONTROL_SOCKET"] = socketPath
        app.launchForUITest()
    }

    /// Simulate a quit/relaunch cycle: terminate the running app and relaunch against the SAME state dir
    /// + socket, so the persisted open-set + per-window selection drive the relaunch reopen.
    private func relaunch() {
        app?.terminate()
        launch()
    }

    // MARK: - Oracles

    /// Reads the open-state map (window id → open flag) from `windows.json`.
    private func indexOpenState() -> [UUID: Bool]? {
        let file = stateDir.appendingPathComponent("windows.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = obj["windows"] as? [[String: Any]] else { return nil }
        var actual: [UUID: Bool] = [:]
        for entry in windows {
            if let idStr = entry["id"] as? String, let id = UUID(uuidString: idStr) {
                actual[id] = (entry["isOpen"] as? Bool) ?? false
            }
        }
        return actual
    }

    /// Polls `windows.json` until its open-state map equals `expected`.
    private func pollIndexOpenState(_ expected: [UUID: Bool], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if indexOpenState() == expected { return true }
            usleep(200_000)
        }
        return false
    }

    /// Polls until the app exposes at least `count` windows. `app.windows` can briefly include
    /// transient/auxiliary windows, so the index file is the authoritative open-set oracle; this is a
    /// liveness check that windows actually materialized.
    private func pollWindowCount(atLeast count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count >= count { return true }
            usleep(200_000)
        }
        return false
    }

    // MARK: - Tests

    // the distinct-store probe is the load-bearing assertion: under a duplicate-store collision both
    // on-screen windows bind one store, so the un-rendered window's session never realizes and its probe
    // never writes. The index open-flags alone would not catch that.
    func testReopensTwoSeededWindows() throws {
        try seedTwoWindowsWithKnownSessions()
        launch()

        // the OR is fine here — the distinct-store assertion below is what proves the stores differ.
        let alpha = app.staticTexts["alpha-ws"]
        let beta = app.staticTexts["beta-ws"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 30) || beta.waitForExistence(timeout: 30),
                      "a seeded window's workspace should render")

        XCTAssertTrue(pollWindowCount(atLeast: 2, timeout: 10), "two windows should open, got \(app.windows.count)")
        XCTAssertTrue(pollIndexOpenState([windowAID: true, windowBID: true], timeout: 10),
                      "both seeded windows should be marked open in windows.json")

        let aSession = try XCTUnwrap(sessionByWindow[windowAID], "window A's seeded session id")
        let bSession = try XCTUnwrap(sessionByWindow[windowBID], "window B's seeded session id")
        let aValue = try readWindowEnv(windowID: windowAID, sessionID: aSession, fileName: "win-a-env")
        let bValue = try readWindowEnv(windowID: windowBID, sessionID: bSession, fileName: "win-b-env")
        XCTAssertEqual(aValue, windowAID.uuidString.lowercased(),
                       "window A's session should see AGTERM_WINDOW_ID == window A's id")
        XCTAssertEqual(bValue, windowBID.uuidString.lowercased(),
                       "window B's session should see AGTERM_WINDOW_ID == window B's id")
        XCTAssertNotEqual(aValue, bValue,
                          "the two windows must bind DISTINCT stores — identical ids would mean one shared store")
    }

    /// Type `echo "$AGTERM_WINDOW_ID" > <file>` into the given window's session (targeting it by id and
    /// scoping to its window, `select:true` to realize a never-shown surface), then read the written
    /// value back, lowercased. The window/session scoping routes the inject to the owning store, so a
    /// shared-store collision shows up as the un-rendered window's session never realizing (no write).
    private func readWindowEnv(windowID: UUID, sessionID: UUID, fileName: String) throws -> String {
        // surfaces realize only when their detail pane is shown, so raise the window before injecting.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.select","target":"\#(windowID.uuidString)"}"#)["ok"] as? Bool, true,
                       "selecting window \(windowID) should succeed")
        let file = markerDir.appendingPathComponent(fileName)
        let cmd = "echo \"$AGTERM_WINDOW_ID\" > '\(file.path)'\n"
        let value = try XCTUnwrap(try typeUntilMarker(cmd, target: sessionID.uuidString, file: file, window: windowID.uuidString),
                                  "the env probe for window \(windowID) should write a value")
        return value.lowercased()
    }

    func testReopenAllAfterSimulatedQuitRestoresOpenSetAndSelection() throws {
        try seedTwoWindowsWithSelection()
        let expectedSelection = selectedByWindow

        launch()

        let alpha = app.staticTexts["alpha-ws"]
        let beta = app.staticTexts["beta-ws"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 30) || beta.waitForExistence(timeout: 30),
                      "a seeded window's workspace should render after launch")
        XCTAssertTrue(pollWindowCount(atLeast: 2, timeout: 10), "two windows should open, got \(app.windows.count)")
        XCTAssertTrue(pollIndexOpenState([windowAID: true, windowBID: true], timeout: 10),
                      "both seeded windows should be open after the first launch")
        XCTAssertEqual(windowSelectedSessionID(windowAID), expectedSelection[windowAID],
                       "window A's seeded selection should be intact after launch")
        XCTAssertEqual(windowSelectedSessionID(windowBID), expectedSelection[windowBID],
                       "window B's seeded selection should be intact after launch")

        relaunch()

        XCTAssertTrue(app.staticTexts["alpha-ws"].waitForExistence(timeout: 30)
                      || app.staticTexts["beta-ws"].waitForExistence(timeout: 30),
                      "a seeded window should render after the simulated quit/relaunch")
        XCTAssertTrue(pollWindowCount(atLeast: 2, timeout: 10),
                      "both windows should reopen after the simulated quit, got \(app.windows.count)")
        XCTAssertTrue(pollIndexOpenState([windowAID: true, windowBID: true], timeout: 10),
                      "both windows should be marked open again after the simulated quit/relaunch")
        XCTAssertEqual(windowSelectedSessionID(windowAID), expectedSelection[windowAID],
                       "window A's selected session should survive the simulated quit/relaunch")
        XCTAssertEqual(windowSelectedSessionID(windowBID), expectedSelection[windowBID],
                       "window B's selected session should survive the simulated quit/relaunch")
    }

    /// Clicks a button labelled `label` in a confirmation sheet/dialog (the close-confirm alert),
    /// searching sheets, then dialogs, then any matching button. Returns whether it was clicked.
    private func clickConfirmButton(_ label: String, timeout: TimeInterval) -> Bool {
        let sheetButton = app.sheets.buttons[label].firstMatch
        if sheetButton.waitForExistence(timeout: timeout) { sheetButton.click(); return true }
        let dialogButton = app.dialogs.buttons[label].firstMatch
        if dialogButton.waitForExistence(timeout: 2) { dialogButton.click(); return true }
        let anyButton = app.buttons[label].firstMatch
        if anyButton.waitForExistence(timeout: 2) { anyButton.click(); return true }
        return false
    }

    func testClosingOneWindowRemovesIt() throws {
        try seedTwoWindows()
        launch()

        let alpha = app.staticTexts["alpha-ws"]
        let beta = app.staticTexts["beta-ws"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 30) || beta.waitForExistence(timeout: 30),
                      "a seeded window should render")
        XCTAssertTrue(pollIndexOpenState([windowAID: true, windowBID: true], timeout: 10),
                      "both windows should start open")

        // targeting by title matters: SwiftUI restores an extra empty stray window from its OWN
        // restoration state (NSUserDefaults, not isolated by AGTERM_STATE_DIR), and it can sit frontmost,
        // so a generic firstMatch / File-menu Close hits THAT window instead of a seeded one.
        let target = app.windows.matching(NSPredicate(format: "title CONTAINS %@", "win-a")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "seeded window win-a should be on screen")
        target.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(clickConfirmButton("Close", timeout: 10), "a close-confirmation sheet should appear; clicking Close proceeds")

        // the close path can lag under load, so the settle is generous; the index is the readiness signal.
        let deadline = Date().addingTimeInterval(30)
        var settled = false
        while Date() < deadline {
            if let state = indexOpenState(), state[windowAID] == false, state[windowBID] == true {
                settled = true
                break
            }
            usleep(200_000)
        }
        XCTAssertTrue(settled, "win-a should be marked closed and win-b open, got \(String(describing: indexOpenState()))")
    }

    /// One panel for the whole app, not one per window: showing it with two windows open yields a single
    /// surface, and it stays up and addressable when the other window becomes frontmost — the contract that
    /// replaced the per-window registry.
    func testQuickTerminalIsOnePanelForTheApp() throws {
        try seedTwoWindows()
        launch()

        let alpha = app.staticTexts["alpha-ws"]
        let beta = app.staticTexts["beta-ws"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 30) || beta.waitForExistence(timeout: 30),
                      "a seeded window should render")
        XCTAssertTrue(pollWindowCount(atLeast: 2, timeout: 10), "two windows should open, got \(app.windows.count)")

        let quick = app.descendants(matching: .any).matching(identifier: "quick-terminal")
        XCTAssertEqual(quick.count, 0, "no quick terminal should be visible before showing one")

        let shown = try sendCommand(#"{"cmd":"quick","args":{"mode":"show"}}"#)
        XCTAssertEqual(shown["ok"] as? Bool, true, "quick show should succeed: \(shown)")
        XCTAssertTrue(quick.firstMatch.waitForExistence(timeout: 10), "the quick-terminal panel should appear")
        XCTAssertEqual(quick.count, 1, "one panel for the whole app, got \(quick.count)")

        // the panel belongs to no window, so selecting the other one neither hides it nor mints a second.
        for id in [windowBID, windowAID] {
            let selected = try sendCommand(#"{"cmd":"window.select","args":{"target":"\#(id.uuidString)"}}"#)
            XCTAssertEqual(selected["ok"] as? Bool, true, "window.select should succeed: \(selected)")
            XCTAssertEqual(quick.count, 1, "the panel should survive a frontmost change, got \(quick.count)")
        }

        let hidden = try sendCommand(#"{"cmd":"quick","args":{"mode":"hide"}}"#)
        XCTAssertEqual(hidden["ok"] as? Bool, true, "quick hide should succeed: \(hidden)")
        XCTAssertTrue(waitForCount(quick, equals: 0, timeout: 10), "the quick terminal should hide")
    }

    // the session is created over the socket so its surface realizes AFTER the bind, which is what
    // populates AGTERM_SOCKET in the spawned shell's env.
    func testSpawnedShellSeesWindowAndSessionEnv() throws {
        try seedTwoWindows()
        launch()

        let alpha = app.staticTexts["alpha-ws"]
        let beta = app.staticTexts["beta-ws"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 30) || beta.waitForExistence(timeout: 30),
                      "a seeded window should render")
        XCTAssertTrue(pollWindowCount(atLeast: 2, timeout: 10), "two windows should open, got \(app.windows.count)")
        XCTAssertTrue(pollIndexOpenState([windowAID: true, windowBID: true], timeout: 10), "both windows should be open")

        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let result = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let newSessionID = try XCTUnwrap(result["id"] as? String, "session.new should return the new id")

        let frontmost = try XCTUnwrap(pollIndexFrontmost(timeout: 10), "windows.json should record a frontmost id")

        let windowFile = markerDir.appendingPathComponent("window-id")
        let windowCmd = "echo \"$AGTERM_WINDOW_ID\" > '\(windowFile.path)'\n"
        let readWindowID = try XCTUnwrap(try typeUntilMarker(windowCmd, target: newSessionID, file: windowFile),
                                         "the window-id probe should write the env value")
        XCTAssertEqual(readWindowID.lowercased(), frontmost.lowercased(),
                       "AGTERM_WINDOW_ID should equal the owning (frontmost) window's id")

        let sessionFile = markerDir.appendingPathComponent("session-id")
        let sessionCmd = "echo \"$AGTERM_SESSION_ID\" > '\(sessionFile.path)'\n"
        let readSessionID = try XCTUnwrap(try typeUntilMarker(sessionCmd, target: newSessionID, file: sessionFile),
                                          "the session-id probe should write the env value")
        XCTAssertEqual(readSessionID.lowercased(), newSessionID.lowercased(),
                       "AGTERM_SESSION_ID should equal the spawning session's id")
    }

    func testSessionEnvBindsToOwningWindowB() throws {
        try seedTwoWindows()
        launch()

        let alpha = app.staticTexts["alpha-ws"]
        let beta = app.staticTexts["beta-ws"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 30) || beta.waitForExistence(timeout: 30), "a seeded window should render")
        XCTAssertTrue(pollWindowCount(atLeast: 2, timeout: 10), "two windows should open, got \(app.windows.count)")
        XCTAssertTrue(pollIndexOpenState([windowAID: true, windowBID: true], timeout: 10), "both windows should be open")

        // surfaces are lazy — they realize only when displayed, so window B has to be raised first.
        XCTAssertEqual(try sendCommand(#"{"cmd":"window.select","target":"\#(windowBID.uuidString)"}"#)["ok"] as? Bool, true,
                       "selecting window B should succeed")

        let created = try sendCommand(#"{"cmd":"session.new","args":{"window":"\#(windowBID.uuidString)"}}"#)
        let newSessionID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                                         "session.new --window B should return the new id")
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.select","target":"\#(newSessionID)","args":{"window":"\#(windowBID.uuidString)"}}"#)["ok"] as? Bool,
                       true, "selecting the new B-session should succeed")

        let windowFile = markerDir.appendingPathComponent("window-b-id")
        let windowCmd = "echo \"$AGTERM_WINDOW_ID\" > '\(windowFile.path)'\n"
        let readWindowID = try XCTUnwrap(try typeUntilMarker(windowCmd, target: newSessionID, file: windowFile),
                                         "the window-id probe should write the env value")
        XCTAssertEqual(readWindowID.lowercased(), windowBID.uuidString.lowercased(),
                       "AGTERM_WINDOW_ID should equal window B's id, not the frontmost-at-launch window A")
    }

    // MARK: - File-menu window actions (Task 9)

    func testNewWindowMenuOpensSecondWindow() throws {
        try seedOneWindow()
        launch()

        XCTAssertTrue(app.staticTexts["alpha-ws"].waitForExistence(timeout: 30), "the seeded window should render")
        XCTAssertTrue(pollIndexWindows(timeout: 10) { $0.count == 1 && $0[0].isOpen }, "exactly one open window to start")

        app.menuBars.menuBarItems["File"].click()
        let item = app.menuItems["New Window"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "File menu should offer New Window")
        item.click()

        XCTAssertTrue(pollWindowCount(atLeast: 2, timeout: 10), "a second window should open, got \(app.windows.count)")
        XCTAssertTrue(pollIndexWindows(timeout: 10) { $0.count == 2 && $0.filter(\.isOpen).count == 2 },
                      "the index should record two open windows, got \(String(describing: indexWindows()))")
    }

    func testDeleteWindowMenuDisabledForLastWindow() throws {
        try seedOneWindow()
        launch()

        XCTAssertTrue(app.staticTexts["alpha-ws"].waitForExistence(timeout: 30), "the seeded window should render")

        app.menuBars.menuBarItems["File"].click()
        let item = app.menuItems["Delete Window"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "File menu should offer Delete Window")
        XCTAssertFalse(item.isEnabled, "Delete Window should be disabled with only one window")
    }

    func testDeleteWindowMenuRemovesExtraWindow() throws {
        try seedOneWindow()
        launch()

        XCTAssertTrue(app.staticTexts["alpha-ws"].waitForExistence(timeout: 30), "the seeded window should render")
        XCTAssertTrue(pollIndexWindows(timeout: 10) { $0.count == 1 }, "one window to start")

        app.menuBars.menuBarItems["File"].click()
        app.menuItems["New Window"].click()
        XCTAssertTrue(pollIndexWindows(timeout: 10) { $0.count == 2 }, "two windows after New Window")

        // the just-created window is frontmost and has a session, so the delete confirm fires.
        app.menuBars.menuBarItems["File"].click()
        let delete = app.menuItems["Delete Window"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "File menu should offer Delete Window")
        XCTAssertTrue(delete.isEnabled, "Delete Window should be enabled with two windows")
        delete.click()

        let confirm = app.dialogs.buttons["Delete"].firstMatch
        if confirm.waitForExistence(timeout: 5) {
            confirm.click()
        } else {
            let fallback = app.buttons["Delete"].firstMatch
            XCTAssertTrue(fallback.waitForExistence(timeout: 5), "the delete confirm should appear")
            fallback.click()
        }

        XCTAssertTrue(pollIndexWindows(timeout: 10) { $0.count == 1 },
                      "deleting the extra window should leave one, got \(String(describing: indexWindows()))")
    }

    // the File-menu rename alert is system UI XCUITest can't drive, so this verifies the control path.
    func testRenameWindowViaControlUpdatesIndex() throws {
        try seedOneWindow()
        launch()

        XCTAssertTrue(app.staticTexts["alpha-ws"].waitForExistence(timeout: 30), "the seeded window should render")
        XCTAssertTrue(pollIndexWindows(timeout: 10) { $0.count == 1 && $0[0].name == "win-a" }, "the window starts named win-a")

        let renamed = try sendCommand(#"{"cmd":"window.rename","args":{"name":"renamed-win"}}"#)
        XCTAssertEqual(renamed["ok"] as? Bool, true, "window.rename should succeed: \(renamed)")

        XCTAssertTrue(pollIndexWindows(timeout: 10) { $0.contains { $0.id == self.windowAID && $0.name == "renamed-win" } },
                      "the index entry should carry the new name, got \(String(describing: indexWindows()))")
    }

    /// Reads the `frontmost` window id from `windows.json`, polling until it appears.
    private func pollIndexFrontmost(timeout: TimeInterval) -> String? {
        let file = stateDir.appendingPathComponent("windows.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let frontmost = obj["frontmost"] as? String {
                return frontmost
            }
            usleep(200_000)
        }
        return nil
    }

    /// Build a `session.type` request line with JSON-escaped `text` (covers the newline and quoted
    /// path). When `window` is set it scopes the inject to that window's store (cross-window targeting).
    private func typeRequest(text: String, target: String, select: Bool, window: String? = nil) -> String {
        var args: [String: Any] = ["text": text, "select": select]
        if let window { args["window"] = window }
        let obj: [String: Any] = ["cmd": "session.type", "target": target, "args": args]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    /// Polls `file` until its (trimmed) contents are non-empty, returning them, or nil on timeout.
    private func pollMarker(_ file: URL, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOf: file, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            usleep(150_000)
        }
        return nil
    }

    /// Type a `session.type` command at `file` and wait for the shell to write it back, retrying the
    /// inject if the marker hasn't appeared yet. A freshly-realized surface's shell/pty may not be ready
    /// to read when the first keystrokes land (especially under full-suite CPU load), so a single
    /// injection can be dropped; the non-empty marker file is the readiness signal. Returns the marker
    /// contents, or nil if it never appeared across all attempts.
    private func typeUntilMarker(_ command: String, target: String, file: URL, window: String? = nil,
                                 attempts: Int = 4, perAttempt: TimeInterval = 4) throws -> String? {
        for attempt in 0..<attempts {
            // a prior attempt's late injection must not be read as this attempt's success.
            try? FileManager.default.removeItem(at: file)
            // select:true so the first attempt realizes a never-shown surface.
            let typed = try sendCommand(typeRequest(text: command, target: target, select: true, window: window))
            XCTAssertEqual(typed["ok"] as? Bool, true, "typing the probe (attempt \(attempt)) should succeed: \(typed)")
            if let value = pollMarker(file, timeout: perAttempt) { return value }
        }
        return nil
    }

    /// Polls until `query` resolves to exactly `count` elements, returning true if it settles within `timeout`.
    private func waitForCount(_ query: XCUIElementQuery, equals count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if query.count == count { return true }
            usleep(150_000)
        }
        return query.count == count
    }

    // MARK: - Socket client

    /// Connect to the app's control socket, send `line`, read the single response line, parse as JSON.
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

    /// Open a unix-domain stream socket and connect to `path`, retrying while the server finishes binding.
    private func connect(to path: String) throws -> Int32 {
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

    /// Read bytes up to the first newline (exclusive), or to EOF.
    private func readResponseLine(_ fd: Int32) -> Data {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return buffer }
            if byte == UInt8(ascii: "\n") { return buffer }
            buffer.append(byte)
        }
    }

    private func posixError(_ op: String, _ code: Int32) -> NSError {
        NSError(domain: "control-socket", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(op) failed: \(String(cString: strerror(code)))"])
    }
}
