import Darwin
import XCTest

/// End-to-end tests for the opt-in title-bar attention bell (Task 11). The bell exists only when the
/// `attentionButtonEnabled` setting is on (seeded into the isolated `settings.json` before launch), and
/// its three states (dimmed/disabled, plain enabled, filled-blocked) are derived from the window's
/// `attentionSessions`. The bell↔bell.fill highlight isn't observable, so the test reads the
/// `accessibilityValue` (none|attention|blocked) the button exposes (mirroring `StatusIconView`). Status
/// is driven over the control socket (spoken directly, like `ControlAPIUITests`) via `session.status`.
@MainActor
final class AttentionButtonUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var socketPath: String!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-attnuitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        // the runner's own temp dir keeps the socket path under the sun_path ~104-byte limit and inside
        // the sandbox grant (the per-test AGTERM_STATE_DIR subdir is too long; /tmp is outside the grant).
        socketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("agtermc-\(UUID().uuidString.prefix(8)).sock")
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
    }

    // with the toggle on, the bell tracks the window's attention state: idle → disabled "none", a
    // non-blocked status → enabled "attention", a blocked status → enabled "blocked", back to idle →
    // disabled "none". The accessibilityValue is the oracle for the otherwise-unobservable highlight.
    func testAttentionButtonStatesTrackSessionStatus() throws {
        launch(attentionEnabled: true)
        let seeded = try seededSessionID()

        let bell = app.buttons["attention-button"]
        XCTAssertTrue(bell.waitForExistence(timeout: 10), "the attention bell should exist with the toggle on")
        // all sessions idle at launch: the bell is dimmed/disabled and reports "none".
        XCTAssertTrue(pollButton(bell, value: "none", enabled: false), "an all-idle window should disable the bell as none")

        try setStatus("active", target: seeded)
        XCTAssertTrue(pollButton(bell, value: "attention", enabled: true),
                      "a non-blocked attention session should enable the bell as attention")

        try setStatus("completed", target: seeded)
        XCTAssertTrue(pollButton(bell, value: "attention", enabled: true),
                      "a completed (non-blocked) attention session should keep the bell enabled as attention")

        try setStatus("blocked", target: seeded)
        XCTAssertTrue(pollButton(bell, value: "blocked", enabled: true),
                      "a blocked session should mark the bell blocked")

        try setStatus("idle", target: seeded)
        XCTAssertTrue(pollButton(bell, value: "none", enabled: false),
                      "clearing the last attention session should disable the bell back to none")
    }

    // clicking the bell opens the attention command palette; choosing its only row (the blocked session)
    // selects that session — proving the click drives `toggleAttentionPalette` and the row drives select.
    func testAttentionButtonOpensPaletteAndSelectsSession() throws {
        launch(attentionEnabled: true)
        let seeded = try seededSessionID()

        // flag the seeded session, then add a SECOND session — `session.new` selects the new (idle) one,
        // so the seeded blocked session is NOT the active one. The bell still lists it (window-wide).
        try setStatus("blocked", target: seeded)
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let createdResult = try XCTUnwrap(created["result"] as? [String: Any], "session.new should carry a result")
        let secondID = try XCTUnwrap(createdResult["id"] as? String, "session.new should return the new id")
        XCTAssertTrue(pollSelectedSessionID(secondID), "the new session should be selected after add")

        let bell = app.buttons["attention-button"]
        XCTAssertTrue(pollButton(bell, value: "blocked", enabled: true), "the bell should mark the blocked seeded session")
        bell.click()

        let palette = app.descendants(matching: .any).matching(identifier: "command-palette").firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "clicking the bell should open the command palette")

        // the panel enters the AX tree before its field grabs first responder, and a button-open settles
        // focus a beat slower than a menu-open — so a single Return can land before the field is
        // keyboard-ready and do nothing. re-send Return each tick until the seeded (only attention) row's
        // session is selected, so the test is deterministic rather than racing a fixed delay.
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the attention palette field should appear")
        XCTAssertTrue(pollReturnSelects(seeded), "choosing the attention row should select that session")
    }

    // with the toggle off (the default — no seeded setting), the bell is absent from the title bar.
    func testAttentionButtonAbsentWhenToggleOff() throws {
        launch(attentionEnabled: false)
        // the sidebar toggle proves the custom title bar rendered, so the bell's absence is real, not a
        // not-yet-laid-out race.
        XCTAssertTrue(app.buttons["sidebar-toggle-button"].waitForExistence(timeout: 10), "the title bar should render")
        XCTAssertFalse(app.buttons["attention-button"].exists, "the bell should be absent with the toggle off")
    }

    // flipping the Settings toggle at runtime shows/hides the bell live (the .agtermAppearanceChanged
    // refresh path) without a relaunch — every other test seeds settings.json before launch. launch
    // WITHOUT the toggle (bell absent), open Settings (Cmd+,), flip the toggle on (bell appears), flip it
    // back off (bell hides).
    func testAttentionButtonTogglesLiveFromSettings() throws {
        launch(attentionEnabled: false)
        XCTAssertTrue(app.buttons["sidebar-toggle-button"].waitForExistence(timeout: 10), "the title bar should render")
        let bell = app.buttons["attention-button"]
        XCTAssertFalse(bell.exists, "the bell should be absent before the toggle is flipped on")

        let toggle = settingsControl(tab: "Notifications", control: "settings-attention-button")
        toggle.click() // turn it on (default off)
        XCTAssertTrue(bell.waitForExistence(timeout: 10), "flipping the toggle on should show the bell live")

        toggle.click() // turn it back off
        XCTAssertTrue(pollAbsent(bell), "flipping the toggle back off should hide the bell live")
    }

    // MARK: - Launch + seeding

    private func launch(attentionEnabled: Bool) {
        if attentionEnabled { seedSettings(["attentionButtonEnabled": true]) }
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchEnvironment["AGTERM_CONTROL_SOCKET"] = socketPath
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 30), "seeded session should exist")
    }

    /// Writes `settings.json` into the isolated state dir BEFORE launch, so `SettingsModel.init` applies
    /// it (and `GhosttyApp.attentionButtonEnabled` is true) by the time the title bar first renders.
    private func seedSettings(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        try! data.write(to: stateDir.appendingPathComponent("settings.json"))
    }

    // MARK: - Assertions / polling

    /// Polls until the button reports `value` AND `enabled` (both XCUITest snapshots refresh per read),
    /// covering the live observation lag after a status change rides the control socket.
    private func pollButton(_ button: XCUIElement, value: String, enabled: Bool, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if button.exists, (button.value as? String) == value, button.isEnabled == enabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func pollSelectedSessionID(_ expected: String, timeout: TimeInterval = 8) -> Bool {
        stateDir.pollSnapshot(equals: expected.lowercased(), timeout: timeout) { obj in
            (obj["selectedSessionID"] as? String)?.lowercased()
        }
    }

    /// Re-sends Return each tick (the only attention row is the blocked seeded session, so Return on the
    /// top match selects it) until the snapshot reports `expected` selected, bounded by `timeout`. A
    /// button-opened palette settles field focus a beat slower than a menu-open, so a single keypress can
    /// race the focus and no-op; re-sending until the selection lands makes the assertion deterministic.
    private func pollReturnSelects(_ expected: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            app.typeKey(.return, modifierFlags: [])
            if pollSelectedSessionID(expected, timeout: 0.4) { return true }
        }
        return false
    }

    /// Polls until the element is gone from the AX tree (the bell after the toggle is flipped off), or the
    /// timeout elapses.
    private func pollAbsent(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    /// Opens the Settings window (Cmd+,) if needed, switches to `tab`, and returns the control with
    /// `control` id once it is hittable — RETRYING the tab click each tick (mirrors SettingsUITests). A
    /// stale/half-open Settings window can silently drop the first tab click, so retry until the control
    /// is actually hittable.
    @discardableResult
    private func settingsControl(tab: String, control: String, timeout: TimeInterval = 12,
                                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = app.descendants(matching: .any).matching(identifier: control).firstMatch
        let tabButton = app.buttons[tab].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.exists, target.isHittable { return target }
            if tabButton.exists, tabButton.isHittable {
                tabButton.click()
            } else {
                app.typeKey(",", modifierFlags: .command) // settings not open yet (or lost) — (re)open
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("Settings '\(tab)' control '\(control)' never became hittable", file: file, line: line)
        return target
    }

    /// The seeded (first) session's id from a `tree` response.
    private func seededSessionID() throws -> String {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let root = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let workspaces = try XCTUnwrap(root["workspaces"] as? [[String: Any]], "tree should list workspaces")
        let sessions = try XCTUnwrap(workspaces.first?["sessions"] as? [[String: Any]], "workspace should list sessions")
        return try XCTUnwrap(sessions.first?["id"] as? String, "should have a seeded session id")
    }

    @discardableResult
    private func setStatus(_ status: String, target: String) throws -> [String: Any] {
        let resp = try sendCommand(#"{"cmd":"session.status","target":"\#(target)","args":{"status":"\#(status)"}}"#)
        XCTAssertEqual(resp["ok"] as? Bool, true, "session.status \(status) should succeed: \(resp)")
        return resp
    }

    // MARK: - Control socket (spoken directly, like ControlAPIUITests)

    private func sendCommand(_ line: String) throws -> [String: Any] {
        let fd = try connect(to: socketPath)
        defer { close(fd) }
        var payload = Data(line.utf8)
        payload.append(UInt8(ascii: "\n"))
        try writeAll(fd, payload)
        let data = readResponse(fd)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(obj, "response should be a JSON object, got: \(String(data: data, encoding: .utf8) ?? "<binary>")")
    }

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
                    pathBytes.withUnsafeBufferPointer { src in
                        buf.update(from: src.baseAddress!, count: src.count)
                    }
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
    private func readResponse(_ fd: Int32) -> Data {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue }
                return buffer
            }
            if n == 0 { return buffer }
            if byte == UInt8(ascii: "\n") { return buffer }
            buffer.append(byte)
        }
    }

    private func posixError(_ op: String, _ code: Int32) -> NSError {
        NSError(domain: "control-socket", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(op) failed: \(String(cString: strerror(code)))"])
    }
}
