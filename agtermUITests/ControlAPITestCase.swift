import AppKit
import Darwin
import XCTest

/// Shared XCUITest harness for the programmatic control-channel e2e suites: launches the real app
/// with an isolated `AGTERM_STATE_DIR` (which also locates the unix socket at `<stateDir>/agterm.sock`),
/// speaks the socket directly from the test process (one newline-delimited JSON request → one response
/// → close), and exposes the `workspaces.json` file-polling oracles the suites assert against. The
/// per-family `Control*UITests` classes and `SessionTextUITests` subclass it.
@MainActor
class ControlAPITestCase: XCTestCase {
    var app: XCUIApplication!
    private(set) var stateDir: URL!
    private var socketPath: String!
    private(set) var markerDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-ctluitest-\(UUID().uuidString)", isDirectory: true)
        markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-ctlmarker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        // socket path constraints: it must be (a) under the unix-socket sun_path ~104-byte limit and
        // (b) inside the runner's sandbox grant. The per-test AGTERM_STATE_DIR subdir pushes the path to
        // ~135 bytes (too long), and /tmp is outside the runner sandbox (connect → EPERM). The runner's
        // own temp dir (NSTemporaryDirectory(), ~81 bytes) with a short filename satisfies both.
        socketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("agtermc-\(UUID().uuidString.prefix(8)).sock")
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchEnvironment["AGTERM_CONTROL_SOCKET"] = socketPath
        // Pin the title-bar double-click action so the header gesture tests are hermetic regardless of
        // the host's Desktop & Dock setting (the app honors this env override in
        // performTitlebarDoubleClickAction; launch args can't carry it — FB11763863). Most tests never
        // double-click, so the value is irrelevant to them; the no-op-case test opts into "None".
        // (that test, testDoubleClickHeaderHonorsNoneSetting, now lives in ControlWindowUITests.)
        app.launchEnvironment["AGTERM_UITEST_DOUBLECLICK_ACTION"] =
            name.contains("testDoubleClickHeaderHonorsNoneSetting") ? "None" : "Maximize"
        app.launchForUITest()
        // the seeded session row proves the window (and thus the control server's scene .task) is up.
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 30), "seeded session should exist")
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
        if let markerDir { try? FileManager.default.removeItem(at: markerDir) }
    }

    /// Polls until the sidebar shows exactly `expected` `session-row` elements.
    func pollSessionRowCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        let rows = app.staticTexts.matching(identifier: "session-row")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if rows.count == expected { return true }
            usleep(200_000)
        }
        return rows.count == expected
    }

    /// The id of the seeded (active) session from the tree.
    func activeSessionID() throws -> String {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any], "tree should carry a result")
        let t = try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
        let ws = try XCTUnwrap((t["workspaces"] as? [[String: Any]])?.first, "should have a workspace")
        return try XCTUnwrap((ws["sessions"] as? [[String: Any]])?.first?["id"] as? String, "seeded session id")
    }

    /// Terminate the running app, write `snapshot` as the (single) window's per-window snapshot file,
    /// and relaunch with the same isolated state dir + socket so a test can control the restored
    /// session set. `windows.json` (written by the first launch) already points at this file, so the
    /// relaunched window loads the seeded snapshot.
    func relaunch(withSnapshot snapshot: String) throws {
        app.terminate()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Data(snapshot.utf8).write(to: stateDir.windowSnapshotFile())
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchEnvironment["AGTERM_CONTROL_SOCKET"] = socketPath
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 30), "restored session should exist")
    }

    /// Terminate the running app, write `keymap` to `<stateDir>/config/keymap.conf`, and relaunch with the
    /// same isolated state dir + socket.
    func relaunch(withKeymap keymap: String) throws {
        try relaunch(writing: keymap, toConfigFile: "keymap.conf")
    }

    /// Terminate the running app, write `config` to `<stateDir>/config/ghostty.conf`, and relaunch with the
    /// same isolated state dir + socket.
    func relaunch(withGhosttyConfig config: String) throws {
        try relaunch(writing: config, toConfigFile: "ghostty.conf")
    }

    /// Terminate the running app, write `contents` to `<stateDir>/config/<fileName>`, and relaunch with the
    /// same isolated state dir + socket. Writing the file before relaunch means the starter-file seeder
    /// finds it present and never overwrites it, so the seeded content is what gets parsed.
    func relaunch(writing contents: String, toConfigFile fileName: String) throws {
        app.terminate()
        let configDir = stateDir.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: configDir.appendingPathComponent(fileName))
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchEnvironment["AGTERM_CONTROL_SOCKET"] = socketPath
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 30), "seeded session should exist")
    }

    /// Terminate the running app, write `json` as `<stateDir>/settings.json`, and relaunch with the same
    /// isolated state dir + socket so a test can exercise a seeded `AppSettings`. `SettingsStore` reads the
    /// file directly under the state dir (the `AGTERM_STATE_DIR` override), and the app applies GUI-only
    /// settings at launch — e.g. `SettingsModel.applyAutoFollow` pushes the seeded auto-follow timeout into
    /// each window's store — so seeding + relaunch is how a control-only test enables a GUI-only setting.
    /// The previously seeded session set restores from the same state dir.
    func relaunch(withSettings json: String) throws {
        app.terminate()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: stateDir.appendingPathComponent("settings.json"))
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchEnvironment["AGTERM_CONTROL_SOCKET"] = socketPath
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 30), "seeded session should exist")
    }

    /// Build a `session.type` request line with JSON-escaped `text` (covers the newline and the quoted
    /// path); `pane` addresses a pane (`left`|`right`|`scratch`, nil = the main pane).
    func typeRequest(text: String, target: String? = nil, select: Bool, pane: String? = nil) -> String {
        var args: [String: Any] = ["text": text, "select": select]
        if let pane { args["pane"] = pane }
        var obj: [String: Any] = ["cmd": "session.type", "args": args]
        if let target { obj["target"] = target }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    /// Seed the SYSTEM pasteboard for one test, restoring its FULL prior contents afterwards.
    ///
    /// `NSPasteboard.general` is a machine-wide resource the app process reads, so a test that seeds it must
    /// put back exactly what the user had — every representation (RTF, image, file URL, custom UTIs), not
    /// just `.string`, since `clearContents()` destroys them all. The restore rides `addTeardownBlock`, which
    /// XCTest runs even when an assertion fails; a `defer` would not, because `continueAfterFailure = false`
    /// unwinds through an Objective-C exception that skips Swift defer blocks. Pass an empty closure to seed
    /// a deliberately EMPTY clipboard.
    func seedPasteboard(_ seed: (NSPasteboard) -> Void) {
        let pb = NSPasteboard.general
        // deep-copy each item: the originals are invalidated by clearContents().
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        addTeardownBlock {
            let general = NSPasteboard.general
            general.clearContents()
            if !saved.isEmpty { general.writeObjects(saved) }
        }
        pb.clearContents()
        seed(pb)
    }

    /// Polls `file` until its (trimmed) contents are non-empty, returning them, or nil on timeout.
    func pollMarker(_ file: URL, timeout: TimeInterval) -> String? {
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

    /// Inject `command` (which redirects to `file`) and wait for the shell to write it back, retrying the
    /// inject if the marker hasn't appeared yet. A freshly-realized surface's shell/pty may not be ready to
    /// read when the first keystrokes land (especially under full-suite CPU load), so a single injection can
    /// be dropped — re-injecting once the shell has had time to spawn is the deterministic readiness wait.
    /// The marker file is the readiness signal: when it's non-empty the command actually ran. Returns the
    /// marker contents, or nil if it never appeared across all attempts. Asserts each type request returns ok.
    func typeUntilMarker(_ command: String, target: String, file: URL, select: Bool,
                         attempts: Int = 4, perAttempt: TimeInterval = 4) throws -> String? {
        for attempt in 0..<attempts {
            // clear any marker a prior attempt's late injection may have written, so a stale value
            // can't be read as this attempt's success.
            try? FileManager.default.removeItem(at: file)
            let typed = try sendCommand(typeRequest(text: command, target: target, select: select))
            XCTAssertEqual(typed["ok"] as? Bool, true, "typing the probe (attempt \(attempt)) should succeed: \(typed)")
            if let value = pollMarker(file, timeout: perAttempt) { return value }
        }
        return nil
    }

    /// Polls `session.text --pane <pane>` of `target` until the returned buffer contains `contains`, re-running
    /// `retype` (which re-injects the marker command — idempotent for an `echo` line) at the start of each
    /// outer attempt to ride out shell/focus readiness. Returns the matching text, or nil on timeout. Shared
    /// by the pane-addressed suites (`SessionTextUITests`, `SessionTypePaneUITests`).
    @discardableResult
    func pollPaneText(target: String, pane: String, contains: String,
                      attempts: Int = 8, perAttempt: Int = 8,
                      retype: () throws -> Void) throws -> String? {
        for _ in 0..<attempts {
            try retype()
            for _ in 0..<perAttempt {
                let response = try sendCommand(#"{"cmd":"session.text","target":"\#(target)","args":{"pane":"\#(pane)"}}"#)
                if let t = (response["result"] as? [String: Any])?["text"] as? String, t.contains(contains) {
                    return t
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            }
        }
        return nil
    }

    // MARK: - Snapshot oracle

    /// Polls the hermetic snapshot file until the (single) seeded workspace holds `expected` sessions.
    func pollSessionCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]], let ws = workspaces.first else { return nil }
            return (ws["sessions"] as? [[String: Any]])?.count ?? -1
        }
    }

    /// Polls the hermetic snapshot file until each workspace's session count equals `expected`, in order.
    func pollSessionCounts(_ expected: [Int], timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]] else { return nil }
            return workspaces.map { ($0["sessions"] as? [[String: Any]])?.count ?? -1 }
        }
    }

    /// Polls the hermetic snapshot file until the (single seeded workspace's) first session's `isSplit`
    /// equals `expected`.
    func pollActiveSessionSplit(_ expected: Bool, timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]],
                  let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
            return sessions.first?["isSplit"] as? Bool ?? false
        }
    }

    /// Polls the hermetic snapshot file until `selectedSessionID` equals `expected`.
    func pollActiveSessionID(_ expected: UUID, timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected.uuidString.lowercased(), timeout: timeout) { obj in
            (obj["selectedSessionID"] as? String)?.lowercased()
        }
    }

    /// Polls the hermetic snapshot file until the (single seeded workspace's) first session's `customName`
    /// equals `expected`.
    func pollFirstSessionName(_ expected: String, timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]],
                  let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
            return sessions.first?["customName"] as? String
        }
    }

    /// Polls the hermetic snapshot file until the (single seeded workspace's) first session's `splitRatio`
    /// equals `expected` — the persisted side effect of `session.resize`.
    func pollSplitRatio(_ expected: Double, timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]],
                  let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
            return sessions.first?["splitRatio"] as? Double
        }
    }

    /// Polls the hermetic snapshot file until the session with `id` (case-insensitive) has `customName`
    /// equal to `expected`, scanning across all workspaces.
    func pollSessionName(id: String, equals expected: String, timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]] else { return nil }
            for ws in workspaces {
                for s in (ws["sessions"] as? [[String: Any]] ?? [])
                where (s["id"] as? String)?.lowercased() == id.lowercased() {
                    return s["customName"] as? String
                }
            }
            return nil
        }
    }

    /// Polls the hermetic snapshot file until the (single seeded workspace's) session ids equal
    /// `expected`, in order (case-insensitive compare).
    func pollSessionOrder(_ expected: [UUID], timeout: TimeInterval) -> Bool {
        let wanted = expected.map { $0.uuidString.lowercased() }
        return stateDir.pollSnapshot(equals: wanted, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]],
                  let sessions = workspaces.first?["sessions"] as? [[String: Any]] else { return nil }
            return sessions.compactMap { ($0["id"] as? String)?.lowercased() }
        }
    }

    /// Polls the hermetic snapshot file until the session ids in the workspace at `workspaceIndex` equal
    /// `expected`, in order (case-insensitive compare). Used by cross-workspace placement tests where the
    /// destination is not the first workspace, so `pollSessionOrder` (first-workspace-only) can't observe it.
    func pollSessionOrder(inWorkspace workspaceIndex: Int, equals expected: [UUID], timeout: TimeInterval) -> Bool {
        let wanted = expected.map { $0.uuidString.lowercased() }
        return stateDir.pollSnapshot(equals: wanted, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]],
                  workspaceIndex < workspaces.count,
                  let sessions = workspaces[workspaceIndex]["sessions"] as? [[String: Any]] else { return nil }
            return sessions.compactMap { ($0["id"] as? String)?.lowercased() }
        }
    }

    /// Polls the hermetic snapshot file until the workspace names equal `expected`, in order.
    func pollWorkspaceNames(_ expected: [String], timeout: TimeInterval) -> Bool {
        stateDir.pollSnapshot(equals: expected, timeout: timeout) { obj in
            guard let workspaces = obj["workspaces"] as? [[String: Any]] else { return nil }
            return workspaces.compactMap { $0["name"] as? String }
        }
    }

    /// The (single seeded workspace's) first session's persisted `fontSize` override, or nil when the
    /// session has none (or the snapshot isn't readable yet).
    func firstSessionFontSize() -> Double? {
        guard let data = try? Data(contentsOf: stateDir.windowSnapshotFile()),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = obj["workspaces"] as? [[String: Any]],
              let sessions = workspaces.first?["sessions"] as? [[String: Any]]
        else { return nil }
        return sessions.first?["fontSize"] as? Double
    }

    /// Polls the hermetic snapshot file until the first session has a persisted `fontSize` override,
    /// returning it, or nil on timeout (the `FontSizeUITests.pollFontSize` shape).
    func pollFirstSessionFontSize(timeout: TimeInterval) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let size = firstSessionFontSize() { return size }
            usleep(200_000)
        }
        return firstSessionFontSize()
    }

    // MARK: - Socket client

    /// Connect to the app's control socket, send `line` (newline-terminated), read the single response
    /// line, and parse it as JSON. Retries the connect briefly since the server's scene `.task` may bind a
    /// beat after the window appears.
    func sendCommand(_ line: String) throws -> [String: Any] {
        let fd = try connect(to: socketPath)
        defer { close(fd) }

        var payload = Data(line.utf8)
        payload.append(UInt8(ascii: "\n"))
        try writeAll(fd, payload)

        let data = readLine(fd)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(obj, "response should be a JSON object, got: \(String(data: data, encoding: .utf8) ?? "<binary>")")
    }

    /// Open a unix-domain stream socket and connect to `path`, retrying for a few seconds while the server
    /// finishes binding.
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
    private func readLine(_ fd: Int32) -> Data {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue } // a signal interrupted the blocking read; retry, don't treat as EOF
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
