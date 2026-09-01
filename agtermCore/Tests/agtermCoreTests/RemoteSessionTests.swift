import Foundation
import Testing
@testable import agtermCore

struct RemoteSessionTests {
    private let daemon = ZmxSupport.daemonName(for: UUID())
    private let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/Contents/Resources/zmx/zmx",
                                              socketDirectory: "/tmp/agterm-zmx-abc123")

    // MARK: - ssh options

    @Test func treeIsNonInteractiveAndBounded() throws {
        let argv = try RemoteSession.treeCommand(host: "buildbox", connectTimeout: 12)
        #expect(argv.prefix(7) == ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=12", "buildbox"])
        #expect(argv.count == 8)
    }

    @Test func attachForcesAPtyAndNeverBoundsItsLifetime() throws {
        let argv = try RemoteSession.attachCommand(host: "buildbox", endpoint: endpoint, daemon: daemon)
        #expect(argv.prefix(7) == ["ssh", "-tt", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "buildbox"])
        #expect(!argv.contains { $0.hasPrefix("ServerAlive") })
    }

    // MARK: - what the remote shell actually runs

    @Test func treeRunsTheFarSidesOwnBareForm() throws {
        let fake = try FakeRemote()
        defer { fake.cleanUp() }
        try fake.installAgtermctl(exitCodes: [0])

        let run = try fake.runRemote(RemoteSession.treeCommand(host: "buildbox"))

        #expect(run.status == 0)
        #expect(try fake.calls() == [["zmx", "tree", "--json"]],
                "one command: the far side does the whole join and answers with one document")
    }

    @Test func treeWidensPathWithEveryDocumentedInstallDirectory() throws {
        let remote = try #require(RemoteSession.treeCommand(host: "buildbox").last)

        // sshd runs a remote command with /usr/bin:/bin:/usr/sbin:/sbin and a non-interactive shell reads
        // no profile, so a CLI installed through the Help action or the cask is otherwise not found. One
        // list, shared with the local widening, or the two drift and an install route stops working.
        #expect(remote.contains(RemoteSession.cliPathPrefix))
        for directory in CommandPath.standardDirectories {
            #expect(remote.contains(directory))
        }
    }

    @Test func theRemoteCommandIsOneOrdinaryCommandEvenUnderANonPosixLoginShell() throws {
        let fake = try FakeRemote()
        defer { fake.cleanUp() }
        try fake.installAgtermctl(exitCodes: [0])

        // sshd runs it through the ACCOUNT's shell, and a bare VAR=value assignment is a syntax error in
        // tcsh; unwrapped, the whole read fails before the first agtermctl
        let run = try fake.runRemote(RemoteSession.treeCommand(host: "buildbox"), shell: "/bin/tcsh")

        #expect(run.status == 0)
        #expect(try fake.calls() == [["zmx", "tree", "--json"]])
    }

    @Test func thePathPrefixAppendsSoAUsersOwnCliStillWins() {
        #expect(RemoteSession.cliPathPrefix.hasPrefix("PATH=\"$PATH:"))
        #expect(!RemoteSession.cliPathPrefix.contains(":$PATH\""))
    }

    // the far side prints a not-ok JSON response to stdout and exits nonzero, so the caller must read the
    // status before the output rather than trusting a well-formed-looking document
    @Test func theFarSidesFailureReachesTheCallerAsANonzeroExit() throws {
        let fake = try FakeRemote()
        defer { fake.cleanUp() }
        try fake.installAgtermctl(exitCodes: [3])

        let run = try fake.runRemote(RemoteSession.treeCommand(host: "buildbox"))

        #expect(run.status != 0)
        #expect(try fake.calls() == [["zmx", "tree", "--json"]])
    }

    @Test func attachPassesTheEndpointAndGuardAsExactArguments() throws {
        let fake = try FakeRemote()
        defer { fake.cleanUp() }
        let zmx = try fake.installZmx()
        let endpoint = ControlZmxEndpoint(executable: zmx, socketDirectory: "/tmp/zmx dir")

        let run = try fake.runRemote(RemoteSession.attachCommand(host: "buildbox", endpoint: endpoint,
                                                                daemon: daemon))

        #expect(run.status == 0)
        #expect(try fake.recordedZmxDir() == "/tmp/zmx dir")
        let argv = try #require(try fake.calls().first)
        #expect(argv == ["attach", daemon, "/bin/sh", "-c",
                         "printf '%s\\n' 'agterm: remote session is gone'; exit 1"])
    }

    // an inherited ZMX_SESSION made attach switch session instead of attaching, past the create-only guard
    @Test func attachClearsTheAccountsOwnZmxSessionVariables() throws {
        let fake = try FakeRemote()
        defer { fake.cleanUp() }
        let zmx = try fake.installZmx()
        let endpoint = ControlZmxEndpoint(executable: zmx, socketDirectory: "/tmp/z")

        let run = try fake.runRemote(
            RemoteSession.attachCommand(host: "buildbox", endpoint: endpoint, daemon: daemon),
            exporting: ["ZMX_SESSION_PREFIX": "work-", "ZMX_SESSION": "someone-elses"])

        #expect(run.status == 0)
        #expect(try fake.recordedZmxSessionEnv() == "session=[] prefix=[] nodetach=[1]")
        #expect(try fake.recordedZmxDir() == "/tmp/z", "clearing them must not lose ZMX_DIR")
    }

    @Test func attachSurvivesABundlePathWithASpace() throws {
        let fake = try FakeRemote(directoryName: "fake remote \(UUID().uuidString)")
        defer { fake.cleanUp() }
        let zmx = try fake.installZmx()
        #expect(zmx.contains(" "), "the fixture must actually exercise the quoting")
        let endpoint = ControlZmxEndpoint(executable: zmx, socketDirectory: "/tmp/agterm-zmx-abc")

        let run = try fake.runRemote(RemoteSession.attachCommand(host: "buildbox", endpoint: endpoint,
                                                                daemon: daemon))

        #expect(run.status == 0)
        #expect(try fake.calls().first?.first == "attach")
    }

    // MARK: - the pane command

    @Test func thePaneCommandPrintsWhatDiedAfterTheAttachExits() throws {
        let fake = try FakeRemote()
        defer { fake.cleanUp() }
        try fake.installSSH()
        let zmx = try fake.installZmx()
        let endpoint = ControlZmxEndpoint(executable: zmx, socketDirectory: "/tmp/z")

        let command = try RemoteSession.attachPaneCommand(host: "buildbox", endpoint: endpoint,
                                                          daemon: daemon, session: "build", pane: .right)
        let run = try fake.runShell(command)

        #expect(run.stdout.contains("agterm: build (right) on buildbox disconnected, exit"))
        #expect(try fake.calls().first?.first == "attach", "the diagnostic runs AFTER the attach")
    }

    @Test func thePaneCommandKeepsTheSshExitStatusRatherThanPrintfsZero() throws {
        let fake = try FakeRemote()
        defer { fake.cleanUp() }
        try fake.installSSH(exitCode: 23)
        let endpoint = ControlZmxEndpoint(executable: "/bin/true", socketDirectory: "/tmp/z")

        let command = try RemoteSession.attachPaneCommand(host: "buildbox", endpoint: endpoint,
                                                          daemon: daemon, session: "build", pane: .left)
        let run = try fake.runShell(command)

        #expect(run.stdout.hasSuffix("exit 23\n"), "the line must name the real status")
        #expect(run.status == 23, "a failed connection must not read as a clean exit")
    }

    @Test func aHostileSessionNameCannotEscapeTheDiagnosticLine() throws {
        let fake = try FakeRemote()
        defer { fake.cleanUp() }
        try fake.installSSH()
        let zmx = try fake.installZmx()
        let endpoint = ControlZmxEndpoint(executable: zmx, socketDirectory: "/tmp/z")
        let marker = fake.root.appendingPathComponent("pwned").path

        let command = try RemoteSession.attachPaneCommand(
            host: "buildbox", endpoint: endpoint, daemon: daemon,
            session: "build'; touch \(marker); echo '", pane: .left)
        _ = try fake.runShell(command)

        #expect(!FileManager.default.fileExists(atPath: marker), "the name is data, never shell syntax")
    }

    // MARK: - validation

    @Test func emptyHostIsRefused() {
        #expect(throws: RemoteSession.InvocationError.emptyHost) {
            try RemoteSession.treeCommand(host: "")
        }
    }

    @Test(arguments: ["build box", "box\nrm -rf /", "box\u{0}", "-oProxyCommand=touch /tmp/pwned"])
    func hostileHostIsRefused(_ host: String) {
        #expect(throws: RemoteSession.InvocationError.self) {
            try RemoteSession.treeCommand(host: host)
        }
    }

    @Test(arguments: ["agterm 42", "agterm\n42", "", "notes", "agterm-nothex"])
    func anythingButAnAgtermDaemonNameIsRefused(_ name: String) {
        #expect(throws: RemoteSession.InvocationError.invalidSession) {
            try RemoteSession.attachCommand(host: "buildbox", endpoint: endpoint, daemon: name)
        }
    }

    @Test func anEndpointPathMaySpaceButNotCarryControlCharacters() throws {
        let spaced = ControlZmxEndpoint(executable: "/Users/me/My Apps/agterm.app/zmx",
                                        socketDirectory: "/tmp/x")
        #expect(throws: Never.self) {
            try RemoteSession.attachCommand(host: "buildbox", endpoint: spaced, daemon: daemon)
        }
        let broken = ControlZmxEndpoint(executable: "/tmp/zmx\n", socketDirectory: "/tmp/x")
        #expect(throws: RemoteSession.InvocationError.invalidEndpoint) {
            try RemoteSession.attachCommand(host: "buildbox", endpoint: broken, daemon: daemon)
        }
    }
}

/// Runs the remote half of an invocation through `/bin/sh` against recording stand-ins, so a quoting or
/// ordering regression fails rather than passing a substring check.
private struct FakeRemote {
    let root: URL
    private let log: URL
    private let zmxDirLog: URL
    private let zmxEnvLog: URL

    init(directoryName: String = "fake-remote-\(UUID().uuidString)") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        log = root.appendingPathComponent("calls.log")
        zmxDirLog = root.appendingPathComponent("zmxdir.log")
        zmxEnvLog = root.appendingPathComponent("zmxenv.log")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // the command under test appends the REAL install directories to PATH, so a test that forgets
        // `installAgtermctl` would otherwise resolve the machine's own CLI and drive the live terminal.
        // this sentinel makes that fail here instead of reaching outside the fixture.
        try write(name: "agtermctl", script: """
        printf '%s\\n' 'fake-remote: no agtermctl installed for this test' >&2
        exit 99
        """)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// Exits with `exitCodes[n]` on its nth call, so a chain can be failed at a chosen stage.
    func installAgtermctl(exitCodes: [Int32]) throws {
        let cases = exitCodes.enumerated()
            .map { "  \($0.offset)) exit \($0.element) ;;" }
            .joined(separator: "\n")
        try write(name: "agtermctl", script: """
        \(recordArguments)
        n=$(grep -c '^\(Self.callSeparator)$' '\(log.path)')
        case $((n - 1)) in
        \(cases)
        esac
        exit 0
        """)
    }

    /// Stands in for ssh by running its LAST argument through a shell, which is what the real one does
    /// with the remote command.
    func installSSH(exitCode: Int32? = nil) throws {
        let body = exitCode.map { "exit \($0)" } ?? #"/bin/sh -c "$last""#
        try write(name: "ssh", script: """
        for a in "$@"; do last=$a; done
        \(body)
        """)
    }

    func installZmx() throws -> String {
        try write(name: "zmx", script: """
        \(recordArguments)
        printf '%s\\n' "$ZMX_DIR" >> '\(zmxDirLog.path)'
        printf 'session=[%s] prefix=[%s] nodetach=[%s]\\n' \\
          "${ZMX_SESSION-MISSING}" "${ZMX_SESSION_PREFIX-MISSING}" "${ZMX_NO_DETACH_KEY-MISSING}" \\
          >> '\(zmxEnvLog.path)'
        """)
        return root.appendingPathComponent("zmx").path
    }

    /// One line per argument, so an argument containing spaces stays one argument. `"$*"` would flatten
    /// the guard script into words and let a broken argv pass.
    private var recordArguments: String {
        """
        for a in "$@"; do printf '%s\\n' "$a" >> '\(log.path)'; done
        printf '%s\\n' '\(Self.callSeparator)' >> '\(log.path)'
        """
    }

    private static let callSeparator = "<<<agterm-call>>>"

    /// `shell` stands in for the far side's login shell, which is what sshd actually runs the remote
    /// command through — not necessarily a POSIX one.
    func runRemote(_ argv: [String], shell: String = "/bin/sh",
                   exporting extra: [String: String] = [:]) throws -> (status: Int32, stdout: String) {
        try runShell(try #require(argv.last), shell: shell, exporting: extra)
    }

    /// The fake's directory goes FIRST, ahead of the real install locations the command under test
    /// appends, so these never resolve the machine's own agtermctl and drive the live terminal.
    func runShell(_ remote: String, shell: String = "/bin/sh",
                  exporting extra: [String: String] = [:]) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", remote]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = root.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func calls() throws -> [[String]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        var calls: [[String]] = []
        var current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            if line == Self.callSeparator {
                calls.append(current)
                current = []
                continue
            }
            current.append(String(line))
        }
        return calls
    }

    func recordedZmxDir() throws -> String {
        try String(contentsOf: zmxDirLog, encoding: .utf8).trimmingCharacters(in: .newlines)
    }

    /// The zmx session variables as the invoked zmx saw them; `MISSING` marks one the argv never set.
    func recordedZmxSessionEnv() throws -> String {
        try String(contentsOf: zmxEnvLog, encoding: .utf8).trimmingCharacters(in: .newlines)
    }

    private func write(name: String, script: String) throws {
        let url = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
