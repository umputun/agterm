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

    private func firstTextField(in view: NSView, matching value: String) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.stringValue == value { return field }
            if let found = firstTextField(in: subview, matching: value) { return found }
        }
        return nil
    }
}
