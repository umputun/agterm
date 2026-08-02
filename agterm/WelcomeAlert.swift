import AppKit
import agtermCore

/// The first-launch alert pointing at the Help menu extras, with buttons for the two a Homebrew install
/// does not provide. Host-free copy and the due-decision are `agtermCore.FirstRunWelcome`.
@MainActor
enum WelcomeAlert {
    private static var presented = false

    /// Suppressed under XCUITest, since every test launches on a fresh isolated state directory and would
    /// otherwise open a modal before its first assertion. `WelcomeUITests` opts back in.
    static var isSuppressedForUITest: Bool {
        ContentView.isUITestLaunch && ProcessInfo.processInfo.environment["AGTERM_UITEST_SHOW_WELCOME"] == nil
    }

    /// Show the welcome once per process, marking it shown before any installer runs so a cancelled or
    /// failed install cannot bring it back on the next launch.
    static func presentOnce(settingsModel: SettingsModel) {
        guard !presented, !isSuppressedForUITest else { return }
        presented = true
        settingsModel.setWelcomeShown(true)
        // hop out of the caller's Task before the nested modal loop: started from inside the scene's
        // `.task`, `runModal()` returns `.abort` immediately and nothing is ever drawn.
        DispatchQueue.main.async { present() }
    }

    private static func present() {
        let built = makeAlert()
        guard built.alert.runModal() == .alertFirstButtonReturn else { return }
        // each installer runs its own result alert, so they queue behind one another
        if built.skill.state == .on { SkillInstaller.run() }
        if built.hooks.state == .on { AgentHooksInstaller.run() }
    }

    /// The alert and its two option checkboxes, laid out and aligned. Split out of `present()` so a hosted
    /// test can check the layout without running a modal.
    static func makeAlert() -> (alert: NSAlert, skill: NSButton, hooks: NSButton) {
        let skill = checkbox(title: FirstRunWelcome.skillOption, identifier: "welcome-skill-checkbox")
        let hooks = checkbox(title: FirstRunWelcome.hooksOption, identifier: "welcome-hooks-checkbox")
        let stack = NSStackView(views: [skill, hooks])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        let container = NSView(frame: stack.frame)
        container.addSubview(stack)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = FirstRunWelcome.title
        alert.informativeText = FirstRunWelcome.message
        alert.accessoryView = container
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        alert.buttons.first?.setAccessibilityIdentifier("welcome-install")
        alert.buttons.last?.setAccessibilityIdentifier("welcome-later")
        alert.layout()
        indentOptions(stack, container: container, reference: skill, in: alert)
        return (alert, skill, hooks)
    }

    private static func checkbox(title: String, identifier: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = .on
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    /// Move the checkboxes under the alert's text column. AppKit parks an accessory view narrower than the
    /// alert at the window's left margin, which is the icon column, so without this the boxes hang left of
    /// every line of text. Measured after `layout()` because the text column's x is not knowable before it,
    /// then corrected against the checkbox itself: a stack positions its views by alignment rect, and a
    /// checkbox's differs from a text field's by a couple of points.
    private static func indentOptions(_ stack: NSStackView, container: NSView, reference: NSView, in alert: NSAlert) {
        guard let content = alert.window.contentView,
              let text = messageLabel(in: content, matching: alert.messageText) else { return }
        let textX = leadingX(of: text, in: content)
        let indent = textX - leadingX(of: container, in: content)
        guard indent > 0 else { return }
        stack.setFrameOrigin(NSPoint(x: indent, y: stack.frame.origin.y))
        container.setFrameSize(NSSize(width: indent + stack.frame.width, height: container.frame.height))
        alert.layout()
        let residual = leadingX(of: reference, in: content) - textX
        guard abs(residual) > 0.5 else { return }
        stack.setFrameOrigin(NSPoint(x: stack.frame.origin.x - residual, y: stack.frame.origin.y))
        alert.layout()
    }

    /// A view's visible left edge in `content` coordinates: the frame inset by the alignment rect, which is
    /// what AppKit lines controls up by and what the eye reads as the edge.
    private static func leadingX(of view: NSView, in content: NSView) -> CGFloat {
        view.convert(NSPoint.zero, to: content).x + view.alignmentRectInsets.left
    }

    /// The alert's title label, the leftmost element of its text column.
    private static func messageLabel(in view: NSView, matching title: String) -> NSView? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.stringValue == title { return field }
            if let found = messageLabel(in: subview, matching: title) { return found }
        }
        return nil
    }
}
