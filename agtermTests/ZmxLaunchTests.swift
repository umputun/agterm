import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ZmxLaunchTests: XCTestCase {
    func testSessionHostPathUsesOnlyDebugOverride() {
        let bundle = URL(fileURLWithPath: "/Applications/agterm.app")
        let env = ["AGTERM_SESSION_HOST_PATH": "/tmp/debug-host"]
        XCTAssertEqual(ZmxLaunch.sessionHostExecutablePath(bundleURL: bundle, environment: env, allowDebugOverride: true), "/tmp/debug-host")
        XCTAssertEqual(ZmxLaunch.sessionHostExecutablePath(bundleURL: bundle, environment: env, allowDebugOverride: false),
                       "/Applications/agterm.app/Contents/MacOS/agterm-session-host")
        XCTAssertEqual(ZmxLaunch.sessionHostExecutablePath(bundleURL: bundle, environment: ["AGTERM_SESSION_HOST_PATH": ""], allowDebugOverride: true),
                       "/Applications/agterm.app/Contents/MacOS/agterm-session-host")
    }

    func testRerunNeverRendersTheAvailableClient() {
        let configuration = ZmxSupport.Configuration(executablePath: "/bundle/zmx", environment: ["SHELL": "/bin/zsh", "ZDOTDIR": "/bundle/zsh"],
                                                     daemonName: "pane", socketDirectory: "/tmp/zmx", paneID: "pane", sessionHostExecutablePath: "/bundle/host")
        let session = Session(initialCwd: "/tmp")
        session.initialCommand = "printf rerun"
        let disposition = ZmxLaunch.disposition(requested: .rerun, active: .rerun, configuration: configuration)
        XCTAssertNil(ZmxLaunch.surfaceSeed(disposition: disposition, session: session, pane: .left, denylist: []))
        let provider = LaunchSeedProvider.pane(session: session, pane: .left, disposition: disposition,
                                               policy: .init(restoreEnabled: true, denylist: [], runningNames: nil))
        XCTAssertEqual(provider.resolve(.left).command, "printf rerun")
    }

    func testBothLivePaneRolesRenderTheClient() throws {
        let configuration = ZmxSupport.Configuration(executablePath: "/bundle/zmx", environment: ["SHELL": "/bin/zsh", "ZDOTDIR": "/bundle/zsh"],
                                                     daemonName: "pane", socketDirectory: "/tmp/zmx", paneID: "pane", sessionHostExecutablePath: "/bundle/host")
        let session = Session(initialCwd: "/tmp")
        for pane in [StatusPane.left, .right] {
            let seed = try XCTUnwrap(ZmxLaunch.surfaceSeed(disposition: .wrapped(configuration), session: session, pane: pane, denylist: []))
            XCTAssertEqual(seed.command, "'/bundle/host' 'client' 'pane' '--' '/bundle/zmx' 'attach' 'pane'")
            XCTAssertNil(seed.initialInput)
        }
    }

    func testMissingBundledHelperKeepsTheBareCreationPayload() throws {
        let bundle = try makeBundleWithZshLoader()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let configuration = try ZmxSupport.configuration(for: .init(
            zmxExecutablePath: "/bin/echo", passwordDatabaseShell: "/bin/zsh",
            resourcesDirectory: bundle.appendingPathComponent("Contents/Resources/ghostty").path,
            stateDirectory: bundle.path, paneIdentity: UUID(), baseEnvironment: [:], inheritedZdotdir: nil,
            sessionHostExecutablePath: ZmxLaunch.sessionHostExecutablePath(bundleURL: bundle, environment: [:], allowDebugOverride: false)
        )).get()
        let session = Session(initialCwd: "/tmp")
        session.initialCommand = "printf 'two words'"
        let seed = try XCTUnwrap(ZmxLaunch.surfaceSeed(disposition: .wrapped(configuration), session: session, pane: .left, denylist: []))
        let script = ZmxReplayScript.render(commandLine: "printf 'two words'", integrationDirectory: try XCTUnwrap(configuration.environment["ZDOTDIR"]),
                                           inheritedZdotdir: nil, shell: "/bin/zsh")
        XCTAssertNil(configuration.sessionHostExecutablePath)
        XCTAssertEqual(seed.command, CommandRestore.shellQuotedLine(["/bin/echo", "attach", configuration.daemonName, "/bin/zsh", "-lic", script]))
    }

    func testALiveLaunchWrapsALocalSessionButNeverARemoteOne() {
        let local = Session(initialCwd: "/tmp")
        let remote = Session(initialCwd: "/tmp", remoteHost: "buildbox")

        XCTAssertTrue(ZmxLaunch.wrapsLocally(mode: .live, session: local))
        // a wrapper would keep the ssh alive inside a surviving daemon after a window close
        XCTAssertFalse(ZmxLaunch.wrapsLocally(mode: .live, session: remote))
    }

    func testNoSessionIsWrappedOutsideLiveMode() {
        let local = Session(initialCwd: "/tmp")

        XCTAssertFalse(ZmxLaunch.wrapsLocally(mode: .none, session: local))
        XCTAssertFalse(ZmxLaunch.wrapsLocally(mode: .rerun, session: local))
    }

    func testLaunchDispositionKeepsFallbackStateUnconsumed() {
        let configuration = ZmxSupport.Configuration(
            executablePath: "zmx", environment: [:], daemonName: "session",
            socketDirectory: "/tmp/zmx", paneID: "pane")

        XCTAssertEqual(ZmxLaunch.disposition(requested: .rerun, active: .rerun,
                                             configuration: configuration), .ordinary)
        XCTAssertEqual(ZmxLaunch.disposition(requested: .live, active: .live,
                                             configuration: configuration), .wrapped(configuration))
        XCTAssertEqual(ZmxLaunch.disposition(requested: .live, active: .none,
                                             configuration: nil), .fallback)
    }

    func testExecutablePathUsesOnlyDebugOverride() {
        let bundle = URL(fileURLWithPath: "/Applications/agterm.app", isDirectory: true)
        let environment = ["AGTERM_ZMX_PATH": "/tmp/debug-zmx"]

        XCTAssertEqual(ZmxLaunch.executablePath(bundleURL: bundle, environment: environment,
                                                allowDebugOverride: true), "/tmp/debug-zmx")
        XCTAssertEqual(ZmxLaunch.executablePath(bundleURL: bundle, environment: environment,
                                                allowDebugOverride: false),
                       "/Applications/agterm.app/Contents/MacOS/zmx")
    }

    func testDefaultUITestLaunchIsBypassedAndExplicitOptInUsesRealInputs() throws {
        let bundle = try makeBundleWithZshLoader()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let base = ["AGTERM_ZMX_PATH": "/bin/echo"]

        XCTAssertEqual(ZmxLaunch.liveUnavailableReason(
            bundleURL: bundle, environment: base, passwordDatabaseShell: "/bin/zsh",
            isUITestLaunch: true, allowDebugOverride: true), ZmxLaunch.uiTestBypassReason)
        var optedIn = base
        optedIn[ZmxLaunch.uiTestOptInKey] = "1"
        XCTAssertNil(ZmxLaunch.liveUnavailableReason(
            bundleURL: bundle, environment: optedIn, passwordDatabaseShell: "/bin/zsh",
            isUITestLaunch: true, allowDebugOverride: true))
    }

    func testResolvedGhosttyResourcesOverrideMissingBundleResources() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-zmx-empty-bundle-\(UUID().uuidString).app", isDirectory: true)
        let resources = try makeResourcesWithZshLoader()
        defer {
            try? FileManager.default.removeItem(at: bundle)
            try? FileManager.default.removeItem(at: resources)
        }
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        XCTAssertNil(ZmxLaunch.liveUnavailableReason(
            bundleURL: bundle,
            environment: ["AGTERM_ZMX_PATH": "/bin/echo", "GHOSTTY_RESOURCES_DIR": resources.path],
            passwordDatabaseShell: "/bin/zsh", isUITestLaunch: false, allowDebugOverride: true))
    }

    func testLiveUnavailableReasonUsesTheLoginShellRejectionMessage() throws {
        let bundle = try makeBundleWithZshLoader()
        defer { try? FileManager.default.removeItem(at: bundle) }

        XCTAssertEqual(ZmxLaunch.liveUnavailableReason(
            bundleURL: bundle,
            environment: ["AGTERM_ZMX_PATH": "/bin/echo"],
            passwordDatabaseShell: "/bin/bash",
            isUITestLaunch: false,
            allowDebugOverride: true), "the password-database login shell is not zsh")
    }

    func testWrappedStateIsFixedAtInitialization() {
        let view = GhosttySurfaceView(workingDirectory: "/tmp", backedByZmx: true)

        XCTAssertTrue(view.backedByZmx)
    }

    private func makeBundleWithZshLoader() throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-zmx-bundle-\(UUID().uuidString).app", isDirectory: true)
        let loader = bundle.appendingPathComponent("Contents/Resources/ghostty/shell-integration/zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: loader, withIntermediateDirectories: true)
        try Data().write(to: loader.appendingPathComponent(".zshenv"))
        return bundle
    }

    private func makeResourcesWithZshLoader() throws -> URL {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-zmx-resources-\(UUID().uuidString)", isDirectory: true)
        let loader = resources.appendingPathComponent("shell-integration/zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: loader, withIntermediateDirectories: true)
        try Data().write(to: loader.appendingPathComponent(".zshenv"))
        return resources
    }
}
