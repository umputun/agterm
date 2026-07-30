import AppKit
import Foundation

/// Bridges macOS accessibility display-option changes into agterm's app-local notification center: AppKit
/// posts them on `NSWorkspace.notificationCenter`, not the default center that agterm's window and sidebar
/// consumers observe with lifecycle-scoped tokens. Consumers read the settled values directly from
/// `NSWorkspace` when handling the bridged event — `WindowAppearance` for Reduce Transparency,
/// `StatusIconView` for Reduce Motion; native SwiftUI consumers use the matching accessibility environment
/// values and update independently.
@MainActor
final class SystemAccessibilityObserver {
    private var displayOptionsObserver: NSObjectProtocol?

    /// Register once for the process — the scene `.task` runs for every window, so this must be idempotent
    /// like `SystemAppearanceObserver.start()`. No initial post: consumers read the current preference
    /// during their normal first render or window attachment.
    func start() {
        guard displayOptionsObserver == nil else { return }
        let workspace = NSWorkspace.shared
        displayOptionsObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: workspace,
            queue: .main
        ) { _ in
            // NotificationCenter's callback is @Sendable even with a main queue. Hop explicitly so this
            // remains correct under Swift 6 isolation and matches SystemAppearanceObserver's convention.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .agtermAccessibilityDisplayOptionsChanged, object: nil)
            }
        }
    }

    isolated deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }
}
