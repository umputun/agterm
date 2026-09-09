import Foundation
import Testing
@testable import agtermCore

struct ZmxSupportTests {
    @Test func helperWrapsStructuredReplayWithoutChangingTheScript() {
        let name = "agterm-pane"
        let configuration = ZmxSupport.Configuration(executablePath: "/bundle's files/zmx", environment: [
            "SHELL": "/bin/zsh", "ZDOTDIR": "/bundle resources/zsh", "GHOSTTY_ZSH_ZDOTDIR": "/user/zsh",
        ], daemonName: name, socketDirectory: "/tmp/zmx", paneID: "pane", sessionHostExecutablePath: "/bundle's files/agterm-session-host")
        let replay = ["printf", "%s", "two words", "single'quote", "$literal"]
        let script = ZmxReplayScript.render(argv: replay, integrationDirectory: "/bundle resources/zsh", inheritedZdotdir: "/user/zsh", shell: "/bin/zsh")
        let expected = ["/bundle's files/agterm-session-host", "client", name, "--", "/bundle's files/zmx", "attach", name, "/bin/zsh", "-lic", script]
        #expect(ZmxSupport.attachCommand(configuration, replaying: replay, creationCommand: "do not run", denylist: []) == CommandRestore.shellQuotedLine(expected))
    }

    @Test func helperKeepsDurablePayloadAndRefusedReplayPrecedence() {
        let configuration = ZmxSupport.Configuration(executablePath: "/bundle/zmx", environment: ["SHELL": "/bin/zsh", "ZDOTDIR": "/bundle/zsh"],
                                                     daemonName: "agterm-pane", socketDirectory: "/tmp/zmx", paneID: "pane", sessionHostExecutablePath: "/bundle/host")
        let prefix = ["/bundle/host", "client", "agterm-pane", "--", "/bundle/zmx", "attach", "agterm-pane"]
        let line = "printf '%s' 'two words' && echo done"
        let script = ZmxReplayScript.render(commandLine: line, integrationDirectory: "/bundle/zsh", inheritedZdotdir: nil, shell: "/bin/zsh")
        #expect(ZmxSupport.attachCommand(configuration, replaying: nil, creationCommand: line, denylist: []) ==
                CommandRestore.shellQuotedLine(prefix + ["/bin/zsh", "-lic", script]))
        #expect(ZmxSupport.attachCommand(configuration, replaying: ["tmux"], creationCommand: line, denylist: ["tmux"]) == CommandRestore.shellQuotedLine(prefix))
        #expect(ZmxSupport.attachCommand(configuration, replaying: nil, denylist: []) == CommandRestore.shellQuotedLine(prefix))
    }

    @Test(arguments: [nil, "relative/helper", "/no/such/session-host"])
    func unavailableHelperKeepsBareAttach(_ helper: String?) throws {
        let resources = try makeResources(withLoader: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let inputs = ZmxSupport.Inputs(zmxExecutablePath: "/bin/echo", passwordDatabaseShell: "/bin/zsh", resourcesDirectory: resources.path,
                                      stateDirectory: "/tmp/task6", paneIdentity: UUID(), baseEnvironment: [:], inheritedZdotdir: nil,
                                      sessionHostExecutablePath: helper)
        let configuration = try #require(ZmxSupport.configuration(for: inputs).value)
        #expect(configuration.sessionHostExecutablePath == nil)
        #expect(ZmxSupport.attachCommand(configuration, replaying: nil, denylist: []) == configuration.command)
    }

    @Test func availableHelperIsCarriedFromInputsIntoTheCommand() throws {
        let resources = try makeResources(withLoader: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let inputs = ZmxSupport.Inputs(zmxExecutablePath: "/bin/echo", passwordDatabaseShell: "/bin/zsh", resourcesDirectory: resources.path,
                                      stateDirectory: "/tmp/task6", paneIdentity: UUID(), baseEnvironment: [:], inheritedZdotdir: nil,
                                      sessionHostExecutablePath: "/bin/cat")
        let configuration = try #require(ZmxSupport.configuration(for: inputs).value)
        #expect(configuration.sessionHostExecutablePath == "/bin/cat")
        #expect(ZmxSupport.attachCommand(configuration, replaying: nil, denylist: []) ==
                CommandRestore.shellQuotedLine(["/bin/cat", "client", configuration.daemonName, "--", "/bin/echo", "attach", configuration.daemonName]))
    }

    @Test func configurationUsesPasswordDatabaseZshAndFullPaneIdentity() throws {
        let resources = try makeResources(withLoader: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let paneID = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!

        let result = ZmxSupport.configuration(for: .init(
            zmxExecutablePath: "/bin/echo",
            passwordDatabaseShell: "/bin/zsh",
            resourcesDirectory: resources.path,
            stateDirectory: "/tmp/agterm-state",
            paneIdentity: paneID,
            baseEnvironment: ["AGTERM_ENABLED": "1", "AGTERM_PANE_ID": "old"],
            inheritedZdotdir: "/Users/test/.config/zsh"
        ))
        let configuration = try #require(result.value)

        #expect(configuration.daemonName == "agterm-abcdef0123456789abcdef0123456789")
        #expect(configuration.paneID == paneID.uuidString)
        #expect(configuration.command == "'/bin/echo' 'attach' 'agterm-abcdef0123456789abcdef0123456789'")
        #expect(configuration.environment["AGTERM_ENABLED"] == "1")
        #expect(configuration.environment["AGTERM_PANE_ID"] == paneID.uuidString)
        #expect(configuration.environment["SHELL"] == "/bin/zsh")
        #expect(configuration.environment["ZDOTDIR"] == resources.path + "/shell-integration/zsh")
        #expect(configuration.environment["GHOSTTY_ZSH_ZDOTDIR"] == "/Users/test/.config/zsh")
        #expect(configuration.environment["ZMX_DIR"] == configuration.socketDirectory)
        #expect(configuration.environment["ZMX_NO_DETACH_KEY"] == "1")
    }

    @Test func environmentShellCannotOverrideUnsupportedPasswordDatabaseShell() throws {
        let resources = try makeResources(withLoader: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let inputs = makeInputs(resources: resources, shell: "/bin/bash",
                                baseEnvironment: ["SHELL": "/bin/zsh"])

        #expect(ZmxSupport.configuration(for: inputs).failure == .unsupportedLoginShell)
    }

    @Test func configurationClearsInheritedZmxSessionContext() throws {
        let resources = try makeResources(withLoader: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let inputs = makeInputs(resources: resources, baseEnvironment: [
            "AGTERM_ENABLED": "1",
            "ZMX_SESSION": "parent-session",
            "ZMX_SESSION_PREFIX": "parent.",
        ])

        let configuration = try #require(ZmxSupport.configuration(for: inputs).value)

        #expect(configuration.environment["AGTERM_ENABLED"] == "1")
        #expect(configuration.environment["ZMX_SESSION"] == "")
        #expect(configuration.environment["ZMX_SESSION_PREFIX"] == "")
    }

    @Test func missingZshLoaderIsRejected() throws {
        let resources = try makeResources(withLoader: false)
        defer { try? FileManager.default.removeItem(at: resources) }

        #expect(ZmxSupport.configuration(for: makeInputs(resources: resources)).failure == .missingZshIntegration)
    }

    @Test func missingExecutableIsRejected() throws {
        let resources = try makeResources(withLoader: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let inputs = ZmxSupport.Inputs(
            zmxExecutablePath: "/tmp/agterm-zmx-does-not-exist-\(UUID().uuidString)",
            passwordDatabaseShell: "/bin/zsh",
            resourcesDirectory: resources.path,
            stateDirectory: "/tmp/agterm-state",
            paneIdentity: UUID(),
            baseEnvironment: [:],
            inheritedZdotdir: nil
        )

        #expect(ZmxSupport.configuration(for: inputs).failure == .executableUnavailable)
    }

    @Test func relativeExecutableIsRejected() throws {
        let resources = try makeResources(withLoader: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let inputs = ZmxSupport.Inputs(
            zmxExecutablePath: "zmx",
            passwordDatabaseShell: "/bin/zsh",
            resourcesDirectory: resources.path,
            stateDirectory: "/tmp/agterm-state",
            paneIdentity: UUID(),
            baseEnvironment: [:],
            inheritedZdotdir: nil
        )

        #expect(ZmxSupport.configuration(for: inputs).failure == .executablePathNotAbsolute)
    }

    @Test func canonicalStatePathsShareNamespace() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agterm-zmx-state-\(UUID().uuidString)")
        let real = root.appending(path: "real")
        let link = root.appending(path: "link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ZmxSupport.socketDirectory(forStateDirectory: real.path) ==
                ZmxSupport.socketDirectory(forStateDirectory: link.path))
    }

    @Test func launchDispositionKeepsLiveFallbackStateUnconsumed() {
        let configuration = ZmxSupport.Configuration(
            executablePath: "zmx", environment: [:], daemonName: "session",
            socketDirectory: "/tmp/zmx", paneID: "pane")

        #expect(ZmxSupport.launchDisposition(requested: .rerun, active: .rerun,
                                             configuration: configuration) == .ordinary)
        #expect(ZmxSupport.launchDisposition(requested: .live, active: .live,
                                             configuration: configuration) == .wrapped(configuration))
        #expect(ZmxSupport.launchDisposition(requested: .live, active: .none,
                                             configuration: nil) == .fallback)
    }

    @Test func eligibleReplayWinsOverDurableCommandAsOneOuterQuotedAttachPayload() {
        let configuration = replayConfiguration()
        let argv = ["printf", "%s", "two words", "single'quote"]
        let script = ZmxReplayScript.render(
            argv: argv, integrationDirectory: "/bundle resources/zsh",
            inheritedZdotdir: "/user/zsh", shell: "/bin/zsh"
        )

        let command = ZmxSupport.attachCommand(
            configuration, replaying: argv, creationCommand: "echo durable", denylist: []
        )

        #expect(command == configuration.command + " " +
                CommandRestore.shellQuotedLine(["/bin/zsh", "-lic", script]))
    }

    @Test(arguments: [
        (["tmux"], Set(["tmux"])),
        (["echo", "a\u{0A}b"], Set<String>()),
        (["grep", "caf\u{FFFD}"], Set<String>()),
        ([""], Set<String>()),
    ])
    func refusedReplayKeepsTheBareAttach(argv: [String], denylist: Set<String>) {
        let configuration = replayConfiguration()

        #expect(ZmxSupport.attachCommand(
            configuration, replaying: argv, creationCommand: "echo durable", denylist: denylist
        ) ==
                configuration.command)
    }

    @Test func missingReplayUsesDurableCommandAsAShellLine() {
        let configuration = replayConfiguration()
        let line = "printf durable && echo 'two words'"
        let script = ZmxReplayScript.render(
            commandLine: line, integrationDirectory: "/bundle resources/zsh",
            inheritedZdotdir: "/user/zsh", shell: "/bin/zsh"
        )

        #expect(ZmxSupport.attachCommand(
            configuration, replaying: nil, creationCommand: line, denylist: []
        ) == configuration.command + " " +
                CommandRestore.shellQuotedLine(["/bin/zsh", "-lic", script]))
    }

    @Test func missingReplayAndDurableCommandKeepTheBareAttach() {
        let configuration = replayConfiguration()

        #expect(ZmxSupport.attachCommand(
            configuration, replaying: nil, creationCommand: nil, denylist: []
        ) ==
                configuration.command)
    }

    @Test(arguments: [
        (ZmxSupport.Rejection.executablePathNotAbsolute, "the zmx executable path is not absolute"),
        (ZmxSupport.Rejection.executableUnavailable, "the zmx executable is unavailable"),
        (ZmxSupport.Rejection.unsupportedLoginShell, "the password-database login shell is not zsh"),
        (ZmxSupport.Rejection.missingZshIntegration, "the bundled zsh integration is unavailable"),
    ])
    func rejectionMessagesAreTheUserFacingSettingsReasons(
        rejection: ZmxSupport.Rejection, expected: String
    ) {
        #expect(rejection.message == expected)
    }

    private func makeInputs(resources: URL, shell: String = "/bin/zsh",
                            baseEnvironment: [String: String] = [:]) -> ZmxSupport.Inputs {
        .init(zmxExecutablePath: "/bin/echo", passwordDatabaseShell: shell,
              resourcesDirectory: resources.path, stateDirectory: "/tmp/agterm-state",
              paneIdentity: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
              baseEnvironment: baseEnvironment, inheritedZdotdir: nil)
    }

    private func replayConfiguration() -> ZmxSupport.Configuration {
        .init(
            executablePath: "/bin/zmx",
            environment: [
                "SHELL": "/bin/zsh",
                "ZDOTDIR": "/bundle resources/zsh",
                "GHOSTTY_ZSH_ZDOTDIR": "/user/zsh",
            ],
            daemonName: "agterm-pane", socketDirectory: "/tmp/zmx", paneID: "pane"
        )
    }

    private func makeResources(withLoader: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "agterm-zmx-resources-\(UUID().uuidString)")
        let integration = root.appending(path: "shell-integration/zsh")
        try FileManager.default.createDirectory(at: integration, withIntermediateDirectories: true)
        if withLoader {
            try Data().write(to: integration.appending(path: ".zshenv"))
        }
        return root
    }
}

private extension Result {
    var value: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }

    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
