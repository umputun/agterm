import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

enum RealZmx {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().path

    static var binary: String? {
        let environment = ProcessInfo.processInfo.environment
        #if os(Linux)
        let arch = environment["AGTERM_LINUX_ARCH"] ?? (Self.machine == "x86_64" ? "x86_64" : "aarch64")
        let staged = "\(repository)/build/linux/\(arch)/zmx/zmx"
        #else
        let staged = "\(repository)/agterm/Resources/zmx/zmx"
        #endif
        let path = environment["AGTERM_ZMX_BIN"] ?? staged
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var integration: String {
        #if os(Linux)
        let staged = "\(repository)/build/linux/ghostty/shell-integration"
        #else
        let staged = "\(repository)/agterm/Resources/ghostty/shell-integration"
        #endif
        return ProcessInfo.processInfo.environment["AGTERM_SHELL_INTEGRATION"] ?? staged
    }

    static var required: Bool { ProcessInfo.processInfo.environment["AGTERM_REQUIRE_ZMX"] == "1" }
    static var runs: Bool { binary != nil || required }

    private static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

@MainActor
@Suite(.serialized, .enabled(if: RealZmx.runs))
final class ServerLifecycleTests {
    private let scratch: ServerScratch
    private var server: AgtermServer?

    init() throws { scratch = try ServerScratch() }

    deinit {
        let socketDirectory = scratch.runtime
        let zmx = RealZmx.binary
        let root = scratch.root
        if let zmx, let directory = try? FileManager.default.contentsOfDirectory(atPath: socketDirectory)
            .first(where: { $0.hasPrefix("agterm-zmx-") }) {
            let path = "\(socketDirectory)/\(directory)"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path))?.filter { $0.hasPrefix("agterm-") } ?? []
            if !names.isEmpty {
                _ = try? ServerProcess.run([zmx, "kill"] + names + ["--force"], environment: ["ZMX_DIR": path], timeout: 10)
            }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    private func start(shell: String = "/bin/zsh") throws -> AgtermServer {
        let zmx = try #require(RealZmx.binary, "no zmx binary staged; run scripts/setup.sh or set AGTERM_ZMX_BIN")
        let resources = scratch.root + "/res"
        try? FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: resources + "/shell-integration", withDestinationPath: RealZmx.integration)
        let configuration = try ServerConfiguration.resolve(stateDirectory: scratch.state, zmxPath: zmx, resourcesDirectory: resources,
                                                            catalogName: "lifecycle", loginShell: shell,
                                                            environment: scratch.environment, executableDirectory: scratch.bin)
        let environment = ["HOME": scratch.root, "PATH": "/usr/bin:/bin", "XDG_RUNTIME_DIR": scratch.runtime, "LANG": "C.UTF-8"]
        let server = try AgtermServer.start(configuration: configuration, identity: AppIdentity(version: "1.2.3"),
                                            environment: environment)
        self.server = server
        return server
    }

    private func newSession(_ server: AgtermServer, cwd: String? = nil, command: String? = nil) throws -> Session {
        let reply = server.actions.createSession(ControlSessionCreateOptions(window: nil, cwd: cwd ?? scratch.root, workspace: nil,
                                                                             workspaceName: nil, createWorkspace: nil, command: command,
                                                                             wait: nil, name: nil, after: nil, before: nil,
                                                                             noSelect: false))
        let id = try #require(reply.result?.id.flatMap(UUID.init(uuidString:)), "\(reply)")
        return try #require(server.store.session(withID: id))
    }

    private func type(_ server: AgtermServer, _ session: Session, _ text: String, pane: StatusPane? = nil) async {
        _ = await server.actions.typeSession(session.id.uuidString, window: nil,
                                             options: ControlSessionTypeOptions(text: text, select: false, pane: pane, paneID: nil))
    }

    private func screen(_ server: AgtermServer, _ session: Session, pane: StatusPane? = nil) -> String {
        server.actions.readSessionText(session.id.uuidString, window: nil,
                                       options: ControlSessionTextOptions(pane: pane, paneID: nil, all: false, lines: nil)).result?.text ?? ""
    }

    private func eventually(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    private func listed(_ server: AgtermServer) -> Set<String> {
        Set(((try? server.zmx.list()) ?? []).map(\.name))
    }

    @Test func aPaneRunsItsShellWithThePaneEnvironment() async throws {
        let server = try start()
        let session = try newSession(server)

        #expect(listed(server).contains(ZmxSupport.daemonName(for: session.paneIdentity)))
        await type(server, session, "echo MARK-$AGTERM_PANE-$AGTERM_SESSION_ID\n")

        #expect(await eventually { self.screen(server, session).contains("MARK-left-\(session.id.uuidString)") })
    }

    @Test func aShellThatExitsClosesItsSession() async throws {
        let server = try start()
        let session = try newSession(server)

        await type(server, session, "exit\n")

        #expect(await eventually { server.store.session(withID: session.id) == nil })
    }

    @Test func aKilledDaemonLeavesItsSessionEnded() async throws {
        let server = try start()
        let session = try newSession(server)

        _ = server.zmx.kill(ZmxSupport.daemonName(for: session.paneIdentity))

        #expect(await eventually { session.ended })
        #expect(server.store.session(withID: session.id) != nil)
    }

    @Test func aSplitTakesThePrimarysPlaceWhenThePrimaryExits() async throws {
        let server = try start()
        let session = try newSession(server)
        #expect(server.actions.splitSession(session.id.uuidString, window: nil, mode: "on").ok)
        let split = try #require(session.splitPaneIdentity)

        await type(server, session, "exit\n", pane: .left)

        #expect(await eventually { session.paneIdentity == split && !session.hasSplit })
        #expect(server.store.session(withID: session.id) != nil)
    }

    @Test func aRestartedServerAdoptsTheRunningPane() async throws {
        let first = try start()
        let session = try newSession(first)
        let id = session.id
        let identity = session.paneIdentity
        first.stop()

        let second = try start()

        let adopted = try #require(second.store.session(withID: id))
        #expect(adopted.daemonBackedPanes == [identity])
        #expect(listed(second).contains(ZmxSupport.daemonName(for: identity)))
    }

    @Test(arguments: ["/bin/bash", "/bin/zsh"])
    func bashAndZshPanesStart(shell: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let server = try start(shell: shell)
        let session = try newSession(server)

        await type(server, session, "echo SHELL-IS-$0\n")

        #expect(await eventually { self.screen(server, session).contains("SHELL-IS-") })
    }

    @Test func aFishPaneLoadsTheShellIntegration() async throws {
        guard let fish = ["/usr/bin/fish", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            if ProcessInfo.processInfo.environment["AGTERM_REQUIRE_FISH"] != nil {
                Issue.record("AGTERM_REQUIRE_FISH is set but fish is not installed")
            }
            return
        }
        let server = try start(shell: fish)
        let session = try newSession(server)

        await type(server, session, "functions -q __ghostty_mark_prompt_start; and echo INTEGRATED-(echo FISH)\n")

        let integrated = await eventually(15) { self.screen(server, session).contains("INTEGRATED-FISH") }
        #expect(integrated, "fish pane screen: \(screen(server, session))")
    }

    #if os(Linux)
    // macOS's bash 3.2 does not read ENV for a `-c` shell
    @Test func aBashCommandPaneLoadsTheShellIntegration() async throws {
        let server = try start(shell: "/bin/bash")
        let session = try newSession(server, command: "declare -F __ghostty_precmd >/dev/null && echo INTEGRATED-BASH; sleep 30")

        #expect(await eventually { self.screen(server, session).contains("INTEGRATED-BASH") })
    }

    @Test func aSplitStartsWhereThePrimaryShellHasMovedTo() async throws {
        let server = try start()
        let session = try newSession(server)
        let target = scratch.root + "/moved"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)

        await type(server, session, "cd \(target)\n")
        #expect(await eventually { session.currentCwd == target })
        #expect(server.actions.splitSession(session.id.uuidString, window: nil, mode: "on").ok)
        await type(server, session, "pwd\n", pane: .right)

        #expect(await eventually { self.screen(server, session, pane: .right).contains(target) })
    }
    #endif
}
