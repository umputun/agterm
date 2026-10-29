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

    @Test func paneCommandEndsThePaneWhileCreationCommandReturnsToTheShell() {
        let configuration = ZmxSupport.Configuration(executablePath: "/bundle/zmx", environment: ["SHELL": "/bin/zsh", "ZDOTDIR": "/bundle/zsh"],
                                                     daemonName: "agterm-pane", socketDirectory: "/tmp/zmx", paneID: "pane", sessionHostExecutablePath: "/bundle/host")
        let prefix = ["/bundle/host", "client", "agterm-pane", "--", "/bundle/zmx", "attach", "agterm-pane"]
        let line = "lazygit --path 'two words'"
        let ending = ZmxReplayScript.renderEnding(commandLine: line)
        let returning = ZmxReplayScript.render(commandLine: line, integrationDirectory: "/bundle/zsh", inheritedZdotdir: nil, shell: "/bin/zsh")

        #expect(ZmxSupport.attachCommand(configuration, replaying: nil, paneCommand: line, denylist: []) ==
                CommandRestore.shellQuotedLine(prefix + ["/bin/zsh", "-lic", ending]))
        #expect(ZmxSupport.attachCommand(configuration, replaying: nil, creationCommand: line, denylist: []) ==
                CommandRestore.shellQuotedLine(prefix + ["/bin/zsh", "-lic", returning]))
    }

    @Test func capturedReplayWinsOverThePaneCommand() {
        let configuration = ZmxSupport.Configuration(executablePath: "/bundle/zmx", environment: ["SHELL": "/bin/zsh", "ZDOTDIR": "/bundle/zsh"],
                                                     daemonName: "agterm-pane", socketDirectory: "/tmp/zmx", paneID: "pane", sessionHostExecutablePath: "/bundle/host")
        let prefix = ["/bundle/host", "client", "agterm-pane", "--", "/bundle/zmx", "attach", "agterm-pane"]
        let replay = ZmxReplayScript.render(argv: ["htop"], integrationDirectory: "/bundle/zsh", inheritedZdotdir: nil, shell: "/bin/zsh")

        #expect(ZmxSupport.attachCommand(configuration, replaying: ["htop"], paneCommand: "lazygit", denylist: []) ==
                CommandRestore.shellQuotedLine(prefix + ["/bin/zsh", "-lic", replay]))
        #expect(ZmxSupport.attachCommand(configuration, replaying: ["tmux"], paneCommand: "lazygit", denylist: ["tmux"]) ==
                CommandRestore.shellQuotedLine(prefix))
    }

    @Test func fishPaneCommandEndsThePane() {
        let configuration = ZmxSupport.Configuration(executablePath: "/bundle/zmx", environment: [
            "SHELL": "/opt/homebrew/bin/fish", "GHOSTTY_SHELL_INTEGRATION_XDG_DIR": "/bundle/shell-integration",
        ], daemonName: "agterm-pane", socketDirectory: "/tmp/zmx", paneID: "pane", sessionHostExecutablePath: nil)
        let command = ZmxSupport.attachCommand(configuration, replaying: nil, paneCommand: "lazygit", denylist: [])

        #expect(command.hasSuffix(CommandRestore.shellQuotedLine([
            "/opt/homebrew/bin/fish", "-lic", ZmxReplayScript.renderFishEnding(commandLine: "lazygit"),
        ])))
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

    @Test func leadAttachmentReachesTheAttachEnvironmentAndAnInheritedOneDoesNot() throws {
        let resources = try makeResources(withLoader: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let inherited = ["ZMX_MANAGED": "stale", "ZMX_MANAGED_CLAIM": "1"]
        func environment(lead: ZmxLeadAttachment?) throws -> [String: String] {
            let inputs = ZmxSupport.Inputs(zmxExecutablePath: "/bin/echo", passwordDatabaseShell: "/bin/zsh",
                                          resourcesDirectory: resources.path, stateDirectory: "/tmp/agterm-state",
                                          paneIdentity: UUID(), baseEnvironment: inherited, inheritedZdotdir: nil,
                                          lead: lead)
            return try #require(ZmxSupport.configuration(for: inputs).value).environment
        }

        let unmanaged = try environment(lead: nil)
        #expect(unmanaged["ZMX_MANAGED"] == nil)
        #expect(unmanaged["ZMX_MANAGED_CLAIM"] == nil)

        let recovering = try environment(lead: ZmxLeadAttachment(nonce: "n1", claim: false))
        #expect(recovering["ZMX_MANAGED"] == "n1")
        #expect(recovering["ZMX_MANAGED_CLAIM"] == nil)

        let claiming = try environment(lead: ZmxLeadAttachment(nonce: "n2", claim: true))
        #expect(claiming["ZMX_MANAGED"] == "n2")
        #expect(claiming["ZMX_MANAGED_CLAIM"] == "1")
    }

    @Test func configurationUsesPasswordDatabaseFishAndFullPaneIdentity() throws {
        let resources = try makeFishResources(withMarker: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let paneID = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        let root = resources.path + "/shell-integration"
        let result = ZmxSupport.configuration(for: .init(
            zmxExecutablePath: "/bin/echo",
            passwordDatabaseShell: "/usr/local/bin/fish",
            resourcesDirectory: resources.path,
            stateDirectory: "/tmp/agterm-state",
            paneIdentity: paneID,
            baseEnvironment: ["AGTERM_ENABLED": "1", "AGTERM_PANE_ID": "old", "XDG_DATA_DIRS": "/pane/share"],
            inheritedZdotdir: "/Users/test/.config/zsh"
        ))
        let configuration = try #require(result.value)

        #expect(configuration.daemonName == "agterm-abcdef0123456789abcdef0123456789")
        #expect(configuration.paneID == paneID.uuidString)
        #expect(configuration.environment["AGTERM_ENABLED"] == "1")
        #expect(configuration.environment["AGTERM_PANE_ID"] == paneID.uuidString)
        #expect(configuration.environment["SHELL"] == "/usr/local/bin/fish")
        #expect(configuration.environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] == root)
        #expect(configuration.environment["XDG_DATA_DIRS"] == "/pane/share")
        #expect(configuration.environment["ZDOTDIR"] == nil)
        #expect(configuration.environment["GHOSTTY_ZSH_ZDOTDIR"] == nil)
        #expect(configuration.environment["ZMX_DIR"] == configuration.socketDirectory)
        #expect(configuration.environment["ZMX_NO_DETACH_KEY"] == "1")
    }

    @Test func fishSurfaceEnvironmentLeavesAnInheritedXDGDataDirectoriesAlone() throws {
        let resources = try makeFishResources(withMarker: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let configuration = try #require(ZmxSupport.configuration(for: makeInputs(resources: resources, shell: "/bin/fish")).value)

        #expect(configuration.environment["XDG_DATA_DIRS"] == nil)
        #expect(configuration.environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] == resources.path + "/shell-integration")
    }

    @Test(arguments: [false, true])
    func fishAttachMergesTheIntegrationRootIntoTheLaunchEnvironment(withSessionHost: Bool) throws {
        let resources = try makeFishResources(withMarker: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let root = resources.path + "/shell-integration"
        let recorder = resources.appending(path: "record-xdg")
        try "#!/bin/sh\nprintf '%s' \"$XDG_DATA_DIRS\" > \"$RESULT_FILE\"\n".write(to: recorder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recorder.path)
        let cases: [(inherited: String?, pane: String?, expected: String)] = [
            ("/custom/share", nil, root + ":/custom/share"),
            (nil, nil, root + ":/usr/local/share:/usr/share"),
            ("", nil, root + ":/usr/local/share:/usr/share"),
            ("/custom/share", "/pane/share", root + ":/pane/share"),
            (root, nil, root),
            (root + ":/first:" + root + "::/second:" + root, nil, root + ":/first:/second"),
            ("/with space:/with'quote:/with\\backslash:/glob/*:", nil,
             root + ":/with space:/with'quote:/with\\backslash:/glob/*"),
        ]

        for (inherited, pane, expected) in cases {
            let configuration = try #require(ZmxSupport.configuration(for: .init(
                zmxExecutablePath: recorder.path, passwordDatabaseShell: "/bin/fish",
                resourcesDirectory: resources.path, stateDirectory: "/tmp/agterm-state", paneIdentity: UUID(),
                baseEnvironment: pane.map { ["XDG_DATA_DIRS": $0] } ?? [:], inheritedZdotdir: nil,
                sessionHostExecutablePath: withSessionHost ? recorder.path : nil
            )).value)
            let result = resources.appending(path: "result-\(UUID().uuidString)")
            var environment = ProcessInfo.processInfo.environment
            environment["XDG_DATA_DIRS"] = inherited
            environment.merge(configuration.environment) { _, surface in surface }
            environment["RESULT_FILE"] = result.path
            let line = ZmxSupport.attachCommand(configuration, replaying: nil, denylist: [])
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["--noprofile", "--norc", "-c", "exec -l " + line]
            process.environment = environment
            try process.run()
            process.waitUntilExit()

            #expect(process.terminationStatus == 0)
            #expect(try String(contentsOf: result, encoding: .utf8) == expected)
        }
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

    @Test func missingFishResourcesAndLoaderAreRejected() throws {
        let missingResources = ZmxSupport.Inputs(
            zmxExecutablePath: "/bin/echo", passwordDatabaseShell: "/bin/fish", resourcesDirectory: nil,
            stateDirectory: "/tmp/agterm-state", paneIdentity: UUID(), baseEnvironment: [:], inheritedZdotdir: nil
        )
        let resources = try makeFishResources(withMarker: false)
        defer { try? FileManager.default.removeItem(at: resources) }

        #expect(ZmxSupport.configuration(for: missingResources).failure == .missingFishIntegration)
        #expect(ZmxSupport.configuration(for: .init(
            zmxExecutablePath: "/bin/echo", passwordDatabaseShell: "/bin/fish", resourcesDirectory: resources.path,
            stateDirectory: "/tmp/agterm-state", paneIdentity: UUID(), baseEnvironment: [:], inheritedZdotdir: nil
        )).failure == .missingFishIntegration)
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

    @Test func fishAttachCarriesEveryPayloadFormWithAndWithoutTheSessionHost() {
        for host in [nil, "/bin/cat"] {
            let configuration = fishReplayConfiguration(sessionHostExecutablePath: host)
            let captured = ["printf", "%s", "two words", "single'quote"]
            let capturedScript = ZmxReplayScript.renderFish(
                argv: captured, integrationRoot: "/bundle resources/fish", shell: "/bin/fish"
            )
            let durable = "printf durable; echo 'two words'"
            let durableScript = ZmxReplayScript.renderFish(
                commandLine: durable, integrationRoot: "/bundle resources/fish", shell: "/bin/fish"
            )
            func attach(_ payload: [String]) -> String {
                var arguments = configuration.attachArguments + payload
                if let host { arguments = [host, "client", configuration.daemonName, "--"] + arguments }
                return CommandRestore.shellQuotedLine(["/usr/bin/env", "/bin/sh", "-c",
                                                       ZmxSupport.fishXDGDataDirectoriesScript, "sh",
                                                       "/bundle resources/fish"] + arguments)
            }

            #expect(ZmxSupport.attachCommand(configuration, replaying: captured, creationCommand: durable, denylist: []) ==
                    attach(["/bin/fish", "-lic", capturedScript]))
            #expect(ZmxSupport.attachCommand(configuration, replaying: nil, creationCommand: durable, denylist: []) ==
                    attach(["/bin/fish", "-lic", durableScript]))
            #expect(ZmxSupport.attachCommand(configuration, replaying: ["tmux"], creationCommand: durable, denylist: ["tmux"]) ==
                    attach([]))
            #expect(ZmxSupport.attachCommand(configuration, replaying: nil, creationCommand: nil, denylist: []) == attach([]))
        }
    }

    @Test(arguments: [
        (ZmxSupport.Rejection.executablePathNotAbsolute, "the zmx executable path is not absolute"),
        (ZmxSupport.Rejection.executableUnavailable, "the zmx executable is unavailable"),
        (ZmxSupport.Rejection.unsupportedLoginShell, "the password-database login shell is not zsh or fish"),
        (ZmxSupport.Rejection.missingZshIntegration, "the bundled zsh integration is unavailable"),
        (ZmxSupport.Rejection.missingFishIntegration, "the bundled fish integration is unavailable"),
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

    private func fishReplayConfiguration(sessionHostExecutablePath: String?) -> ZmxSupport.Configuration {
        .init(
            executablePath: "/bin/zmx",
            environment: [
                "SHELL": "/bin/fish",
                "GHOSTTY_SHELL_INTEGRATION_XDG_DIR": "/bundle resources/fish",
            ],
            daemonName: "agterm-pane", socketDirectory: "/tmp/zmx", paneID: "pane",
            sessionHostExecutablePath: sessionHostExecutablePath
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

    private func makeFishResources(withMarker: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "agterm-zmx-fish-resources-\(UUID().uuidString)")
        let integration = root.appending(path: "shell-integration")
        try FileManager.default.createDirectory(at: integration, withIntermediateDirectories: true)
        if withMarker {
            let marker = integration.appending(path: "fish/vendor_conf.d/ghostty-shell-integration.fish")
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: marker)
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
