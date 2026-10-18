import AgtermResponsibility
import AppKit
import Darwin
import XCTest
import agtermCore
@testable import agterm

@MainActor
final class SessionHostFishSeamTests: XCTestCase {
    private var fixtures: [Fixture] = []

    override func tearDown() {
        for fixture in fixtures.reversed() { fixture.cleanup() }
        fixtures = []
        super.tearDown()
    }

    func testCapturedArgvPayloadLandsOnIntegratedFish() throws {
        let fish = try FishInstallation.resolve()
        try forEachAttachVariant(fish) { fixture, supervised in
            let log = fixture.directory.appendingPathComponent("captured-argv")
            let probe = try fixture.payloadProbe(named: "captured", log: log, exitCode: 0)
            let command = [probe.path, "two words", "", "$literal"]
            let configuration = try fixture.configuration(supervised: supervised)
            let attachment = try fixture.attach(configuration, session: fixture.session(.captured, command: command))
            let record = try fixture.acknowledge(attachment, token: UUID().uuidString)
            fixture.assertFinalPrompt(record)
            XCTAssertEqual(try fixture.argv(in: log), command)
        }
    }

    func testFailingPayloadsStillLandOnIntegratedFish() throws {
        let fish = try FishInstallation.resolve()
        for failure in FailureCase.allCases {
            try forEachAttachVariant(fish) { fixture, supervised in
                let command: [String]
                let log: URL?
                switch failure {
                case .missingCommand:
                    command = [fixture.directory.appendingPathComponent("does-not-exist").path]
                    log = nil
                case .exitThree:
                    let output = fixture.directory.appendingPathComponent("\(failure.rawValue)-argv")
                    let probe = try fixture.payloadProbe(named: failure.rawValue, log: output, exitCode: 3)
                    command = [probe.path, "fails"]
                    log = output
                }
                let configuration = try fixture.configuration(supervised: supervised)
                let attachment = try fixture.attach(configuration, session: fixture.session(.captured, command: command))
                let record = try fixture.acknowledge(attachment, token: UUID().uuidString)
                fixture.assertFinalPrompt(record)
                if let log {
                    XCTAssertEqual(try fixture.argv(in: log), command)
                }
            }
        }
    }

    func testDurableCreationCommandLandsOnIntegratedFish() throws {
        let fish = try FishInstallation.resolve()
        try forEachAttachVariant(fish) { fixture, supervised in
            let log = fixture.directory.appendingPathComponent("durable-argv")
            let probe = try fixture.payloadProbe(named: "durable", log: log, exitCode: 0)
            let command = [probe.path, "durable value"]
            let configuration = try fixture.configuration(supervised: supervised)
            let attachment = try fixture.attach(configuration, session: fixture.session(.durable, command: command))
            let record = try fixture.acknowledge(attachment, token: UUID().uuidString)
            fixture.assertFinalPrompt(record)
            XCTAssertEqual(try fixture.argv(in: log), command)
        }
    }

    func testCapturedArgvPayloadOwnsPaneForeground() throws {
        let fish = try FishInstallation.resolve()
        try forEachAttachVariant(fish) { fixture, supervised in
            try fixture.assertPayloadForeground(.captured, supervised: supervised)
        }
    }

    func testDurableCreationCommandOwnsPaneForeground() throws {
        let fish = try FishInstallation.resolve()
        try forEachAttachVariant(fish) { fixture, supervised in
            try fixture.assertPayloadForeground(.durable, supervised: supervised)
        }
    }

    func testSurvivingDaemonDoesNotReplayCapturedPayloadOnBareAttach() throws {
        let fish = try FishInstallation.resolve()
        try assertSurvivingDaemonDoesNotReplayPayload(fish, kind: .captured, supervised: false)
    }

    func testSurvivingDaemonDoesNotReplayCapturedPayloadOnSupervisedAttach() throws {
        let fish = try FishInstallation.resolve()
        try assertSurvivingDaemonDoesNotReplayPayload(fish, kind: .captured, supervised: true)
    }

    func testSurvivingDaemonDoesNotReplayFailingPayloadOnBareAttach() throws {
        let fish = try FishInstallation.resolve()
        try assertSurvivingDaemonDoesNotReplayPayload(fish, kind: .failing, supervised: false)
    }

    func testSurvivingDaemonDoesNotReplayFailingPayloadOnSupervisedAttach() throws {
        let fish = try FishInstallation.resolve()
        try assertSurvivingDaemonDoesNotReplayPayload(fish, kind: .failing, supervised: true)
    }

    func testSurvivingDaemonDoesNotReplayDurablePayloadOnBareAttach() throws {
        let fish = try FishInstallation.resolve()
        try assertSurvivingDaemonDoesNotReplayPayload(fish, kind: .durable, supervised: false)
    }

    func testSurvivingDaemonDoesNotReplayDurablePayloadOnSupervisedAttach() throws {
        let fish = try FishInstallation.resolve()
        try assertSurvivingDaemonDoesNotReplayPayload(fish, kind: .durable, supervised: true)
    }

    func testKilledDaemonStartsNewFishAndRunsPayloadOnce() throws {
        let fish = try FishInstallation.resolve()
        try forEachAttachVariant(fish) { fixture, supervised in
            let firstLog = fixture.directory.appendingPathComponent("before-kill")
            let firstProbe = try fixture.payloadProbe(named: "before-kill", log: firstLog, exitCode: 0)
            let configuration = try fixture.configuration(supervised: supervised)
            let first = try fixture.attach(configuration, session: fixture.session(.captured, command: [firstProbe.path]))
            let firstRecord = try fixture.acknowledge(first, token: UUID().uuidString)
            fixture.assertFinalPrompt(firstRecord)
            let firstLeader = try fixture.assertDaemon(configuration, supervised: supervised)
            XCTAssertEqual(try fixture.argv(in: firstLog), [firstProbe.path])

            try fixture.killDaemon(configuration, leader: firstLeader)

            let secondLog = fixture.directory.appendingPathComponent("after-kill")
            let secondProbe = try fixture.payloadProbe(named: "after-kill", log: secondLog, exitCode: 0)
            let second = try fixture.attach(configuration, session: fixture.session(.captured, command: [secondProbe.path]))
            let secondRecord = try fixture.acknowledge(second, token: UUID().uuidString)
            fixture.assertFinalPrompt(secondRecord)
            XCTAssertNotEqual(secondRecord.fishPID, firstRecord.fishPID)
            XCTAssertNotEqual(try fixture.assertDaemon(configuration, supervised: supervised), firstLeader)
            XCTAssertEqual(try fixture.argv(in: secondLog), [secondProbe.path])
        }
    }

    func testPlainLoginShellStartsIntegratedFish() throws {
        let fish = try FishInstallation.resolve()
        try requireOrSkip(ZmxLaunch.passwordDatabaseLoginShell().map(CommandRestore.basename) == "fish",
                          "The password-database login shell must be fish")
        try forEachAttachVariant(fish) { fixture, supervised in
            let configuration = try fixture.configuration(supervised: supervised)
            let session = fixture.session(.plain, command: [])
            let seed = try XCTUnwrap(ZmxLaunch.surfaceSeed(disposition: .wrapped(configuration), session: session,
                                                            pane: .left, denylist: []))
            XCTAssertEqual(seed.command, ZmxSupport.attachCommand(configuration, replaying: nil, denylist: []))
            let attachment = try fixture.attach(configuration, session: session, seed: seed)
            let record = try fixture.acknowledge(attachment, token: UUID().uuidString)
            fixture.assertFinalPrompt(record)
        }
    }

    private func forEachAttachVariant(_ fish: FishInstallation,
                                      _ body: (Fixture, Bool) throws -> Void) throws {
        try requireOrSkip(Responsibility.system.isAvailable, "Required responsibility symbols are absent")
        for supervised in [false, true] {
            let fixture = try Fixture(fish: fish)
            fixtures.append(fixture)
            try body(fixture, supervised)
        }
    }

    private func assertSurvivingDaemonDoesNotReplayPayload(_ fish: FishInstallation,
                                                           kind: PayloadKind, supervised: Bool) throws {
        try requireOrSkip(Responsibility.system.isAvailable, "Required responsibility symbols are absent")
        let fixture = try Fixture(fish: fish)
        fixtures.append(fixture)
        let firstLog = fixture.directory.appendingPathComponent("\(kind.rawValue)-first")
        let firstProbe = try fixture.payloadProbe(named: "\(kind.rawValue)-first", log: firstLog,
                                                  exitCode: kind == .failing ? 3 : 0)
        let firstCommand = [firstProbe.path, "first"]
        let configuration = try fixture.configuration(supervised: supervised)
        let first = try fixture.attach(configuration, session: fixture.session(kind.creation, command: firstCommand))
        let firstRecord = try fixture.acknowledge(first, token: UUID().uuidString)
        fixture.assertFinalPrompt(firstRecord)
        XCTAssertEqual(try fixture.argv(in: firstLog), firstCommand)
        let firstLeader = try fixture.assertDaemon(configuration, supervised: supervised)

        fixture.detach(first)
        try fixture.waitForZeroClients(configuration, leader: firstLeader)

        let secondLog = fixture.directory.appendingPathComponent("\(kind.rawValue)-second")
        let secondProbe = try fixture.payloadProbe(named: "\(kind.rawValue)-second", log: secondLog,
                                                   exitCode: kind == .failing ? 3 : 0)
        let second = try fixture.attach(configuration,
                                        session: fixture.session(kind.creation, command: [secondProbe.path, "second"]))
        let secondRecord = try fixture.acknowledge(second, token: UUID().uuidString)
        fixture.assertFinalPrompt(secondRecord)
        XCTAssertEqual(secondRecord.fishPID, firstRecord.fishPID)
        XCTAssertEqual(try fixture.assertDaemon(configuration, supervised: supervised), firstLeader)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondLog.path))
    }

    private func requireOrSkip(_ condition: Bool, _ message: String) throws {
        guard !condition else { return }
        if ProcessInfo.processInfo.environment["AGTERM_REQUIRE_FISH_LOGIN_SHELL"] != nil {
            XCTFail(message)
            throw POSIXError(.ENOENT)
        }
        try XCTSkipUnless(condition, message)
    }

    private enum FailureCase: String, CaseIterable {
        case missingCommand
        case exitThree
    }

    private enum Creation {
        case captured
        case durable
        case plain
    }

    private enum PayloadKind: String, CaseIterable {
        case captured
        case failing
        case durable

        var creation: Creation {
            switch self {
            case .captured, .failing: .captured
            case .durable: .durable
            }
        }
    }

    private struct FishInstallation {
        let path: String

        static func resolve() throws -> FishInstallation {
            let environment = ProcessInfo.processInfo.environment
            let path: String?
            if let override = environment["AGTERM_TEST_FISH"] {
                path = override
            } else if let fromPath = (environment["PATH"] ?? "").split(separator: ":")
                .map(String.init)
                .map({ URL(fileURLWithPath: $0).appendingPathComponent("fish").path })
                .first(where: FileManager.default.isExecutableFile) {
                path = fromPath
            } else if let shell = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_shell) }),
                      URL(fileURLWithPath: shell).lastPathComponent == "fish",
                      FileManager.default.isExecutableFile(atPath: shell) {
                path = shell
            } else if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/fish") {
                path = "/opt/homebrew/bin/fish"
            } else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/fish") {
                path = "/usr/local/bin/fish"
            } else {
                path = nil
            }
            guard let path else {
                if ProcessInfo.processInfo.environment["AGTERM_REQUIRE_FISH"] != nil {
                    XCTFail("AGTERM_REQUIRE_FISH is set but fish is absent from PATH")
                    throw POSIXError(.ENOENT)
                }
                throw XCTSkip("fish is absent from PATH")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw POSIXError(.ETIMEDOUT) }
            let version = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !version.isEmpty else { throw POSIXError(.ENOEXEC) }
            NSLog("Resolved fish at %@: %@", path, version)
            return FishInstallation(path: path)
        }
    }

    private struct PromptRecord {
        let login: String
        let interactive: String
        let xdgDataDirs: String
        let integrationDirectory: String
        let promptMarker: String
        let cwdHook: String
        let cwd: String
        let fishPID: Int32
        let lastLine: String
    }

    private struct Attachment {
        let surface: GhosttySurfaceView
        let window: NSWindow
    }

    @MainActor private final class Fixture {
        let directory = URL(fileURLWithPath: "/tmp/shf-\(UUID().uuidString)")
        let paneID = UUID()
        let executable: URL
        let zmx: URL
        let resources: URL
        let configHome: URL
        let paths: SessionHost.Paths
        var physicalDirectory = ""
        let fish: FishInstallation
        let promptLog: URL
        let userXDGDataDirs = "/fish-user/one:/fish-user/two"
        var surfaces: [GhosttySurfaceView] = []
        var windows: [NSWindow] = []
        var hostPID: Int32?

        init(fish: FishInstallation) throws {
            self.fish = fish
            let bundle = directory.appendingPathComponent("FishSeam.app")
            executable = bundle.appendingPathComponent("Contents/MacOS/agterm-session-host")
            zmx = bundle.appendingPathComponent("Contents/MacOS/zmx")
            resources = bundle.appendingPathComponent("Contents/Resources/ghostty")
            configHome = directory.appendingPathComponent("config")
            promptLog = directory.appendingPathComponent("fish-prompts")
            paths = try SessionHost.paths(socketDirectory: ZmxSupport.socketDirectory(forStateDirectory: directory.path))
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let physical = try XCTUnwrap(realpath(directory.path, nil))
                physicalDirectory = String(cString: physical)
                free(physical)
                try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: configHome.appendingPathComponent("fish"),
                                                        withIntermediateDirectories: true)
                let integration = resources.appendingPathComponent("shell-integration/fish/vendor_conf.d")
                try FileManager.default.createDirectory(at: integration, withIntermediateDirectories: true)
                let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                try FileManager.default.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agterm-session-host"),
                                                 to: executable)
                try FileManager.default.copyItem(at: repository.appendingPathComponent("agterm/Resources/zmx/zmx"), to: zmx)
                try FileManager.default.copyItem(
                    at: repository.appendingPathComponent("agterm/Resources/ghostty/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish"),
                    to: integration.appendingPathComponent("ghostty-shell-integration.fish")
                )
                let info = ["CFBundleIdentifier": "com.umputun.fishseam.\(UUID().uuidString)",
                            "CFBundleExecutable": "agterm-session-host"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
                try fishConfig().write(to: configHome.appendingPathComponent("fish/config.fish"), atomically: true,
                                       encoding: .utf8)
            } catch {
                cleanup()
                throw error
            }
        }

        func configuration(supervised: Bool) throws -> ZmxSupport.Configuration {
            let root = resources.appendingPathComponent("shell-integration").path
            let rawDataDirectories = "\(root):/fish-user/one::/fish-user/two:\(root)"
            let environment = [
                "HOME": directory.path,
                "XDG_CONFIG_HOME": configHome.path,
                "XDG_DATA_HOME": directory.appendingPathComponent("data").path,
                "XDG_DATA_DIRS": rawDataDirectories,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "FISH_SEAM_PROMPT_LOG": promptLog.path
            ]
            let inputs = ZmxSupport.Inputs(zmxExecutablePath: zmx.path, passwordDatabaseShell: fish.path,
                                           resourcesDirectory: resources.path, stateDirectory: directory.path,
                                           paneIdentity: paneID, baseEnvironment: environment,
                                           inheritedZdotdir: directory.appendingPathComponent("foreign-zdotdir").path,
                                           sessionHostExecutablePath: supervised ? executable.path : nil)
            let configuration = try ZmxSupport.configuration(for: inputs).get()
            XCTAssertEqual(configuration.environment["SHELL"], fish.path)
            XCTAssertEqual(configuration.environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"], root)
            XCTAssertEqual(configuration.environment["XDG_DATA_DIRS"], rawDataDirectories)
            XCTAssertNil(configuration.environment["ZDOTDIR"])
            XCTAssertNil(configuration.environment["GHOSTTY_ZSH_ZDOTDIR"])
            XCTAssertEqual(configuration.environment["AGTERM_PANE_ID"], paneID.uuidString)
            XCTAssertEqual(configuration.environment["ZMX_DIR"], ZmxSupport.socketDirectory(forStateDirectory: directory.path))
            XCTAssertEqual(configuration.environment["ZMX_SESSION"], "")
            XCTAssertEqual(configuration.environment["ZMX_SESSION_PREFIX"], "")
            XCTAssertEqual(configuration.environment["ZMX_NO_DETACH_KEY"], "1")
            return configuration
        }

        func session(_ creation: Creation, command: [String]) -> Session {
            let session = Session(initialCwd: physicalDirectory)
            switch creation {
            case .captured: session.pendingForegroundCommand = command
            case .durable: session.initialCommand = CommandRestore.shellQuotedLine(command)
            case .plain: break
            }
            return session
        }

        func payloadProbe(named: String, log: URL, exitCode: Int32) throws -> URL {
            let probe = directory.appendingPathComponent("\(named)-probe")
            let script = "#!/bin/sh\nprintf '%s\\0' \"$0\" \"$@\" >> \"\(log.path)\"\nexit \(exitCode)\n"
            try script.write(to: probe, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.path)
            return probe
        }

        func attach(_ configuration: ZmxSupport.Configuration, session: Session, seed suppliedSeed: ZmxLaunch.SurfaceSeed? = nil) throws -> Attachment {
            if configuration.sessionHostExecutablePath != nil { try startHost() }
            let carriesPayload = session.pendingForegroundCommand != nil || session.initialCommand != nil
            let seed = try suppliedSeed ?? XCTUnwrap(ZmxLaunch.surfaceSeed(disposition: .wrapped(configuration), session: session,
                                                                            pane: .left, denylist: []))
            if carriesPayload {
                XCTAssertTrue(seed.command.contains(CommandRestore.shellQuotedLine([fish.path, "-lic"])))
            }
            let surface = GhosttySurfaceView(workingDirectory: physicalDirectory, fontSize: 14, command: seed.command,
                                             env: configuration.environment, backedByZmx: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            surface.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
            window.contentView?.addSubview(surface)
            surface.createSurface()
            XCTAssertNotNil(surface.surface)
            surfaces.append(surface)
            windows.append(window)
            return Attachment(surface: surface, window: window)
        }

        func acknowledge(_ attachment: Attachment, token: String) throws -> PromptRecord {
            XCTAssertTrue(attachment.surface.inject(text: "set -gx FISH_SEAM_LAST_LINE \(token)\n"))
            return try waitForPrompt(token)
        }

        func detach(_ attachment: Attachment) {
            attachment.surface.teardown()
            attachment.window.orderOut(nil)
        }

        func assertFinalPrompt(_ record: PromptRecord) {
            XCTAssertEqual(record.login, "yes")
            XCTAssertEqual(record.interactive, "yes")
            XCTAssertEqual(record.xdgDataDirs, userXDGDataDirs)
            XCTAssertTrue(record.integrationDirectory.isEmpty)
            XCTAssertEqual(record.promptMarker, "yes")
            XCTAssertEqual(record.cwdHook, "yes")
            XCTAssertEqual(record.cwd, physicalDirectory)
        }

        func assertPayloadForeground(_ creation: Creation, supervised: Bool) throws {
            let output = directory.appendingPathComponent("foreground-payload")
            let command = ["/usr/bin/tee", output.path]
            let configuration = try configuration(supervised: supervised)
            let attachment = try attach(configuration, session: session(creation, command: command))
            try wait { FileManager.default.fileExists(atPath: output.path) }
            let leader = try assertDaemon(configuration, supervised: supervised)
            let resolver = ZmxForegroundResolver(leaderProvider: { _ in [configuration.daemonName: leader] })
            resolver.refreshIfNeeded()

            XCTAssertEqual(ForegroundProcess.running(for: attachment.surface, shellBasename: "fish", zmxResolver: resolver),
                           .program(command))
        }

        func assertDaemon(_ configuration: ZmxSupport.Configuration, supervised: Bool) throws -> Int32 {
            let record = try XCTUnwrap(try ZmxListParser.parse(runZmx(["list"])).first { $0.name == configuration.daemonName })
            let leader = try XCTUnwrap(record.leaderPID)
            if supervised {
                let declared = try String(contentsOfFile: paths.pidfile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                hostPID = try XCTUnwrap(Int32(declared))
                XCTAssertEqual(Responsibility.system.responsibleProcess(of: leader), hostPID)
            } else {
                XCTAssertEqual(Responsibility.system.responsibleProcess(of: leader),
                               Responsibility.system.responsibleProcess(of: getpid()))
            }
            return leader
        }

        func waitForZeroClients(_ configuration: ZmxSupport.Configuration, leader: Int32) throws {
            try wait {
                let records = try ZmxListParser.parse(runZmx(["list"]))
                return records.first { $0.name == configuration.daemonName }?.clients == 0 && kill(leader, 0) == 0
            }
        }

        func killDaemon(_ configuration: ZmxSupport.Configuration, leader: Int32) throws {
            _ = try runZmx(["kill", configuration.daemonName, "--force"])
            let socket = URL(fileURLWithPath: configuration.socketDirectory).appendingPathComponent(configuration.daemonName).path
            try wait {
                let records = try ZmxListParser.parse(runZmx(["list"]))
                return !records.contains { $0.name == configuration.daemonName }
                    && !FileManager.default.fileExists(atPath: socket) && kill(leader, 0) == -1
            }
        }

        func argv(in log: URL) throws -> [String] {
            let bytes = [UInt8](try Data(contentsOf: log))
            var result: [String] = []
            var start = 0
            for index in bytes.indices where bytes[index] == 0 {
                result.append(String(decoding: bytes[start ..< index], as: UTF8.self))
                start = index + 1
            }
            XCTAssertEqual(start, bytes.count)
            return result
        }

        func cleanup() {
            for surface in surfaces { surface.teardown() }
            let daemon = ZmxSupport.daemonName(for: paneID)
            if zmx.isFileURL, FileManager.default.isExecutableFile(atPath: zmx.path) {
                _ = try? runZmx(["kill", daemon, "--force"])
            }
            if let pid = hostPID { killHostIfOwned(pid) }
            for window in windows { window.close() }
            try? FileManager.default.removeItem(atPath: ZmxSupport.socketDirectory(forStateDirectory: directory.path))
            try? FileManager.default.removeItem(at: directory)
        }

        private func startHost() throws {
            guard hostPID == nil else { return }
            hostPID = try Responsibility.system.spawnDisclaimed(
                executable: executable.path,
                argv: [executable.path, "host", ZmxSupport.socketDirectory(forStateDirectory: directory.path)],
                env: ["HOME": directory.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
            )
            try wait(timeout: 5) { FileManager.default.fileExists(atPath: paths.socket) }
        }

        private func waitForPrompt(_ token: String) throws -> PromptRecord {
            var matching: PromptRecord?
            try wait(timeout: 15) {
                matching = promptRecords().last { $0.lastLine == token }
                return matching != nil
            }
            return try XCTUnwrap(matching)
        }

        private func promptRecords() -> [PromptRecord] {
            guard let text = try? String(contentsOf: promptLog, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 9, let fishPID = Int32(fields[7]) else { return nil }
                return PromptRecord(login: String(fields[0]), interactive: String(fields[1]),
                                    xdgDataDirs: String(fields[2]), integrationDirectory: String(fields[3]),
                                    promptMarker: String(fields[4]), cwdHook: String(fields[5]), cwd: String(fields[6]),
                                    fishPID: fishPID, lastLine: String(fields[8]))
            }
        }

        private func fishConfig() -> String {
            """
            function __fish_seam_probe --on-event fish_prompt
                set -l login no
                status is-login; and set login yes
                set -l interactive no
                status is-interactive; and set interactive yes
                set -l prompt_marker no
                functions -q __ghostty_mark_prompt_start; and set prompt_marker yes
                set -l cwd_hook no
                functions -q __update_cwd_osc; and set cwd_hook yes
                printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \\
                    $login $interactive "$XDG_DATA_DIRS" "$GHOSTTY_SHELL_INTEGRATION_XDG_DIR" \\
                    $prompt_marker $cwd_hook "$PWD" $fish_pid "$FISH_SEAM_LAST_LINE" >> "$FISH_SEAM_PROMPT_LOG"
            end
            """
        }

        private func runZmx(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = zmx
            process.arguments = arguments
            process.environment = ["ZMX_DIR": ZmxSupport.socketDirectory(forStateDirectory: directory.path),
                                   "ZMX_SESSION": "", "ZMX_SESSION_PREFIX": ""]
            process.currentDirectoryURL = directory
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            do {
                try wait(timeout: 5) { !process.isRunning }
            } catch {
                if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
                throw error
            }
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        private func killHostIfOwned(_ pid: Int32) {
            guard kill(pid, 0) == 0 else { return }
            guard let resolved = realpath(executable.path, nil) else {
                XCTFail("Could not resolve the fixture host path for cleanup")
                return
            }
            defer { free(resolved) }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &bytes, UInt32(bytes.count))
            let actual = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            guard length > 0, actual == String(cString: resolved) else {
                XCTFail("Could not verify the fixture host for cleanup")
                return
            }
            kill(pid, SIGKILL)
            let deadline = Date().addingTimeInterval(3)
            while kill(pid, 0) == 0, Date() < deadline {
                var status: Int32 = 0
                _ = waitpid(pid, &status, WNOHANG)
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(kill(pid, 0), -1)
        }

        private func wait(timeout: TimeInterval = 10, until condition: () throws -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if try condition() { return }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            throw POSIXError(.ETIMEDOUT)
        }
    }
}
