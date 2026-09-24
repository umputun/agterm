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
        environment = ["PATH": bin.path, "HOME": home.path]
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

    func testSkippingUnknownVersionWritesNoPlugin() async throws {
        let outcome = try await install(choosing: "Skip OpenCode")

        XCTAssertNil(outcome.version)
        XCTAssertEqual(outcome.result, .unknownVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins").path))
    }

    func testFallbackPreservesAUserOwnedPlugin() async throws {
        let destination = home.appendingPathComponent(".config/opencode/plugins/agterm-v2/tui.js")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = "export default { id: 'user-plugin', setup() {} };\n"
        try existing.write(to: destination, atomically: true, encoding: .utf8)
        let outcome = try await install(choosing: "OpenCode v2")

        XCTAssertEqual(outcome.version, .v2)
        XCTAssertEqual(outcome.result, .userOwned)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), existing)
    }

    func testDetectedVersionInstallsWithoutAsking() async throws {
        try "#!/bin/sh\nprintf 'opencode v2.0.12\\n'\n".write(to: directory.appendingPathComponent("bin/opencode"), atomically: false, encoding: .utf8)

        let outcome = try await install(choosing: nil)

        XCTAssertEqual(outcome.version, .v2)
        XCTAssertEqual(outcome.result, .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins/agterm-v2/tui.js").path))
    }

    func testMissingConfigSkipsDetectionAndSelection() async throws {
        let marker = directory.appendingPathComponent("probe-ran")
        environment["PROBE_MARKER"] = marker.path
        try "#!/bin/sh\nprintf ran > \"$PROBE_MARKER\"\nprintf 'opencode v2.0.12\\n'\n"
            .write(to: directory.appendingPathComponent("bin/opencode"), atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(at: home.appendingPathComponent(".config/opencode"))

        let outcome = try await install(choosing: nil)

        XCTAssertNil(outcome.version)
        XCTAssertEqual(outcome.result, .noOpenCode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode").path))
    }

    private func assertFallbackInstalls(_ expected: AgentHooksInstall.OpenCode.Version, button: String, plugin: String, other: String) async throws {
        let outcome = try await install(choosing: button)

        XCTAssertEqual(outcome.version, expected)
        XCTAssertEqual(outcome.result, .installed)
        let installed = home.appendingPathComponent(".config/opencode/plugins/" + plugin)
        let bundled = scripts.appendingPathComponent("opencode/" + plugin)
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: bundled))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/plugins/" + other).path))
        let repeated = try await install(choosing: button)
        XCTAssertEqual(repeated.version, expected)
        XCTAssertEqual(repeated.result, .alreadyConfigured)
    }

    private func install(choosing button: String?) async throws -> (version: AgentHooksInstall.OpenCode.Version?, result: AgentHooksInstaller.OpenCodeResult) {
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
