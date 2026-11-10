import agtermCore
import XCTest
@testable import agterm

/// AppKit parks an accessory view narrower than the alert at the window's left margin, under the icon, so
/// the option checkboxes need an explicit indent to line up with the text they belong to.
@MainActor
final class WelcomeAlertTests: XCTestCase {
    func testOptionCheckboxesAlignWithTheAlertTextColumn() throws {
        let built = WelcomeAlert.makeAlert()
        let content = try XCTUnwrap(built.alert.window.contentView)
        let title = try XCTUnwrap(firstTextField(in: content, matching: FirstRunWelcome.title),
                                  "the alert should carry its title in a text field")

        let titleX = leadingX(of: title, in: content)
        XCTAssertEqual(leadingX(of: built.skill, in: content), titleX, accuracy: 1,
                       "the skill checkbox should start at the text column, not the icon column")
        XCTAssertEqual(leadingX(of: built.hooks, in: content), titleX, accuracy: 1,
                       "the hooks checkbox should share that edge")
    }

    private func leadingX(of view: NSView, in content: NSView) -> CGFloat {
        view.convert(NSPoint.zero, to: content).x + view.alignmentRectInsets.left
    }

    func testBothOptionsStartChecked() {
        let built = WelcomeAlert.makeAlert()
        XCTAssertEqual(built.skill.state, .on)
        XCTAssertEqual(built.hooks.state, .on)
    }

    func testInstallIsTheDefaultAndLaterIsPresent() {
        let built = WelcomeAlert.makeAlert()
        XCTAssertEqual(built.alert.buttons.map(\.title), ["Install", "Later"])
    }

    func testCombinedInstallationProbesOnceAndFinishesSkillBeforeHooks() async {
        let captured = OpenCodeEnvironmentProbe.Result(version: .v2, v2ConfigurationDirectory: "/opencode", codexHome: "/custom/codex")
        var events: [String] = []
        await AgentInstallers.run(skill: true, hooks: true, probe: {
            events.append("probe")
            await Task.yield()
            return captured
        }, installSkill: { result in
            XCTAssertEqual(result?.codexHome, captured.codexHome)
            events.append("skill result dismissed")
        }, installHooks: { result in
            XCTAssertEqual(result?.codexHome, captured.codexHome)
            XCTAssertEqual(result?.v2ConfigurationDirectory, captured.v2ConfigurationDirectory)
            XCTAssertEqual(events.last, "skill result dismissed")
            events.append("hooks result dismissed")
        })
        XCTAssertEqual(events, ["probe", "skill result dismissed", "hooks result dismissed"])
    }

    func testQueuedHelpRequestWaitsForProbeAndResultThenUsesFreshProbe() async {
        let hooksProbeStarted = expectation(description: "hooks probe started")
        let hooksResultOpened = expectation(description: "hooks result opened")
        let skillRequested = expectation(description: "skill requested while hooks are probing")
        let hooksCapture = OpenCodeEnvironmentProbe.Result(version: .v1, v2ConfigurationDirectory: nil, codexHome: "/first/codex")
        let skillCapture = OpenCodeEnvironmentProbe.Result(version: .v2, v2ConfigurationDirectory: nil, codexHome: "/second/codex")
        var finishProbe: CheckedContinuation<OpenCodeEnvironmentProbe.Result?, Never>?
        var dismissHooks: CheckedContinuation<Void, Never>?
        var events: [String] = []
        defer {
            finishProbe?.resume(returning: hooksCapture)
            dismissHooks?.resume()
        }
        let hooks = Task {
            await AgentInstallers.run(skill: false, hooks: true, probe: {
                events.append("hooks probe")
                return await withCheckedContinuation {
                    finishProbe = $0
                    hooksProbeStarted.fulfill()
                }
            }, installSkill: { _ in XCTFail("unchecked skill must not install") }, installHooks: { result in
                XCTAssertEqual(result?.codexHome, hooksCapture.codexHome)
                events.append("hooks result opened")
                await withCheckedContinuation {
                    dismissHooks = $0
                    hooksResultOpened.fulfill()
                }
                events.append("hooks result dismissed")
            })
        }
        await fulfillment(of: [hooksProbeStarted], timeout: 3)
        let skill = Task {
            skillRequested.fulfill()
            await AgentInstallers.run(skill: true, hooks: false, probe: {
                events.append("skill probe")
                return skillCapture
            }, installSkill: { result in
                XCTAssertEqual(result?.codexHome, skillCapture.codexHome)
                events.append("skill result dismissed")
            }, installHooks: { _ in XCTFail("unchecked hooks must not install") })
        }
        await fulfillment(of: [skillRequested], timeout: 3)
        XCTAssertEqual(events, ["hooks probe"])
        finishProbe?.resume(returning: hooksCapture)
        finishProbe = nil
        await fulfillment(of: [hooksResultOpened], timeout: 3)
        XCTAssertEqual(events, ["hooks probe", "hooks result opened"])
        dismissHooks?.resume()
        dismissHooks = nil
        await hooks.value
        await skill.value
        XCTAssertEqual(events, ["hooks probe", "hooks result opened", "hooks result dismissed", "skill probe", "skill result dismissed"])
    }

    func testHooksOnlyProbesOnceAndNoSelectionDoesNotProbe() async {
        var probes = 0
        var hooks = 0
        for selected in [false, true] {
            await AgentInstallers.run(skill: false, hooks: selected, probe: {
                probes += 1
                return nil
            }, installSkill: { _ in XCTFail("unchecked skill must not install") }, installHooks: { _ in hooks += 1 })
        }
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(hooks, 1)
    }

    private func firstTextField(in view: NSView, matching value: String) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.stringValue == value { return field }
            if let found = firstTextField(in: subview, matching: value) { return found }
        }
        return nil
    }
}
