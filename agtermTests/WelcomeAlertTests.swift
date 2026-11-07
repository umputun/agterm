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

    func testInstallationGuardsReentryAndDoesNotCacheAcrossActions() async {
        var probes = 0
        var skills = 0
        for _ in 0..<2 {
            await AgentInstallers.run(skill: true, hooks: false, probe: {
                probes += 1
                await AgentInstallers.run(skill: true, hooks: true, probe: {
                    XCTFail("reentry must not probe")
                    return nil
                }, installSkill: { _ in XCTFail("reentry must not show a skill result") },
                   installHooks: { _ in XCTFail("reentry must not show a hooks result") })
                return nil
            }, installSkill: { result in
                XCTAssertNil(result)
                skills += 1
            }, installHooks: { _ in XCTFail("unchecked hooks must not install") })
        }
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(skills, 2)
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
