import AgtermResponsibility
import Darwin
import XCTest
import agtermCore
@testable import agterm

@MainActor
final class SessionHostSeamTests: XCTestCase {
    func testClientAndBareAttachMatchForCreationPayloadWithCustomZdotdir() throws {
        try assertMatchingPanes(creationPayload: true)
    }

    func testClientAndBareAttachMatchForPlainLoginShellWithCustomZdotdir() throws {
        try XCTSkipUnless(ZmxLaunch.passwordDatabaseLoginShell().map(CommandRestore.basename) == "zsh",
                          "The password-database login shell must be zsh")
        try assertMatchingPanes(creationPayload: false)
    }

    func testEncodingFieldsCompareByValueNotSpelling() throws {
        XCTAssertEqual(try numericEncoding("0"), try numericEncoding("0x0"))
        XCTAssertEqual(try numericEncoding("16"), try numericEncoding("0x10"))
        XCTAssertEqual(try numericEncoding("501"), 501)
    }

    private func numericEncoding(_ value: Substring) throws -> UInt32 {
        let hex = value.hasPrefix("0x")
        return try XCTUnwrap(UInt32(hex ? value.dropFirst(2) : value, radix: hex ? 16 : 10))
    }

    private func assertMatchingPanes(creationPayload: Bool) throws {
        try XCTSkipUnless(Responsibility.system.isAvailable, "Required responsibility symbols are absent")
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let bare = try fixture.capture(supervised: false, creationPayload: creationPayload)
        let mediated = try fixture.capture(supervised: true, creationPayload: creationPayload)
        XCTAssertEqual(bare.metadata, mediated.metadata)
        XCTAssertEqual(bare.metadata["login"], "on")
        XCTAssertEqual(bare.metadata["interactive"], "on")
        XCTAssertEqual(bare.metadata["profile"], "p")
        XCTAssertEqual(bare.metadata["rc"], "r")
        XCTAssertEqual(bare.metadata["zshenv"], "e")
        XCTAssertEqual(bare.metadata["cwd"], fixture.physicalDirectory)
        XCTAssertEqual(bare.metadata["zdotdir"], fixture.zdotdir.path)
        let size = try XCTUnwrap(bare.metadata["size"]).split(separator: " ").compactMap { Int($0) }
        XCTAssertEqual(size.count, 2)
        XCTAssertTrue(size.allSatisfy { $0 > 0 })
        let runtimeValues = Set(["GHOSTTY_SURFACE_ID", "TERM_SESSION_ID", "__CF_USER_TEXT_ENCODING"])
        let keys = Set(bare.environment.keys).union(mediated.environment.keys).subtracting(runtimeValues)
        let differences = keys.filter { bare.environment[$0] != mediated.environment[$0] }.sorted()
        XCTAssertEqual(differences, [], "Environment comparison reports key names only")
        let bareEncoding = try XCTUnwrap(bare.environment["__CF_USER_TEXT_ENCODING"]).split(separator: ":")
        let mediatedEncoding = try XCTUnwrap(mediated.environment["__CF_USER_TEXT_ENCODING"]).split(separator: ":")
        XCTAssertEqual(bareEncoding.count, 3)
        XCTAssertEqual(mediatedEncoding.count, 3)
        XCTAssertEqual(try bareEncoding.dropFirst().map(numericEncoding), try mediatedEncoding.dropFirst().map(numericEncoding))
        // Foundation refreshes the UID in this cache when the Swift client loads.
        XCTAssertEqual(mediatedEncoding.first.map { UInt32($0.dropFirst(2), radix: 16) }, getuid())
        XCTAssertEqual(mediated.environment["SEAM_VALUE"], "two words; $literal 'quote'")
        XCTAssertEqual(mediated.environment["SEAM_AFTER_HOST_START"], "new pane environment")
    }

    private struct Snapshot {
        let metadata: [String: String]
        let environment: [String: String]
    }

    @MainActor private final class Fixture {
        let directory = URL(fileURLWithPath: "/tmp/shm-\(UUID().uuidString)")
        let paneID = UUID()
        let executable: URL
        let zmx: URL
        let resources: URL
        let zdotdir: URL
        let paths: SessionHost.Paths
        let physicalDirectory: String
        var surfaces: [GhosttySurfaceView] = []
        var windows: [NSWindow] = []
        var hostPID: Int32?

        init() throws {
            let bundle = directory.appendingPathComponent("Seam.app")
            executable = bundle.appendingPathComponent("Contents/MacOS/agterm-session-host")
            zmx = bundle.appendingPathComponent("Contents/MacOS/zmx")
            resources = bundle.appendingPathComponent("Contents/Resources/ghostty")
            zdotdir = directory.appendingPathComponent("custom zsh")
            paths = try SessionHost.paths(socketDirectory: ZmxSupport.socketDirectory(forStateDirectory: directory.path))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let physical = try XCTUnwrap(realpath(directory.path, nil))
            physicalDirectory = String(cString: physical)
            free(physical)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agterm-session-host"), to: executable)
            try FileManager.default.copyItem(at: repo.appendingPathComponent("agterm/Resources/zmx/zmx"), to: zmx)
            try FileManager.default.copyItem(at: repo.appendingPathComponent("agterm/Resources/ghostty/shell-integration"), to: resources.appendingPathComponent("shell-integration"))
            let info = ["CFBundleIdentifier": "com.umputun.seamtest.\(UUID().uuidString)", "CFBundleExecutable": "agterm-session-host"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try "export SEAM_ZSHENV=\"${SEAM_ZSHENV}e\"\n".write(to: zdotdir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            try "export SEAM_PROFILE=\"${SEAM_PROFILE}p\"\n".write(to: zdotdir.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
            let rc = """
            export SEAM_RC="${SEAM_RC}r"
            HISTFILE=/dev/null
            SAVEHIST=0
            if [[ $SEAM_CAPTURE_ON_START == 1 ]]; then source -- "$SEAM_PROBE"; fi

            """
            try rc.write(to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        }

        func capture(supervised: Bool, creationPayload: Bool) throws -> Snapshot {
            if supervised { try startHost() }
            let marker = directory.appendingPathComponent("snapshot")
            let envFile = directory.appendingPathComponent("environment")
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: envFile)
            var env = ["HOME": directory.path, "SEAM_PROFILE": "", "SEAM_RC": "", "SEAM_ZSHENV": "",
                       "SEAM_VALUE": "two words; $literal 'quote'", "SEAM_OUTPUT": marker.path, "SEAM_ENV": envFile.path]
            env["SEAM_AFTER_HOST_START"] = "new pane environment"
            let probe = directory.appendingPathComponent("probe.zsh")
            env["SEAM_PROBE"] = probe.path
            env["SEAM_CAPTURE_ON_START"] = creationPayload ? "0" : "1"
            let inputs = ZmxSupport.Inputs(zmxExecutablePath: zmx.path, passwordDatabaseShell: "/bin/zsh", resourcesDirectory: resources.path,
                                          stateDirectory: directory.path, paneIdentity: paneID, baseEnvironment: env, inheritedZdotdir: zdotdir.path,
                                          sessionHostExecutablePath: supervised ? executable.path : nil)
            let configuration = try ZmxSupport.configuration(for: inputs).get()
            let script = """
            umask 077
            /usr/bin/env -0 > "$SEAM_ENV"
            { print -rl -- "cwd=$PWD" "zdotdir=$ZDOTDIR" "login=$options[login]" "interactive=$options[interactive]" \
            "profile=$SEAM_PROFILE" "rc=$SEAM_RC" "zshenv=$SEAM_ZSHENV"; print -r -- "size=$(/bin/stty size)"; } > "$SEAM_OUTPUT"
            """
            try script.write(to: probe, atomically: true, encoding: .utf8)
            let session = Session(initialCwd: physicalDirectory)
            session.initialCommand = creationPayload ? "source -- " + CommandRestore.shellQuotedLine([probe.path]) : nil
            let seed = try XCTUnwrap(ZmxLaunch.surfaceSeed(disposition: .wrapped(configuration), session: session, pane: .left, denylist: []))
            if supervised { XCTAssertTrue(seed.command.contains("'client'")) }
            let surface = GhosttySurfaceView(workingDirectory: physicalDirectory, fontSize: 14, command: seed.command,
                                            env: configuration.environment, backedByZmx: true)
            surfaces.append(surface)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            windows.append(window)
            surface.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
            window.contentView?.addSubview(surface)
            surface.createSurface()
            XCTAssertNotNil(surface.surface)
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if let data = try? String(contentsOf: marker, encoding: .utf8), data.contains("size="), data.hasSuffix("\n") { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            let metadata = try parse(Data(contentsOf: marker), separator: 0x0A)
            let environment = try parse(Data(contentsOf: envFile), separator: 0)
            let records = try ZmxListParser.parse(runZmx(["list"]))
            let leader = try XCTUnwrap(records.first { $0.name == configuration.daemonName }?.leaderPID)
            if supervised {
                let value = try String(contentsOfFile: paths.pidfile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                hostPID = try XCTUnwrap(Int32(value))
                XCTAssertEqual(Responsibility.system.responsibleProcess(of: leader), hostPID)
            } else {
                XCTAssertEqual(Responsibility.system.responsibleProcess(of: leader), Responsibility.system.responsibleProcess(of: getpid()))
            }
            surface.teardown()
            _ = try runZmx(["kill", configuration.daemonName, "--force"])
            return Snapshot(metadata: metadata, environment: environment)
        }

        private func startHost() throws {
            hostPID = try Responsibility.system.spawnDisclaimed(executable: executable.path,
                argv: [executable.path, "host", ZmxSupport.socketDirectory(forStateDirectory: directory.path)],
                env: ["SEAM_AFTER_HOST_START": "old host environment", "HOME": directory.path, "PATH": "/usr/bin:/bin"])
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: paths.socket) { return }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            throw POSIXError(.ETIMEDOUT)
        }

        func cleanup() {
            for surface in surfaces { surface.teardown() }
            _ = try? runZmx(["kill", ZmxSupport.daemonName(for: paneID), "--force"])
            if hostPID == nil, let value = try? String(contentsOfFile: paths.pidfile, encoding: .utf8) {
                hostPID = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let pid = hostPID {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let length = proc_pidpath(pid, &bytes, UInt32(bytes.count))
                let actual = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                if length > 0, actual == physicalDirectory + "/Seam.app/Contents/MacOS/agterm-session-host" {
                    kill(pid, SIGKILL)
                    let deadline = Date().addingTimeInterval(3)
                    while kill(pid, 0) == 0 && Date() < deadline {
                        var status: Int32 = 0
                        _ = waitpid(pid, &status, WNOHANG)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                    }
                    XCTAssertEqual(kill(pid, 0), -1)
                } else { XCTFail("Could not verify the fixture host for cleanup") }
            }
            for window in windows { window.close() }
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: paths.socket).deletingLastPathComponent().deletingLastPathComponent().path)
            try? FileManager.default.removeItem(at: directory)
        }

        private func parse(_ data: Data, separator: UInt8) -> [String: String] {
            Dictionary(data.split(separator: separator).compactMap { bytes -> (String, String)? in
                let parts = String(decoding: bytes, as: UTF8.self).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            }, uniquingKeysWith: { _, last in last })
        }

        private func runZmx(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = zmx
            process.arguments = arguments
            process.environment = ["ZMX_DIR": ZmxSupport.socketDirectory(forStateDirectory: directory.path), "ZMX_SESSION": "", "ZMX_SESSION_PREFIX": ""]
            process.currentDirectoryURL = directory
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw POSIXError(.ETIMEDOUT) }
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
    }
}
