import ArgumentParser
import Darwin
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

// serialized: runSucceedsOnOkResponse and runThrowsExitCodeFailureOnErrorResponse both redirect the
// process-global STDOUT_FILENO via captureStdout, so running them in parallel races on stdout (one
// test's output lands in the other's pipe). serial execution keeps the redirect exclusive.
@Suite(.serialized)
struct SocketClientTests {
    @Test func roundTripOkResponse() throws {
        let canned = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        let server = StubServer(response: canned)
        try server.start()
        defer { server.stop() }

        let client = SocketClient(path: server.path)
        let response = try client.send(ControlRequest(cmd: .sessionSelect, target: "active"))

        #expect(response.ok)
        #expect(response.result?.id == "9f3c")
        // the server echoed the request it received — confirm the client wrote it correctly.
        #expect(server.received?.cmd == .sessionSelect)
        #expect(server.received?.target == "active")
    }

    @Test func roundTripErrorResponse() throws {
        let canned = ControlResponse(ok: false, error: "cannot delete last workspace")
        let server = StubServer(response: canned)
        try server.start()
        defer { server.stop() }

        let client = SocketClient(path: server.path)
        let response = try client.send(ControlRequest(cmd: .workspaceDelete, target: "active"))

        #expect(!response.ok)
        #expect(response.error == "cannot delete last workspace")
    }

    /// A `session.text --all` response can exceed the old 1 MiB cap (full scrollback). A >1 MiB text
    /// payload must round-trip intact, not fail with "no response".
    @Test func roundTripLargeResponse() throws {
        let big = String(repeating: "scrollback line\n", count: 200_000) // ~3 MiB, well over 1 MiB
        let server = StubServer(response: ControlResponse(ok: true, result: ControlResult(text: big)))
        try server.start()
        defer { server.stop() }

        let client = SocketClient(path: server.path)
        let response = try client.send(ControlRequest(cmd: .sessionText, target: "active"))

        #expect(response.ok)
        #expect(response.result?.text == big)
    }

    @Test func connectFailureToMissingSocketThrows() {
        let client = SocketClient(path: NSTemporaryDirectory() + "agterm-missing-\(UUID().uuidString.prefix(8)).sock")
        #expect(throws: SocketClientError.self) { try client.send(ControlRequest(cmd: .tree)) }
    }

    /// A create command's `run()` returns without throwing on `{"ok":true}` and prints the new id.
    @Test func runEchoesNewIdForCreateCommand() throws {
        let server = StubServer(response: ControlResponse(ok: true, result: ControlResult(id: "9f3c")))
        try server.start()
        defer { server.stop() }

        let command = try Session.New.parse(["--socket", server.path])
        let printed = try captureStdout { try command.run() }
        #expect(printed == "9f3c\n")
    }

    /// A non-create command suppresses the id echo (prints `ok`) even when the response carries an id.
    @Test func runQuietsIdForNonCreateCommand() throws {
        let server = StubServer(response: ControlResponse(ok: true, result: ControlResult(id: "9f3c")))
        try server.start()
        defer { server.stop() }

        let command = try Tree.parse(["--socket", server.path])
        let printed = try captureStdout { try command.run() }
        #expect(printed == "ok\n")
    }

    /// Runs `body` with the process stdout redirected to a pipe, returning everything it printed.
    private func captureStdout(_ body: () throws -> Void) throws -> String {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        defer { close(saved) }
        fflush(stdout)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        try body()
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `RequestCommand.run()` throws `ExitCode.failure` on a `{"ok":false}` response.
    @Test func runThrowsExitCodeFailureOnErrorResponse() throws {
        let server = StubServer(response: ControlResponse(ok: false, error: "boom"))
        try server.start()
        defer { server.stop() }

        let command = try Tree.parse(["--socket", server.path, "--json"])
        #expect(throws: ExitCode.failure) { try command.run() }
    }

    // the --block path: open → poll session.overlay.result (retry while still running) → exit with the
    // captured status. drives the real run() against a scripted multi-connection server.
    @Test func blockPollsResultThenExitsWithStatus() throws {
        let script = OverlayResultScript(stillRunningTimes: 1,
                                         finalResult: ControlResponse(ok: true, result: ControlResult(id: "abc", exitCode: 7)))
        let server = ScriptedStubServer(responder: script.respond)
        try server.start()
        defer { server.stop() }

        let command = try Session.Overlay.Open.parse(["echo", "--block", "--socket", server.path])
        do {
            try command.run()
            Issue.record("expected --block to exit with the program's status")
        } catch let code as ExitCode {
            #expect(code.rawValue == 7)
        }
    }

    // an ok result with no exitCode is a protocol violation → --block fails, never exits 0.
    @Test func blockFailsWhenResultMissingExitCode() throws {
        let script = OverlayResultScript(stillRunningTimes: 0,
                                         finalResult: ControlResponse(ok: true, result: ControlResult(id: "abc")))
        let server = ScriptedStubServer(responder: script.respond)
        try server.start()
        defer { server.stop() }

        let command = try Session.Overlay.Open.parse(["echo", "--block", "--socket", server.path])
        #expect(throws: ExitCode.failure) { try command.run() }
    }

    // a failed open short-circuits --block before any poll.
    @Test func blockFailsWhenOpenFails() throws {
        let server = ScriptedStubServer { req in
            req.cmd == .sessionOverlayOpen
                ? ControlResponse(ok: false, error: "overlay already open")
                : ControlResponse(ok: false, error: "unexpected")
        }
        try server.start()
        defer { server.stop() }

        let command = try Session.Overlay.Open.parse(["echo", "--block", "--socket", server.path])
        #expect(throws: ExitCode.failure) { try command.run() }
    }

    @Test func formatResponseBareOk() {
        #expect(SocketClient.formatResponse(ControlResponse(ok: true), json: false) == "ok")
    }

    @Test func formatResponseEchoesIdWhenRequested() {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        #expect(SocketClient.formatResponse(response, json: false, echoID: true) == "9f3c")
    }

    @Test func formatResponseSuppressesIdByDefault() {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        #expect(SocketClient.formatResponse(response, json: false) == "ok")
    }

    @Test func formatResponseText() {
        let response = ControlResponse(ok: true, result: ControlResult(text: "selected\nlines"))
        #expect(SocketClient.formatResponse(response, json: false) == "selected\nlines")
    }

    @Test func formatResponseZeroCountIsOk() {
        // keymap.reload reports a parse-diagnostic count; 0 reads as a clean reload.
        let response = ControlResponse(ok: true, result: ControlResult(count: 0))
        #expect(SocketClient.formatResponse(response, json: false) == "ok")
    }

    @Test func formatResponseNonZeroCountPluralizes() {
        let response = ControlResponse(ok: true, result: ControlResult(count: 3))
        #expect(SocketClient.formatResponse(response, json: false) == "3 diagnostic(s)")
    }

    @Test func formatResponseError() {
        #expect(SocketClient.formatResponse(ControlResponse(ok: false, error: "boom"), json: false) == "error: boom")
    }

    @Test func formatResponseRatio() {
        // session.resize echoes the applied (clamped) left-pane fraction as a bare 3-decimal number.
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c", ratio: 0.85))
        #expect(SocketClient.formatResponse(response, json: false) == "0.850")
    }

    @Test func formatResponseErrorFallback() {
        // an error response with no message falls back to a generic line.
        #expect(SocketClient.formatResponse(ControlResponse(ok: false), json: false) == "error: unknown error")
    }

    @Test func formatResponseJSONIsRaw() throws {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        let line = SocketClient.formatResponse(response, json: true)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
        #expect(decoded.ok)
        #expect(decoded.result?.id == "9f3c")
    }

    @Test func formatResponseTree() {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: true)
        let workspace = ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])
        let tree = ControlTree(workspaces: [workspace])
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(tree: tree)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0] == "* work  [w1]")
        // active session (*), the (split) suffix, id and cwd columns.
        #expect(lines[1] == "  * shell (split)  [s1]  /tmp")
    }

    @Test func formatTreeShowsScratchTag() {
        let session = ControlSessionNode(id: "s3", name: "shell", cwd: "/tmp", active: true, split: false,
                                         overlay: false, scratch: true)
        let workspace = ControlWorkspaceNode(id: "w3", name: "work", active: true, sessions: [session])
        let tree = ControlTree(workspaces: [workspace])
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(tree: tree)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[1] == "  * shell (scratch)  [s3]  /tmp")
    }

    @Test func formatTreeMarksInactive() {
        let session = ControlSessionNode(id: "s2", name: "logs", cwd: "/var", active: false, split: false)
        let workspace = ControlWorkspaceNode(id: "w2", name: "other", active: false, sessions: [session])
        let tree = ControlTree(workspaces: [workspace])
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(tree: tree)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "  other  [w2]")
        #expect(lines[1] == "    logs  [s2]  /var")
    }

    @Test func formatResponseWindows() {
        let windows = [
            ControlWindowNode(id: "w1", name: "work", open: true, active: true),
            ControlWindowNode(id: "w2", name: "personal", open: true, active: false),
            ControlWindowNode(id: "w3", name: "archive", open: false, active: false),
            // a closed-but-active window (frontmost id pointing at a window not yet loaded) still
            // renders the [active] tag without [open].
            ControlWindowNode(id: "w4", name: "pending", open: false, active: true),
        ]
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(windows: windows)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] == "w1  work [open] [active]")
        #expect(lines[1] == "w2  personal [open]")
        #expect(lines[2] == "w3  archive")
        #expect(lines[3] == "w4  pending [active]")
    }

    @Test func formatResponseEmptyWindows() {
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(windows: [])), json: false)
        // an empty window list renders an empty string (no per-window lines), not the bare ok line —
        // a present-but-empty `windows` payload still takes the windows branch.
        #expect(out == "")
    }

    @Test func formatResponseThemesMarksCurrent() {
        let response = ControlResponse(ok: true, result: ControlResult(theme: "Nord", themes: ["Dracula", "Nord"]))
        let out = SocketClient.formatResponse(response, json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines == ["  default ghostty", "  Dracula", "* Nord"])
    }

    @Test func formatResponseThemesMarksGhosttyDefaultWhenCurrent() {
        // nil current theme = ghostty's built-in is active, so the leading "default ghostty" row is marked.
        let response = ControlResponse(ok: true, result: ControlResult(theme: nil, themes: ["Dracula"]))
        let out = SocketClient.formatResponse(response, json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines == ["* default ghostty", "  Dracula"])
    }

    @Test func formatResponseThemeSetIsBareOk() {
        // theme.set returns only `theme` (no `themes` array), so it prints `ok` like other mutations.
        let response = ControlResponse(ok: true, result: ControlResult(theme: "Dracula"))
        #expect(SocketClient.formatResponse(response, json: false) == "ok")
    }

    @Test func formatResponseThemesMarksBothSyncedSides() {
        // when syncing, both the light and dark themes are marked and a header notes the pair.
        let response = ControlResponse(ok: true, result: ControlResult(
            theme: nil, themes: ["agterm", "Builtin Light", "Nord"], sync: true, light: "Builtin Light", dark: "agterm"))
        let out = SocketClient.formatResponse(response, json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "syncing with macOS appearance — light: Builtin Light, dark: agterm")
        #expect(lines.contains("* agterm"))
        #expect(lines.contains("* Builtin Light"))
        #expect(lines.contains("  Nord"))
        #expect(lines.contains("  default ghostty")) // unmarked while syncing
    }
}

/// An in-process unix-socket server for the round-trip tests: binds a short temp path, accepts one
/// connection, reads the request line, records it, and writes back a canned `ControlResponse`.
private final class StubServer: @unchecked Sendable {
    let path: String
    private let canned: ControlResponse
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "stub.server")
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false
    private(set) var received: ControlRequest?

    init(response: ControlResponse) {
        self.canned = response
        self.path = NSTemporaryDirectory() + "agterm-stub-\(UUID().uuidString.prefix(8)).sock"
    }

    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError("stub socket() failed") }
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                pathBytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw SocketClientError("stub bind failed: \(String(cString: strerror(errno)))")
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw SocketClientError("stub listen failed")
        }
        listenFD = fd
        queue.async { [self] in accept(fd); finished.signal() }
    }

    private func accept(_ fd: Int32) {
        let conn = Darwin.accept(fd, nil, nil)
        lock.lock(); let done = stopped; lock.unlock()
        // stop() woke this accept only to join it — don't serve a request on a stopping server.
        if done { if conn >= 0 { close(conn) }; return }
        guard conn >= 0 else { return }
        defer { close(conn) }

        // read one request line.
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(conn, &byte, 1)
            if n <= 0 { break }
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
        }
        received = try? JSONDecoder().decode(ControlRequest.self, from: buffer)

        // write the canned response.
        guard var data = try? JSONEncoder().encode(canned) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let written = write(conn, base + offset, data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    func stop() {
        guard listenFD >= 0 else { unlink(path); return }
        lock.lock(); stopped = true; lock.unlock()
        wakeAccept(path)                        // unblock a pending accept() so the loop observes `stopped`
        _ = finished.wait(timeout: .now() + 2)  // join the accept loop before freeing the fd
        close(listenFD); listenFD = -1
        unlink(path)
    }
}

/// Connect once to `path` and immediately close, to wake a stub server's blocked `accept()` so its
/// background loop can observe `stopped` and exit. Best-effort — a failed connect is ignored. Shared by
/// both stub servers so `stop()` can JOIN the accept loop before the listen fd is closed, which is what
/// keeps a lingering loop from serving the next server's client on a reused fd number.
private func wakeAccept(_ path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { dst in
        dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
            pathBytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
        }
    }
    _ = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

/// A multi-connection unix-socket server: accepts connections in a loop until `stop()`, answering each
/// request via `responder`. Used to drive the `--block` flow, which makes several round trips (open,
/// then one connection per `session.overlay.result` poll).
private final class ScriptedStubServer: @unchecked Sendable {
    let path: String
    private let responder: @Sendable (ControlRequest) -> ControlResponse
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "scripted.stub.server")
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false

    init(responder: @escaping @Sendable (ControlRequest) -> ControlResponse) {
        self.responder = responder
        self.path = NSTemporaryDirectory() + "agterm-scripted-\(UUID().uuidString.prefix(8)).sock"
    }

    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError("scripted socket() failed") }
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                pathBytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw SocketClientError("scripted bind failed: \(String(cString: strerror(errno)))")
        }
        guard listen(fd, 4) == 0 else {
            close(fd)
            throw SocketClientError("scripted listen failed")
        }
        listenFD = fd
        queue.async { [self] in acceptLoop(fd); finished.signal() }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let conn = Darwin.accept(fd, nil, nil)
            lock.lock(); let done = stopped; lock.unlock()
            // stop() flips `stopped` then self-connects to wake this accept; observing it here is what
            // lets the loop exit (and be joined) before the fd is closed, so it can never run accept on a
            // number the next server has reused.
            if done { if conn >= 0 { close(conn) }; return }
            if conn < 0 { return }
            handle(conn)
            close(conn)
        }
    }

    private func handle(_ conn: Int32) {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(conn, &byte, 1)
            if n <= 0 { return }
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
        }
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: buffer) else { return }
        guard var data = try? JSONEncoder().encode(responder(request)) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let written = write(conn, base + offset, data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    func stop() {
        guard listenFD >= 0 else { unlink(path); return }
        lock.lock(); stopped = true; lock.unlock()
        wakeAccept(path)                        // unblock a pending accept() so the loop observes `stopped`
        _ = finished.wait(timeout: .now() + 2)  // join the accept loop before freeing the fd
        close(listenFD); listenFD = -1
        unlink(path)
    }
}

/// Scripts the `--block` round trips: `session.overlay.open` returns a fixed id; `session.overlay.result`
/// errors `stillRunning` for the first `stillRunningTimes` calls, then returns `finalResult`.
private final class OverlayResultScript: @unchecked Sendable {
    private let lock = NSLock()
    private var resultCalls = 0
    private let stillRunningTimes: Int
    private let finalResult: ControlResponse

    init(stillRunningTimes: Int, finalResult: ControlResponse) {
        self.stillRunningTimes = stillRunningTimes
        self.finalResult = finalResult
    }

    func respond(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionOverlayOpen:
            return ControlResponse(ok: true, result: ControlResult(id: "abc"))
        case .sessionOverlayResult:
            lock.lock(); resultCalls += 1; let n = resultCalls; lock.unlock()
            return n <= stillRunningTimes
                ? ControlResponse(ok: false, error: OverlayResultError.stillRunning)
                : finalResult
        default:
            return ControlResponse(ok: false, error: "unexpected cmd \(request.cmd)")
        }
    }
}
