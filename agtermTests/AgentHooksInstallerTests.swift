import AppKit
import XCTest
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
}
