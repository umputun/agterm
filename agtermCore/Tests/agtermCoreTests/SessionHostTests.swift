import Foundation
import Testing
@testable import agtermCore

struct SessionHostTests {
    private let hello = SessionHost.Hello(bundleID: "com.umputun.agterm", bundlePath: "/Applications/agterm.app")

    @Test func helloUsesTheDocumentedWireKeys() throws {
        let frame = try SessionHost.encodeFrame(SessionHost.Request.hello(hello))
        let object = try #require(JSONSerialization.jsonObject(with: frame) as? [String: [String: Any]])
        let body = try #require(object["hello"])

        #expect(Set(object.keys) == ["hello"])
        #expect(body["protocol"] as? Int == 1)
        #expect(body["bundleID"] as? String == "com.umputun.agterm")
        #expect(body["bundlePath"] as? String == "/Applications/agterm.app")
        #expect(body["pid"] == nil)
        #expect(try SessionHost.decodeFrame(SessionHost.Request.self, from: frame) == .hello(hello))
    }

    @Test func ensurePreservesArgumentsAndEnvironmentInOneLine() throws {
        let ensure = SessionHost.Ensure(
            name: "agterm-test", argv: ["/Applications/My App.app/zmx", "attach", "agterm-test", "/bin/zsh", "-lic", "echo 'a b'"],
            cwd: "/Users/test/my project", env: ["MULTILINE": "first\nsecond", "QUOTED": "a\"b\\c", "EMPTY": ""], rows: 40, cols: 120)
        let frame = try SessionHost.encodeFrame(SessionHost.Request.ensure(ensure))

        #expect(frame.last == 0x0A)
        #expect(frame.filter { $0 == 0x0A }.count == 1)
        #expect(try SessionHost.decodeFrame(SessionHost.Request.self, from: frame) == .ensure(ensure))
        let object = try #require(JSONSerialization.jsonObject(with: frame) as? [String: [String: Any]])
        #expect(object["ensure"]?["argv"] as? [String] == ensure.argv)
        #expect(object["ensure"]?["env"] as? [String: String] == ensure.env)
        #expect(object["ensure"]?["rows"] as? Int == 40)
        #expect(object["ensure"]?["cols"] as? Int == 120)
    }

    @Test func responseVariantsUseTheDocumentedEnvelopes() throws {
        let responses: [(String, SessionHost.Response)] = [
            ("hello", .hello(.init(bundleID: hello.bundleID, bundlePath: hello.bundlePath, pid: 4242))),
            ("ok", .ok(.init(state: .existing, leaderPid: 12345))),
            ("ok", .ok(.init(state: .created, leaderPid: 12346))),
            ("error", .error(.init(stage: .before, message: "invalid cwd"))),
            ("error", .error(.init(stage: .started, message: "timeout\nwaiting for leader"))),
        ]
        for (key, response) in responses {
            let frame = try SessionHost.encodeFrame(response)
            let object = try #require(JSONSerialization.jsonObject(with: frame) as? [String: [String: Any]])
            #expect(Set(object.keys) == [key])
            #expect(try SessionHost.decodeFrame(SessionHost.Response.self, from: frame) == response)
        }
        let ready = Data("{\"ok\":{\"state\":\"created\",\"leaderPid\":12345}}\n".utf8)
        #expect(try SessionHost.decodeFrame(SessionHost.Response.self, from: ready) == .ok(.init(state: .created, leaderPid: 12345)))
    }

    @Test func frameLimitCountsEncodedBytesIncludingTerminator() throws {
        let small = SessionHost.Response.error(.init(stage: .before, message: ""))
        let overhead = try SessionHost.encodeFrame(small).count
        let message = String(repeating: "a", count: SessionHost.maximumFrameBytes - overhead)
        let exact = SessionHost.Response.error(.init(stage: .before, message: message))
        let frame = try SessionHost.encodeFrame(exact)

        #expect(frame.count == 65_536)
        #expect(try SessionHost.decodeFrame(SessionHost.Response.self, from: frame) == exact)
        #expect(throws: SessionHost.Rejection.frameTooLarge) {
            try SessionHost.encodeFrame(SessionHost.Response.error(.init(stage: .before, message: message + "a")))
        }
        #expect(throws: SessionHost.Rejection.frameTooLarge) {
            try SessionHost.decodeFrame(SessionHost.Response.self, from: Data(repeating: 0x61, count: 65_537))
        }
        #expect(throws: SessionHost.Rejection.frameTooLarge) {
            try SessionHost.encodeFrame(SessionHost.Response.error(.init(stage: .before, message: String(repeating: "é", count: 33_000))))
        }
    }

    @Test(arguments: ["", "{}", "{}\n{}\n", "\n"])
    func incompleteOrMultipleFramesAreRejected(_ text: String) {
        #expect(throws: SessionHost.Rejection.invalidFrame) {
            try SessionHost.decodeFrame(SessionHost.Request.self, from: Data(text.utf8))
        }
    }

    @Test(arguments: ["{}\n", "{\"unknown\":{}}\n", "{\"hello\":{},\"ensure\":{}}\n"])
    func requestRequiresOneMessageVariant(_ text: String) {
        #expect(throws: SessionHost.Rejection.invalidMessage) {
            try SessionHost.decodeFrame(SessionHost.Request.self, from: Data(text.utf8))
        }
    }

    @Test func malformedJSONAndAmbiguousResponsesAreRejected() {
        #expect(throws: DecodingError.self) {
            try SessionHost.decodeFrame(SessionHost.Request.self, from: Data("not-json\n".utf8))
        }
        #expect(throws: SessionHost.Rejection.invalidMessage) {
            try SessionHost.decodeFrame(SessionHost.Response.self, from: Data("{\"ok\":{},\"error\":{}}\n".utf8))
        }
    }

    @Test func pathsShareTheConfiguredSocketDirectory() throws {
        let paths = try SessionHost.paths(socketDirectory: "/tmp/agterm-zmx-test/")
        #expect(paths.socket == "/tmp/agterm-zmx-test/session-host.sock")
        #expect(paths.ownerLock == "/tmp/agterm-zmx-test/session-host.lock")
        #expect(paths.spawnLock == "/tmp/agterm-zmx-test/session-host.spawn.lock")
        #expect(paths.pidfile == "/tmp/agterm-zmx-test/session-host.pid")
        #expect(paths.log == "/tmp/agterm-zmx-test/session-host.log")
    }

    @Test func socketPathLimitReservesTheTerminatingNUL() throws {
        let suffix = "/session-host.sock"
        let directory = "/" + String(repeating: "a", count: 103 - suffix.utf8.count - 1)
        #expect(try SessionHost.paths(socketDirectory: directory).socket.utf8.count == 103)
        #expect(throws: SessionHost.Rejection.socketPathTooLong) {
            try SessionHost.paths(socketDirectory: directory + "a")
        }
        #expect(throws: SessionHost.Rejection.socketPathTooLong) {
            try SessionHost.paths(socketDirectory: "/" + String(repeating: "é", count: 45))
        }
    }

    @Test(arguments: ["", "relative/path"])
    func socketDirectoryMustBeAbsolute(_ directory: String) {
        #expect(throws: SessionHost.Rejection.invalidSocketDirectory) {
            try SessionHost.paths(socketDirectory: directory)
        }
    }

    @Test func readinessFindsOnlyTheExactLiveRecord() throws {
        let output = "name=agterm-other\tpid=11\tclients=1\n→ name=agterm-test\tpid=42\tclients=0\n"
        #expect(try SessionHost.leaderPid(in: output, name: "agterm-test") == 42)
        #expect(try SessionHost.leaderPid(in: output, name: "agterm") == nil)
        #expect(try SessionHost.leaderPid(in: "name=agterm-test\tclients=0\n", name: "agterm-test") == nil)
        #expect(try SessionHost.leaderPid(in: "name=agterm-test\tpid=42\terr=TimedOut\n", name: "agterm-test") == nil)
        #expect(try SessionHost.leaderPid(in: "", name: "agterm-test") == nil)
        #expect(try SessionHost.leaderPid(in: output + output, name: "agterm-test") == nil)
    }

    @Test func malformedReadinessOutputIsNotTreatedAsAbsent() {
        #expect(throws: ZmxListParser.ParseError.self) {
            try SessionHost.leaderPid(in: "name=agterm-test\tpid=0\tclients=0\n", name: "agterm-test")
        }
        #expect(throws: ZmxListParser.ParseError.self) {
            try SessionHost.leaderPid(in: "name=agterm-test\tpid=42\tclients=0\ninvalid\n", name: "agterm-test")
        }
    }

    @Test func acknowledgedEnsureUsesPlainAttach() {
        for state in [SessionHost.Ready.State.existing, .created] {
            let outcome = SessionHost.ClientOutcome.decide(phase: .afterDispatch, reply: .ok(.init(state: state, leaderPid: 42)))
            #expect(outcome == .plainAttach)
            #expect(outcome.diagnostic == nil)
        }
    }

    @Test func failuresBeforeEnsurePreserveCreationPayload() {
        let outcome = SessionHost.ClientOutcome.decide(phase: .beforeDispatch, reply: nil)
        #expect(outcome == .fullAttach)
        #expect(outcome.diagnostic == nil)
        #expect(SessionHost.ClientOutcome.decide(phase: .afterDispatch, reply: .error(.init(stage: .before, message: "rejected"))) == .fullAttach)
    }

    @Test func uncertainEnsureNeverReplaysAndExplainsTheFallback() {
        let replies: [SessionHost.Response?] = [nil, .error(.init(stage: .started, message: "timeout")), .hello(hello)]
        for reply in replies {
            let outcome = SessionHost.ClientOutcome.decide(phase: .afterDispatch, reply: reply)
            #expect(outcome == .uncertain)
            #expect(outcome.diagnostic == "Session creation could not be confirmed; the command may have started and was not retried.")
        }
    }

    @Test func handshakeUsesBundleIdentityAndSupportedProtocol() {
        #expect(SessionHost.handshakeAccepts(local: hello, remote: .init(bundleID: hello.bundleID, bundlePath: hello.bundlePath, pid: 42)))
        #expect(!SessionHost.handshakeAccepts(local: hello, remote: .init(bundleID: "com.umputun.agterm.debug", bundlePath: hello.bundlePath)))
        #expect(!SessionHost.handshakeAccepts(local: hello, remote: .init(bundleID: hello.bundleID, bundlePath: "/Other/agterm.app")))
        #expect(!SessionHost.handshakeAccepts(local: hello, remote: .init(bundleID: hello.bundleID, bundlePath: hello.bundlePath, protocolVersion: 2)))
        #expect(!SessionHost.handshakeAccepts(local: hello, remote: .init(bundleID: hello.bundleID, bundlePath: "agterm.app")))
    }

    @Test func applicationBuildMetadataDoesNotInvalidateHandshake() throws {
        let local = try JSONDecoder().decode(SessionHost.Hello.self, from: Data("""
        {"protocol":1,"bundleID":"com.umputun.agterm","bundlePath":"/Applications/agterm.app","appVersion":"1","build":"old"}
        """.utf8))
        let remote = try JSONDecoder().decode(SessionHost.Hello.self, from: Data("""
        {"protocol":1,"bundleID":"com.umputun.agterm","bundlePath":"/Applications/agterm.app","appVersion":"2","build":"new","pid":42}
        """.utf8))
        #expect(SessionHost.handshakeAccepts(local: local, remote: remote))
    }

    @Test func handshakeCanonicalizesBundleSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = directory.appendingPathComponent("agterm.app")
        let alias = directory.appendingPathComponent("alias.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: bundle)

        #expect(SessionHost.handshakeAccepts(
            local: .init(bundleID: hello.bundleID, bundlePath: bundle.path),
            remote: .init(bundleID: hello.bundleID, bundlePath: alias.path)))
    }

    #if os(macOS)
    @Test func temporaryDirectoryAliasesMatch() throws {
        let bundle = URL(fileURLWithPath: "/tmp/session-host-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(SessionHost.handshakeAccepts(
            local: .init(bundleID: hello.bundleID, bundlePath: bundle.path),
            remote: .init(bundleID: hello.bundleID, bundlePath: "/private" + bundle.path)))
    }
    #endif
}
