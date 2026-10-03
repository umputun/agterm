import AppKit
import XCTest
import agtermCore
@testable import agterm

/// NSAlert sizes itself to fit `informativeText`, with no scroll and no height cap, so any text long enough
/// pushes the buttons off the bottom of the screen. Issue #430: the Codex manual-merge cases embedded the
/// whole 29-line hooks block and did exactly that.
@MainActor
final class AgentHooksInstallerTests: XCTestCase {
    private let allCodexResults: [AgentHooksInstaller.CodexResult] =
        [.merged, .alreadyConfigured, .hooksExist, .unparseable, .unreadable, .noCodex]

    func testNoCodexOutcomeEmbedsTheHooksBlock() {
        for result in allCodexResults {
            let text = AgentHooksInstaller.codexText(result)
            XCTAssertFalse(text.contains("[[hooks."), "\(result) should point at the docs, not inline the block")
            XCTAssertFalse(text.contains("\n"), "\(result) should stay a single line")
        }
    }

    func testOnlyTheManualMergeOutcomesOfferTheDocsButton() {
        for result in allCodexResults {
            let expected = result == .hooksExist || result == .unparseable
            XCTAssertEqual(result.needsManualMerge, expected, "\(result) offers the docs button: \(expected)")
        }
    }

    func testManualMergeTextNamesTheDocsSection() {
        for result in allCodexResults where result.needsManualMerge {
            XCTAssertTrue(AgentHooksInstaller.codexText(result).contains("Add Codex hooks by hand"),
                          "\(result) should name the docs section the button opens")
        }
    }

    func testDocsButtonIsSecondSoTheDefaultStaysOK() {
        let alert = AgentHooksInstaller.makeAlert(style: .warning, title: "t", text: "x",
                                                  docs: AgentHooksInstaller.codexManualDocsURL)
        XCTAssertEqual(alert.buttons.map(\.title), ["OK", "Open Docs"])
    }

    func testAlertWithoutDocsKeepsTheSingleDefaultButton() {
        let alert = AgentHooksInstaller.makeAlert(style: .informational, title: "t", text: "x", docs: nil)
        XCTAssertEqual(alert.buttons.map(\.title), ["OK"])
    }

    func testDocsURLPointsAtTheManualMergeAnchor() throws {
        let url = try XCTUnwrap(AgentHooksInstaller.codexManualDocsURL)
        XCTAssertEqual(url.absoluteString, "https://agterm.com/docs#codex-hooks-manual")
    }

    func testOpenCodeOutcomesNameTheVersionAndStayOnOneLine() {
        for version in AgentHooksInstall.OpenCode.Version.allCases {
            let path = "/custom/opencode/plugins/\(version.rawValue).js"
            let results: [AgentHooksInstaller.OpenCodeResult] = [
                .installed(version, path: path), .alreadyConfigured(version, path: path),
                .userOwned(version, path: path), .unreadable(version, path: path), .writeFailed(version, path: path),
            ]
            for result in results {
                let text = AgentHooksInstaller.opencodeText(result)
                XCTAssertTrue(text.contains("OpenCode \(version.rawValue)"))
                XCTAssertTrue(text.contains(path))
                XCTAssertFalse(text.contains("\n"))
            }
            let installed = AgentHooksInstaller.opencodeText(.installed(version, path: path))
            XCTAssertTrue(installed.contains(path))
            XCTAssertTrue(installed.contains("Restart OpenCode"))
        }
    }

    func testMissingOpenCodeDoesNotNameAVersion() {
        let result = AgentHooksInstaller.OpenCodeResult.noOpenCode(directory: "/custom/opencode")
        let text = AgentHooksInstaller.opencodeText(result)
        XCTAssertEqual(text, "No /custom/opencode found, so the OpenCode plugin was skipped. Start OpenCode once, then run this again. "
                       + "Coarse shell detection for opencode is off by default.")
        XCTAssertFalse(result.isWarning)
    }

    func testUnknownOpenCodeVersionOffersSkipAndSupportedVersions() {
        let alert = AgentHooksInstaller.makeOpenCodeVersionAlert()
        let titles = ["Skip OpenCode"] + AgentHooksInstall.OpenCode.Version.allCases.map { "OpenCode \($0.rawValue)" }
        XCTAssertEqual(alert.buttons.map(\.title), titles)
        XCTAssertTrue(alert.informativeText.contains("opencode --version"))
    }

    func testSkippedOpenCodeHasNeutralConfirmation() {
        let result = AgentHooksInstaller.OpenCodeResult.skipped
        let text = AgentHooksInstaller.opencodeText(result)
        XCTAssertFalse(result.isWarning)
        XCTAssertEqual(text, "OpenCode status plugin installation was skipped.")
        XCTAssertFalse(text.contains("\n"))
    }

    func testV1CleanupWarningsReportTheReasonAndTheInstalledV2Plugin() {
        let path = "/custom/opencode/plugins/agterm-status.js"
        let cases: [(AgentHooksInstaller.OpenCodeResult, String)] = [
            (.v1CleanupUserOwned(path: path), "is user-owned and was left untouched"),
            (.v1CleanupUnreadable(path: path), "could not be read and was left untouched"),
            (.v1CleanupFailed(path: path), "could not be safely removed"),
        ]
        for (result, reason) in cases {
            let text = AgentHooksInstaller.opencodeText(result)
            XCTAssertTrue(result.isWarning)
            XCTAssertTrue(text.contains("OpenCode v2 status plugin is installed"))
            XCTAssertTrue(text.contains(path))
            XCTAssertTrue(text.contains(reason))
            XCTAssertFalse(text.contains("\n"))
        }
    }
}
