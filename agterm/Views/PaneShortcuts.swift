import agtermCore
import AppKit

/// App-wide Ctrl-1 / Ctrl-2 focus the active session's left (primary) / right (split) pane directly, a
/// faster alias for the ⌘⌥←/→ menu nav. Caught by an `NSEvent` local monitor rather than a SwiftUI shortcut
/// so it isn't a duplicate menu item, like the Ctrl-Tab switcher. Always consumed (reserved app shortcuts),
/// so they never leak to the shell — on a non-split session `focusPane` no-ops instead of printing "1".
@MainActor
final class PaneShortcuts {
    private let library: WindowLibrary
    private let actions: AppActions
    private var monitor: Any?

    private static let oneKey: UInt16 = 18
    private static let twoKey: UInt16 = 19

    init(library: WindowLibrary, actions: AppActions) {
        self.library = library
        self.actions = actions
    }

    /// Install the local key monitor once (the scene `.task` may re-run).
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // returning nil consumes the event so the terminal never sees Ctrl-1/2.
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods == .control else { return false }
        switch event.keyCode {
        case Self.oneKey: actions.focusPane(.main); return true
        case Self.twoKey: actions.focusPane(.split); return true
        default: return false
        }
    }
}
