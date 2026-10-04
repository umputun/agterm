import AppKit
import XCTest
import agtermCore
@testable import agterm

@MainActor
final class OpenCodeHookInstallationTests: XCTestCase {
    private var directory: URL!
    private var home: URL!
    private var scripts: URL!
    private var environment: [String: String]!
    private var clickedChoice = false
    private var v1Path: String { home.appendingPathComponent(".config/opencode/plugins/agterm-status.js").path }
    private var v2Path: String { home.appendingPathComponent(".config/opencode/plugins/agterm-v2/tui.js").path }

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        directory = fm.temporaryDirectory.appendingPathComponent("opencode-install-\(UUID().uuidString)")
        home = directory.appendingPathComponent("home")
        let bin = directory.appendingPathComponent("bin")
        try fm.createDirectory(at: home.appendingPathComponent(".config/opencode"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let command = bin.appendingPathComponent("opencode")
        try "#!/bin/sh\nprintf 'unknown-version\\n'\n".write(to: command, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        try "export PATH=\(CommandRestore.shellQuotedLine([bin.path]))\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        environment = ["PATH": bin.path, "HOME": home.path, "ZDOTDIR": home.path, "SHELL": "/bin/zsh"]
        scripts = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("agent-status")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testUnknownVersionCanInstallV1() async throws {
        try await assertFallbackInstalls(.v1, button: "OpenCode v1",
                                         plugin: "agterm-status.js", other: "agterm-v2/tui.js")
    }

    func testUnknownVersionCanInstallV2() async throws {
        try await assertFallbackInstalls(.v2, button: "OpenCode v2",
                                          plugin: "agterm-v2/tui.js", other: "agterm-status.js")
    }

    func testV1InstallLeavesTheV2PluginDirectoryUntouched() async throws {
        environment["OPENCODE_CONFIG_DIR"] = directory.path
        environment["XDG_CONFIG_HOME"] = directory.path
        let v2 = home.appendingPathComponent(".config/opencode/plugins/agterm-v2/tui.js")
        let contents = "// agterm-opencode-v2-status-plugin\nexport default { id: 'agterm.status', setup() {} };\n"
        try FileManager.default.createDirectory(at: v2.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: v2, atomically: true, encoding: .utf8)
        let outcome = try await install(choosing: "OpenCode v1")

        XCTAssertEqual(outcome, .installed(.v1, path: v1Path))
        XCTAssertEqual(try String(contentsOf: v2, encoding: .utf8), contents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins/agterm-status.js").path))
    }

    func testV2InstallAndReinstallRemoveManagedV1Plugin() async throws {
        let legacy = try writeV1Plugin()
        let installed = try await install(choosing: "OpenCode v2")

        XCTAssertEqual(installed, .installed(.v2, path: v2Path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))

        _ = try writeV1Plugin()
        let repeated = try await install(choosing: "OpenCode v2")

        XCTAssertEqual(repeated, .alreadyConfigured(.v2, path: v2Path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testV2PreservesAnUnmarkedV1Plugin() async throws {
        let contents = "export const UserPlugin = async () => ({});\n"
        let legacy = try writeV1Plugin(contents)
        let outcome = try await install(choosing: "OpenCode v2")

        XCTAssertEqual(outcome, .v1CleanupUserOwned(path: v1Path))
        XCTAssertTrue(outcome.isWarning)
        XCTAssertTrue(AgentHooksInstaller.opencodeText(outcome).contains("user-owned"))
        XCTAssertTrue(AgentHooksInstaller.opencodeText(outcome).contains("left untouched"))
        XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), contents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins/agterm-v2/tui.js").path))
    }

    func testFailedV2WritePreservesManagedV1Plugin() async throws {
        let legacy = try writeV1Plugin()
        try "not a directory".write(to: legacy.deletingLastPathComponent().appendingPathComponent("agterm-v2"), atomically: true, encoding: .utf8)
        let outcome = try await install(choosing: "OpenCode v2")

        XCTAssertEqual(outcome, .writeFailed(.v2, path: v2Path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testV2RemovesManagedV1SymlinkWithoutDeletingItsTarget() async throws {
        let legacy = try writeV1Plugin()
        let target = directory.appendingPathComponent("managed-plugin.js")
        let contents = try Data(contentsOf: legacy)
        try FileManager.default.moveItem(at: legacy, to: target)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: target)
        let outcome = try await install(choosing: "OpenCode v2")

        XCTAssertEqual(outcome, .installed(.v2, path: v2Path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: target), contents)
    }

    func testDanglingV1SymlinkIsPreservedAndReportedUnreadable() async throws {
        let legacy = URL(fileURLWithPath: v1Path)
        let missing = directory.appendingPathComponent("missing-v1.js")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: missing)

        for expectedAttempt in 1...2 {
            let outcome = try await install(choosing: "OpenCode v2")
            XCTAssertEqual(outcome, .v1CleanupUnreadable(path: legacy.path), "attempt \(expectedAttempt)")
            XCTAssertTrue(outcome.isWarning)
            XCTAssertTrue(AgentHooksInstaller.opencodeText(outcome).contains(legacy.path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: legacy.path), missing.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: v2Path))
        }
    }

    func testV1SymlinkWithAnInaccessibleTargetIsPreservedAndReportedUnreadable() async throws {
        let legacy = try writeV1Plugin()
        let parent = directory.appendingPathComponent("private-target")
        let target = parent.appendingPathComponent("v1.js")
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.moveItem(at: legacy, to: target)
        try fm.createSymbolicLink(at: legacy, withDestinationURL: target)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        let outcome = try await install(choosing: "OpenCode v2")

        XCTAssertEqual(outcome, .v1CleanupUnreadable(path: legacy.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: legacy.path), target.path)
        XCTAssertTrue(fm.fileExists(atPath: v2Path))
    }

    func testV1CleanupFailureWarnsAndKeepsTheWorkingV2Plugin() async throws {
        _ = try await install(choosing: "OpenCode v2")
        let legacy = try writeV1Plugin()
        let plugins = legacy.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: plugins.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: plugins.path) }
        let outcome = try await install(choosing: "OpenCode v2")

        XCTAssertEqual(outcome, .v1CleanupFailed(path: v1Path))
        XCTAssertTrue(outcome.isWarning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugins.appendingPathComponent("agterm-v2/tui.js").path))
    }

    func testUnreadableV1PluginIsPreservedWithWarning() async throws {
        let legacy = try writeV1Plugin()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: legacy.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacy.path) }
        let outcome = try await install(choosing: "OpenCode v2")

        XCTAssertEqual(outcome, .v1CleanupUnreadable(path: v1Path))
        XCTAssertTrue(AgentHooksInstaller.opencodeText(outcome).contains("could not be read"))
        XCTAssertTrue(AgentHooksInstaller.opencodeText(outcome).contains("left untouched"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins/agterm-v2/tui.js").path))
    }

    func testSkippingUnknownVersionWritesNoPluginAndDoesNotWarn() async throws {
        let outcome = try await install(choosing: "Skip OpenCode")

        XCTAssertEqual(outcome, .skipped)
        XCTAssertFalse(outcome.isWarning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins").path))
    }

    func testFallbackPreservesAUserOwnedPlugin() async throws {
        let legacy = try writeV1Plugin()
        let destination = home.appendingPathComponent(".config/opencode/plugins/agterm-v2/tui.js")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = "export default { id: 'user-plugin', setup() {} };\n"
        try existing.write(to: destination, atomically: true, encoding: .utf8)
        let outcome = try await install(choosing: "OpenCode v2")

        XCTAssertEqual(outcome, .userOwned(.v2, path: v2Path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), existing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testDetectedVersionInstallsWithoutAsking() async throws {
        let legacy = try writeV1Plugin()
        try "#!/bin/sh\nprintf 'opencode v2.0.12\\n'\n".write(to: directory.appendingPathComponent("bin/opencode"), atomically: false, encoding: .utf8)

        let outcome = try await install(choosing: nil)

        XCTAssertEqual(outcome, .installed(.v2, path: v2Path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins/agterm-v2/tui.js").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testMissingConfigIsCheckedAfterTheShellProbeWithoutSelection() async throws {
        let marker = directory.appendingPathComponent("probe-ran")
        environment["PROBE_MARKER"] = marker.path
        try "#!/bin/sh\nprintf ran > \"$PROBE_MARKER\"\nprintf 'opencode v2.0.12\\n'\n"
            .write(to: directory.appendingPathComponent("bin/opencode"), atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(at: home.appendingPathComponent(".config/opencode"))

        let outcome = try await install(choosing: nil)

        XCTAssertEqual(outcome, .noOpenCode(directory: home.appendingPathComponent(".config/opencode").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode").path))
    }

    func testV2UsesShellOnlyConfigDirectoryWithoutTheDefaultDirectory() async throws {
        let config = directory.appendingPathComponent("chosen config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let legacy = config.appendingPathComponent("plugins/agterm-status.js")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// agterm-opencode-status-plugin\n".write(to: legacy, atomically: true, encoding: .utf8)
        environment["XDG_CONFIG_HOME"] = directory.appendingPathComponent("unused-xdg").path
        try FileManager.default.removeItem(at: home.appendingPathComponent(".config/opencode"))
        let rc = home.appendingPathComponent(".zshrc")
        let startup = try String(contentsOf: rc, encoding: .utf8)
        try (startup + "export OPENCODE_CONFIG_DIR=\(CommandRestore.shellQuotedLine([config.path]))\n")
            .write(to: rc, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf '2.0.19\\n'\n".write(to: directory.appendingPathComponent("bin/opencode"), atomically: false, encoding: .utf8)

        let outcome = try await install(choosing: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: config.appendingPathComponent("plugins/agterm-v2/tui.js").path))
        XCTAssertTrue(AgentHooksInstaller.opencodeText(outcome).contains(config.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testManualV2UsesShellOnlyXDGDirectoryWhenVersionIsUnknown() async throws {
        let xdg = directory.appendingPathComponent("xdg config")
        let config = xdg.appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let homeLegacy = try writeV1Plugin()
        let customLegacy = config.appendingPathComponent("plugins/agterm-status.js")
        try FileManager.default.createDirectory(at: customLegacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "user-owned".write(to: customLegacy, atomically: true, encoding: .utf8)
        let rc = home.appendingPathComponent(".zshrc")
        let startup = try String(contentsOf: rc, encoding: .utf8)
        try (startup + "export XDG_CONFIG_HOME=\(CommandRestore.shellQuotedLine([xdg.path]))\n")
            .write(to: rc, atomically: true, encoding: .utf8)

        let outcome = try await install(choosing: "OpenCode v2")

        XCTAssertTrue(FileManager.default.fileExists(atPath: config.appendingPathComponent("plugins/agterm-v2/tui.js").path))
        XCTAssertTrue(AgentHooksInstaller.opencodeText(outcome).contains(config.path))
        XCTAssertEqual(outcome, .v1CleanupUserOwned(path: customLegacy.path))
        XCTAssertEqual(try String(contentsOf: customLegacy, encoding: .utf8), "user-owned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: homeLegacy.path))
    }

    func testManualV2DoesNotGuessTheDirectoryWhenTheShellCannotRun() async throws {
        environment["SHELL"] = "/no/such/agterm-test-shell"
        let outcome = try await install(choosing: "OpenCode v2")
        XCTAssertEqual(outcome, .v2ConfigUnavailable)
        XCTAssertTrue(outcome.isWarning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v2Path))
    }

    // regression: with no opencode config and no probe result the version chooser opened, though no answer could install
    func testMissingConfigAndUnprobeableShellSkipsWithoutSelection() async throws {
        environment["SHELL"] = "/no/such/agterm-test-shell"
        try FileManager.default.removeItem(at: home.appendingPathComponent(".config/opencode"))

        let outcome = try await install(choosing: nil)

        XCTAssertEqual(outcome, .noOpenCode(directory: home.appendingPathComponent(".config/opencode").path))
        XCTAssertFalse(outcome.isWarning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode").path))
    }

    private func writeV1Plugin(_ contents: String = "// agterm-opencode-status-plugin\nexport const AgtermStatusPlugin = async () => ({});\n") throws -> URL {
        let legacy = home.appendingPathComponent(".config/opencode/plugins/agterm-status.js")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: legacy, atomically: true, encoding: .utf8)
        return legacy
    }

    private func assertFallbackInstalls(_ expected: AgentHooksInstall.OpenCode.Version, button: String, plugin: String, other: String) async throws {
        let outcome = try await install(choosing: button)

        let installed = home.appendingPathComponent(".config/opencode/plugins/" + plugin)
        XCTAssertEqual(outcome, .installed(expected, path: installed.path))
        let bundled = scripts.appendingPathComponent("opencode/" + plugin)
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: bundled))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins/" + other).path))
        let repeated = try await install(choosing: button)
        XCTAssertEqual(repeated, .alreadyConfigured(expected, path: installed.path))
    }

    private func install(choosing button: String?) async throws -> AgentHooksInstaller.OpenCodeResult {
        clickedChoice = false
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(clickChoice(_:)),
                          userInfo: ["button": button ?? "Skip OpenCode", "deadline": Date().addingTimeInterval(10)] as [String: Any], repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        let outcome = try await AgentHooksInstaller.installOpenCodePlugin(home: home, scriptDirectory: scripts, environment: environment)
        XCTAssertEqual(clickedChoice, button != nil, "manual selection should occur only when detection fails")
        return outcome
    }

    @objc private func clickChoice(_ timer: Timer) {
        guard let info = timer.userInfo as? [String: Any], let title = info["button"] as? String,
              let deadline = info["deadline"] as? Date else { return }
        if let root = NSApp.modalWindow?.contentView, let button = findButton(title: title, in: root) {
            timer.invalidate()
            clickedChoice = true
            button.performClick(nil)
        } else if NSApp.modalWindow != nil && Date() >= deadline {
            timer.invalidate()
            XCTFail("OpenCode version button not found: \(title)")
            NSApp.abortModal()
        }
    }

    private func findButton(title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews {
            if let button = findButton(title: title, in: child) { return button }
        }
        return nil
    }
}
