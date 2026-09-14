import Foundation
import Testing
@testable import agtermCore

struct TerminfoInstallTests {
    private let fixture: Fixture

    init() throws { fixture = try Fixture() }

    // MARK: - where the entry comes from

    @Test func bundleNextToTheClientWinsOverTheEnvironment() throws {
        let bundle = try fixture.bundle(layout: "78")
        let env = try fixture.database(name: "env", layout: "x")

        let directory = TerminfoInstall.terminfoDirectory(clientPath: bundle.client, environment: ["TERMINFO": env])

        #expect(directory == bundle.terminfo)
    }

    @Test func environmentIsTheFallbackWhenTheClientHasNoBundle() throws {
        let env = try fixture.database(name: "env", layout: "x")
        let loose = fixture.root.appendingPathComponent("build/debug/agtermctl").path

        #expect(TerminfoInstall.terminfoDirectory(clientPath: loose, environment: ["TERMINFO": env]) == env)
        #expect(TerminfoInstall.terminfoDirectory(clientPath: nil, environment: ["TERMINFO": env]) == env)
    }

    @Test func aDirectoryWithoutTheEntryIsSkipped() throws {
        let empty = fixture.root.appendingPathComponent("empty").path
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)

        #expect(TerminfoInstall.terminfoDirectory(clientPath: nil, environment: ["TERMINFO": empty]) == nil)
        #expect(TerminfoInstall.terminfoDirectory(clientPath: nil, environment: [:]) == nil)
        #expect(TerminfoInstall.candidateDirectories(clientPath: nil, environment: ["TERMINFO": ""]).isEmpty)
    }

    @Test func dumpAsksForExtendedCapabilitiesFromTheChosenDatabaseOnly() {
        let command = TerminfoInstall.dumpCommand(terminfoDirectory: "/db")

        #expect(command.argv == ["/usr/bin/infocmp", "-x", "xterm-ghostty"])
        #expect(command.environment == ["TERMINFO": "/db"])
    }

    // MARK: - the ssh invocation

    @Test func installMapsEveryConnectionOptionAfterTheExecutionSettings() throws {
        let connection = TerminfoInstall.Connection(destination: "me@buildbox", port: 2222, identities: ["/k1", "/k2"],
                                                    jump: "bastion", config: "/cfg")

        let argv = try TerminfoInstall.installCommand(connection)

        #expect(argv.first == "ssh")
        #expect(Array(argv.dropFirst().prefix(TerminfoInstall.executionOptions.count)) == TerminfoInstall.executionOptions)
        #expect(Array(argv.dropFirst(1 + TerminfoInstall.executionOptions.count).dropLast())
                == ["-p", "2222", "-i", "/k1", "-i", "/k2", "-J", "bastion", "-F", "/cfg", "me@buildbox"])
    }

    @Test func installWithNoOptionsIsJustTheDestination() throws {
        let argv = try TerminfoInstall.installCommand(TerminfoInstall.Connection(destination: "buildbox"))

        #expect(Array(argv.dropFirst(1 + TerminfoInstall.executionOptions.count)) == ["buildbox", argv.last ?? ""])
    }

    // a host block can set the four execution settings the other way; the real ssh resolves precedence
    @Test func installOverridesTheExecutionSettingsAConfigFileSets() throws {
        let hostile = fixture.root.appendingPathComponent("hostile.sshconfig")
        try """
        Host *
          RequestTTY yes
          StdinNull yes
          SessionType none
          ForkAfterAuthentication yes
          RemoteCommand tmux attach
        """.write(to: hostile, atomically: true, encoding: .utf8)
        let argv = try TerminfoInstall.installCommand(TerminfoInstall.Connection(destination: "example.invalid", config: hostile.path),
                                                      ssh: "/usr/bin/ssh")

        let resolved = try fixture.run("/usr/bin/ssh", arguments: ["-G"] + argv.dropFirst())

        #expect(resolved.status == 0, Comment(rawValue: resolved.stderr))
        let settings = Dictionary(resolved.stdout.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: " ", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { first, _ in first })
        #expect(settings["requesttty"] == "false")
        #expect(settings["stdinnull"] == "no")
        #expect(settings["sessiontype"] == "default")
        #expect(settings["forkafterauthentication"] == "no")
        #expect(settings["remotecommand"] == nil)
    }

    @Test func theRemoteCommandIsOneQuotedShInvocationOnOneLine() throws {
        let remote = try #require(TerminfoInstall.installCommand(TerminfoInstall.Connection(destination: "buildbox")).last)

        #expect(remote.hasPrefix("'/bin/sh' '-c' '"))
        #expect(!remote.contains("\n"))
    }

    // sshd hands the command to the account's login shell, so it must parse under every common one
    @Test(arguments: ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/tcsh", "/bin/csh"])
    func theRemoteCommandCompilesTheSourceUnderEveryLoginShell(_ shell: String) throws {
        let remote = try #require(TerminfoInstall.installCommand(TerminfoInstall.Connection(destination: "buildbox")).last)
        let home = try fixture.remoteHome(withTic: true)

        let run = try fixture.run(shell, arguments: ["-c", remote], stdin: "xterm-ghostty|test,\n", environment: home.environment)

        #expect(run.status == 0, Comment(rawValue: run.stderr))
        #expect(try fixture.ticArguments() == ["-x", "-o", "\(home.path)/.terminfo", "-"])
        #expect(try fixture.ticStdin() == "xterm-ghostty|test,\n")
        #expect(FileManager.default.fileExists(atPath: "\(home.path)/.terminfo"))
    }

    @Test(arguments: ["/bin/sh", "/bin/tcsh"])
    func theRemoteCommandSaysSoAndExits3WhenTheHostHasNoTic(_ shell: String) throws {
        let remote = try #require(TerminfoInstall.installCommand(TerminfoInstall.Connection(destination: "buildbox")).last)
        let home = try fixture.remoteHome(withTic: false)

        let run = try fixture.run(shell, arguments: ["-c", remote], stdin: "unused", environment: home.environment)

        #expect(run.status == 3)
        #expect(run.stderr.contains("tic is not installed on this host"))
        #expect(!FileManager.default.fileExists(atPath: "\(home.path)/.terminfo"))
    }

    @Test(arguments: ["", "-G", "-N", "host name", "host\tname", "\u{1b}host"])
    func anOptionLookingOrUnprintableDestinationIsRefused(_ destination: String) {
        #expect(throws: TerminfoInstall.Failure.invalidDestination) {
            try TerminfoInstall.installCommand(TerminfoInstall.Connection(destination: destination))
        }
    }

    // MARK: - the pipeline, with fake executables

    @Test func theDumpReachesSshStdinByteForByteAndEndsInEOF() throws {
        let env = try fixture.database(name: "env", layout: "78")
        let infocmp = try fixture.fakeInfocmp(printing: "xterm-ghostty|test,\n\tcols#80,\n")
        let ssh = try fixture.fakeSSH(exitCode: 0)

        let outcome = try TerminfoInstall.run(TerminfoInstall.Connection(destination: "buildbox"), clientPath: nil,
                                              environment: ["TERMINFO": env], ssh: ssh, infocmp: infocmp)

        #expect(outcome == .exited(0))
        #expect(try fixture.sshStdin() == "xterm-ghostty|test,\n\tcols#80,\n")
        #expect(try fixture.sshArguments().first == "-T")
        #expect(try fixture.sshArguments().contains("buildbox"))
    }

    @Test func aFailedDumpNeverStartsSsh() throws {
        let env = try fixture.database(name: "env", layout: "78")
        let infocmp = try fixture.fakeInfocmp(failingWith: "infocmp: no terminfo file for xterm-ghostty")
        let ssh = try fixture.fakeSSH(exitCode: 0)

        #expect(throws: TerminfoInstall.Failure.dumpFailed(status: 1, stderr: "infocmp: no terminfo file for xterm-ghostty\n")) {
            try TerminfoInstall.run(TerminfoInstall.Connection(destination: "buildbox"), clientPath: nil,
                                    environment: ["TERMINFO": env], ssh: ssh, infocmp: infocmp)
        }
        #expect(!fixture.sshWasCalled())
    }

    @Test func aMissingEntryNeverStartsAnything() throws {
        let infocmp = try fixture.fakeInfocmp(printing: "unused")
        let ssh = try fixture.fakeSSH(exitCode: 0)

        #expect(throws: TerminfoInstall.Failure.terminfoNotFound(searched: [])) {
            try TerminfoInstall.run(TerminfoInstall.Connection(destination: "buildbox"), clientPath: nil,
                                    environment: [:], ssh: ssh, infocmp: infocmp)
        }
        #expect(!fixture.sshWasCalled())
    }

    @Test func aNonZeroRemoteStatusIsReportedAsItself() throws {
        let env = try fixture.database(name: "env", layout: "78")
        let infocmp = try fixture.fakeInfocmp(printing: "x")
        let ssh = try fixture.fakeSSH(exitCode: 3)

        let outcome = try TerminfoInstall.run(TerminfoInstall.Connection(destination: "buildbox"), clientPath: nil,
                                              environment: ["TERMINFO": env], ssh: ssh, infocmp: infocmp)

        #expect(outcome == .exited(3))
    }

    // ssh prompts on the controlling tty, and a child in its own process group is stopped for that
    @Test func sshStaysInTheCallersProcessGroup() throws {
        let env = try fixture.database(name: "env", layout: "78")
        let infocmp = try fixture.fakeInfocmp(printing: "x")
        let ssh = try fixture.fakeSSH(exitCode: 0, recordingProcessGroup: true)

        let outcome = try TerminfoInstall.run(TerminfoInstall.Connection(destination: "buildbox"), clientPath: nil,
                                              environment: ["TERMINFO": env, "PATH": "/bin:/usr/bin"], ssh: ssh, infocmp: infocmp)

        #expect(outcome == .exited(0))
        #expect(try fixture.sshProcessGroup() == getpgrp())
    }

    // a pipe end inherited from a concurrent spawn keeps the other child's stdin open past its EOF
    @Test func sshInheritsNoDescriptorBeyondItsStandardThree() throws {
        let env = try fixture.database(name: "env", layout: "78")
        let infocmp = try fixture.fakeInfocmp(printing: "x")
        var stray: [Int32] = [-1, -1]
        try #require(pipe(&stray) == 0)
        defer { close(stray[0]); close(stray[1]) }
        let ssh = try fixture.fakeSSH(exitCode: 0, probingDescriptor: stray[1])

        let outcome = try TerminfoInstall.run(TerminfoInstall.Connection(destination: "buildbox"), clientPath: nil,
                                              environment: ["TERMINFO": env, "PATH": "/bin:/usr/bin"], ssh: ssh, infocmp: infocmp)

        #expect(outcome == .exited(0))
        #expect(try fixture.sshDescriptorProbe() == "absent")
    }

    // the spawning thread's mask is inherited, and a test worker blocks signals
    @Test func sshStartsWithSignalsUnblockedWhateverTheCallerBlocks() throws {
        let env = try fixture.database(name: "env", layout: "78")
        let infocmp = try fixture.fakeInfocmp(printing: "x")
        let ssh = try fixture.fakeSSH(exitCode: 0, terminatingItself: true)
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTERM)
        var previous = sigset_t()
        try #require(pthread_sigmask(SIG_BLOCK, &blocked, &previous) == 0)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }

        let outcome = try TerminfoInstall.run(TerminfoInstall.Connection(destination: "buildbox"), clientPath: nil,
                                              environment: ["TERMINFO": env, "PATH": "/bin:/usr/bin"], ssh: ssh, infocmp: infocmp)

        #expect(outcome == .signaled(SIGTERM))
    }

    @Test func anSshThatExitsBeforeReadingStdinStillReportsItsStatus() throws {
        let env = try fixture.database(name: "env", layout: "78")
        // larger than a pipe buffer, so the write would block or EPIPE against a reader that has gone
        let infocmp = try fixture.fakeInfocmp(printing: String(repeating: "x", count: 1 << 17))
        let ssh = try fixture.fakeSSH(exitCode: 255, readsStdin: false)

        let outcome = try TerminfoInstall.run(TerminfoInstall.Connection(destination: "buildbox"), clientPath: nil,
                                              environment: ["TERMINFO": env], ssh: ssh, infocmp: infocmp)

        #expect(outcome == .exited(255))
    }

    // MARK: - the real infocmp against a real compiled entry

    @Test func theRealInfocmpDumpsAnEntryTicCompiled() throws {
        let db = try fixture.compiledDatabase(source: "xterm-ghostty|agterm test entry,\n\tcols#80, lines#24,\n")
        let ssh = try fixture.fakeSSH(exitCode: 0)

        let outcome = try TerminfoInstall.run(TerminfoInstall.Connection(destination: "buildbox"), clientPath: nil,
                                              environment: ["TERMINFO": db], ssh: ssh)

        #expect(outcome == .exited(0))
        let dumped = try fixture.sshStdin()
        #expect(dumped.contains("xterm-ghostty|agterm test entry"))
        #expect(dumped.contains("cols#80"))
    }
}

/// A temp root holding fake `ssh`/`infocmp` scripts, a fake bundle, and what the fakes recorded.
private struct Fixture {
    let root: URL
    private var sshArgs: URL { root.appendingPathComponent("ssh.args") }
    private var sshInput: URL { root.appendingPathComponent("ssh.stdin") }
    private var sshGroup: URL { root.appendingPathComponent("ssh.pgid") }
    private var sshDescriptor: URL { root.appendingPathComponent("ssh.fd") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("terminfo-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// `<root>/<name>/<layout>/xterm-ghostty`, an empty file where the entry would sit.
    func database(name: String, layout: String) throws -> String {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(layout), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("\(layout)/xterm-ghostty"))
        return dir.path
    }

    /// The bundle shape the installed CLI resolves into: `Contents/MacOS/agtermctl` beside
    /// `Contents/Resources/terminfo`.
    func bundle(layout: String) throws -> (client: String, terminfo: String) {
        let contents = root.appendingPathComponent("agterm.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let client = contents.appendingPathComponent("MacOS/agtermctl")
        try Data().write(to: client)
        let terminfo = try database(name: "agterm.app/Contents/Resources/terminfo", layout: layout)
        return (client.path, terminfo)
    }

    /// A database the real `tic` compiled from `source`, so the real `infocmp` has something to dump.
    func compiledDatabase(source: String) throws -> String {
        let dir = root.appendingPathComponent("compiled")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tic = Process()
        tic.executableURL = URL(fileURLWithPath: "/usr/bin/tic")
        tic.arguments = ["-x", "-o", dir.path, "-"]
        let stdin = Pipe()
        tic.standardInput = stdin
        tic.standardError = Pipe()
        try tic.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(source.utf8))
        try stdin.fileHandleForWriting.close()
        tic.waitUntilExit()
        try #require(tic.terminationStatus == 0, "tic could not compile the fixture entry")
        return dir.path
    }

    func fakeInfocmp(printing output: String) throws -> String {
        let file = root.appendingPathComponent("infocmp.out")
        try Data(output.utf8).write(to: file)
        return try script(named: "infocmp", body: "cat '\(file.path)'")
    }

    func fakeInfocmp(failingWith message: String) throws -> String {
        try script(named: "infocmp", body: "printf '%s\\n' '\(message)' >&2; exit 1")
    }

    /// Records its arguments one per line and, unless told not to, copies stdin to a file.
    func fakeSSH(exitCode: Int32, readsStdin: Bool = true, recordingProcessGroup: Bool = false,
                 probingDescriptor: Int32? = nil, terminatingItself: Bool = false) throws -> String {
        let read = readsStdin ? "cat > '\(sshInput.path)'" : ""
        let group = recordingProcessGroup ? "ps -o pgid= -p $$ | tr -d ' ' > '\(sshGroup.path)'" : ""
        let probe = probingDescriptor.map {
            "if [ -e /dev/fd/\($0) ]; then echo inherited; else echo absent; fi > '\(sshDescriptor.path)'"
        } ?? ""
        let terminate = terminatingItself ? "kill -TERM $$" : ""
        return try script(named: "ssh", body: """
        printf '%s\\n' "$@" > '\(sshArgs.path)'
        \(group)
        \(probe)
        \(terminate)
        \(read)
        exit \(exitCode)
        """)
    }

    func sshDescriptorProbe() throws -> String {
        try String(contentsOf: sshDescriptor, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sshProcessGroup() throws -> pid_t {
        let text = try String(contentsOf: sshGroup, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(text), "pgid recorded as '\(text)'")
    }

    /// A stand-in for the remote account: an empty `HOME` and a `PATH` of `/bin` (mkdir, but no tic:
    /// the real one is in `/usr/bin`) plus a fake `tic` that records its arguments and stdin, or none.
    func remoteHome(withTic: Bool) throws -> (path: String, environment: [String: String]) {
        let home = root.appendingPathComponent("remote-home")
        let bin = root.appendingPathComponent("remote-bin")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if withTic {
            try script(at: bin.appendingPathComponent("tic"), body: """
            printf '%s\\n' "$@" > '\(root.appendingPathComponent("tic.args").path)'
            cat > '\(root.appendingPathComponent("tic.stdin").path)'
            """)
        }
        return (home.path, ["HOME": home.path, "PATH": bin.path + ":/bin"])
    }

    func ticArguments() throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("tic.args"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func ticStdin() throws -> String { try String(contentsOf: root.appendingPathComponent("tic.stdin"), encoding: .utf8) }

    /// Runs one executable with captured output, an optional stdin body and an optional whole environment.
    func run(_ executable: String, arguments: [String], stdin: String? = nil,
             environment: [String: String]? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        process.standardInput = input
        try process.run()
        if let stdin { try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }

    func sshArguments() throws -> [String] {
        try String(contentsOf: sshArgs, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func sshStdin() throws -> String { try String(contentsOf: sshInput, encoding: .utf8) }

    func sshWasCalled() -> Bool { FileManager.default.fileExists(atPath: sshArgs.path) }

    private func script(named name: String, body: String) throws -> String {
        try script(at: root.appendingPathComponent(name), body: body)
    }

    @discardableResult
    private func script(at file: URL, body: String) throws -> String {
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }
}
