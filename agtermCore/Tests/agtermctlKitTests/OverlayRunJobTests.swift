import Foundation
import Testing
@testable import agtermCore
@testable import agtermctlKit

@Suite(.serialized)
struct OverlayRunJobTests {
    final class FakeOrigin: @unchecked Sendable {
        let helper: Int32
        let origin: Int32
        private let lock = NSLock()
        private var received: [OverlayJobFrame] = []
        private let done = DispatchSemaphore(value: 0)

        init() {
            var pair: [Int32] = [-1, -1]
            socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
            var noSigPipe: Int32 = 1
            for fd in pair { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) }
            helper = pair[0]
            origin = pair[1]
        }

        func serve(reply: String, context: OverlayLaunchContext?) {
            Thread { [self] in
                _ = readLine()
                write(reply + "\n")
                if let context, let line = try? OverlayJobFrame.context(context).line() {
                    write(String(decoding: line, as: UTF8.self))
                }
                while let line = readLine() {
                    if let frame = try? JSONDecoder().decode(OverlayJobFrame.self, from: line) {
                        lock.withLock { received.append(frame) }
                    }
                }
                done.signal()
            }.start()
        }

        func send(_ frame: OverlayJobFrame) {
            guard let line = try? frame.line() else { return }
            write(String(decoding: line, as: UTF8.self))
        }

        func frames() -> [OverlayJobFrame] {
            close(helper)
            _ = done.wait(timeout: .now() + 5)
            return lock.withLock { received }
        }

        private func write(_ text: String) {
            _ = StreamBridge.writeAll(origin, Data(text.utf8))
        }

        private func readLine() -> Data? {
            var line = Data()
            var byte: UInt8 = 0
            while true {
                guard read(origin, &byte, 1) == 1 else { return nil }
                if byte == UInt8(ascii: "\n") { return line }
                line.append(byte)
            }
        }
    }

    static let okReply = #"{"ok":true,"result":{"id":"job"}}"#

    static let base = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]

    func context(_ command: String) -> OverlayLaunchContext {
        OverlayLaunchContext(command: command, cwd: "/tmp", sessionEnvironment: ["AGTERM_ENABLED": "1"])
    }

    func gone(_ pid: pid_t) -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { return true }
            usleep(20_000)
        }
        return false
    }

    func pidFile() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("agterm-run-job-\(UUID().uuidString).pid")
    }

    func readPID(_ path: String) -> pid_t? {
        for _ in 0..<100 {
            if let text = try? String(contentsOfFile: path, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            usleep(20_000)
        }
        return nil
    }

    @Test func aProgramExitingThreeReportsThreeAndTheHelperExitsThree() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: context("exit 3"))
        let runner = OverlayJobRunner(socket: origin.helper)

        let status = runner.run(try runner.claim("job"), baseEnvironment: Self.base)

        #expect(status == 3)
        #expect(origin.frames() == [.started, .exited(3)])
    }

    @Test func aRefusedClaimLaunchesNothing() {
        let origin = FakeOrigin()
        origin.serve(reply: #"{"ok":false,"error":"job not claimable"}"#, context: nil)
        let runner = OverlayJobRunner(socket: origin.helper)

        #expect(throws: SocketClientError.self) { try runner.claim("job") }
        #expect(origin.frames().isEmpty)
    }

    @Test func aCancelFromTheAppEndsTheProgramCanceled() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: context("sleep 30"))
        let runner = OverlayJobRunner(socket: origin.helper, grace: 0.3)
        let claimed = try runner.claim("job")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { origin.send(.cancel) }

        let status = runner.run(claimed, baseEnvironment: Self.base)

        #expect(status == 128 + SIGTERM)
        #expect(origin.frames() == [.started, .canceled])
    }

    @Test func aCancelKillsAProgramThatIgnoresTheFirstSignal() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: context(#"trap "" TERM; sleep 30"#))
        let runner = OverlayJobRunner(socket: origin.helper, grace: 0.3)
        let claimed = try runner.claim("job")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { runner.cancel() }
        let started = Date()

        let status = runner.run(claimed, baseEnvironment: Self.base)

        #expect(status == 128 + SIGKILL)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(origin.frames() == [.started, .canceled])
    }

    @Test func aReportTheAppNeverGetsLeavesTheHelpersStatusAlone() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: context("sleep 0.3; exit 5"))
        let runner = OverlayJobRunner(socket: origin.helper)
        let claimed = try runner.claim("job")
        close(origin.origin)

        #expect(runner.run(claimed, baseEnvironment: Self.base) == 5)
    }

    @Test func theProgramDoesNotInheritTheAppConnection() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: context("test ! -e /dev/fd/\(origin.helper)"))
        let runner = OverlayJobRunner(socket: origin.helper)

        #expect(runner.run(try runner.claim("job"), baseEnvironment: Self.base) == 0)
    }

    @Test func theTerminalTypeComesFromTheHelpersOwnTerminal() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: context(#"test "$TERM" = xterm-kitty"#))
        let runner = OverlayJobRunner(socket: origin.helper)

        var base = Self.base
        base["TERM"] = "xterm-kitty"

        #expect(runner.run(try runner.claim("job"), baseEnvironment: base) == 0)
    }

    @Test func theProgramGetsTheHelpersEnvironmentUnderTheContext() throws {
        let bin = (NSTemporaryDirectory() as NSString).appendingPathComponent("agterm-run-job-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: bin) }
        let tool = (bin as NSString).appendingPathComponent("agterm-fixture-tool")
        try "#!/bin/sh\nexit 0\n".write(toFile: tool, atomically: true, encoding: .utf8)
        chmod(tool, 0o755)
        let session = UUID()
        let environment = SurfaceEnvironment.session(sessionID: session, windowID: nil, workspaceID: nil,
                                                     socketPath: "/tmp/origin.sock", programVersion: "9.9.9")
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply, context: OverlayLaunchContext(
            command: #"agterm-fixture-tool && test -n "$HOME" && test "$AGTERM_SESSION_ID" = "\#(session.uuidString)""#,
            cwd: "/tmp", sessionEnvironment: environment))
        let runner = OverlayJobRunner(socket: origin.helper)

        let status = runner.run(try runner.claim("job"), baseEnvironment: ["PATH": "\(bin):/usr/bin:/bin", "HOME": "/Users/x",
                                                                           "AGTERM_SESSION_ID": "stale"])

        #expect(status == 0)
    }

    @Test func aCancelEndsTheProgramsDescendantsToo() throws {
        let origin = FakeOrigin()
        let path = pidFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        origin.serve(reply: Self.okReply, context: context("/bin/sleep 60 & echo $! > \(path); wait"))
        let runner = OverlayJobRunner(socket: origin.helper, grace: 0.3)
        let claimed = try runner.claim("job")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { origin.send(.cancel) }

        _ = runner.run(claimed, baseEnvironment: Self.base)

        let descendant = try #require(readPID(path))
        #expect(gone(descendant))
        #expect(origin.frames() == [.started, .canceled])
    }

    @Test func runJobParsesUnderSessionOverlay() throws {
        let command = try #require(try Agtermctl.parseAsRoot(["session", "overlay", "run-job", "job-id"])
            as? agtermctlKit.Session.Overlay.RunJob)

        #expect(command.job == "job-id")
    }

    @Test func aProgramThatCannotStartReportsLaunchFailed() throws {
        let origin = FakeOrigin()
        origin.serve(reply: Self.okReply,
                     context: OverlayLaunchContext(command: "true", cwd: "/nonexistent-\(UUID().uuidString)",
                                                   sessionEnvironment: [:]))
        let runner = OverlayJobRunner(socket: origin.helper)

        let status = runner.run(try runner.claim("job"), baseEnvironment: Self.base)

        #expect(status == 127)
        guard case .launchFailed? = origin.frames().first else {
            Issue.record("expected launch-failed")
            return
        }
    }
}
