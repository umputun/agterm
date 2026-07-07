import AppKit
import SwiftUI

/// A transparent AppKit layer placed behind the custom titlebar's decorative regions (the title text and
/// the empty spacers, which opt out of SwiftUI hit-testing) so the header behaves like a real title bar:
/// a single-click drag moves the window (`performDrag`) and a double-click runs the user's configured
/// title-bar double-click action. The custom titlebar is a SwiftUI view, not AppKit's native title bar,
/// so the OS double-click handling never reaches it; this restores it. The interactive header buttons
/// render in front and keep their own clicks. `mouseDownCanMoveWindow` is off so our `mouseDown` — not
/// AppKit's automatic move — sees the event and can tell a double-click apart from a drag.
struct WindowControlArea: NSViewRepresentable {
    func makeNSView(context _: Context) -> TitlebarControlView { TitlebarControlView() }
    func updateNSView(_: TitlebarControlView, context _: Context) {}

    final class TitlebarControlView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                performTitlebarDoubleClickAction()
                return
            }
            // a single click that turns into a drag moves the window; a plain click returns at once.
            window?.performDrag(with: event)
        }

        /// Mirror AppKit's native title-bar double-click by honoring the system setting at
        /// Desktop & Dock ▸ "Double-click a window's title bar to" (`AppleActionOnDoubleClick`
        /// in `NSGlobalDomain`): Zoom/Fill → zoom, Minimize → miniaturize, "Do Nothing" → no-op.
        /// The key is absent until the user changes it from the macOS default (Zoom), so an
        /// untouched system reads as `nil` here and still zooms — preserving the prior behavior.
        /// Read live on each double-click so a setting change takes effect without an app relaunch.
        /// "Fill" maps to `zoom` (the closest standard NSWindow action; true Fill uses the newer
        /// window-tiling APIs). Zoom matches the `window.zoom` control command (the plain green button does
        /// native full screen, not zoom).
        ///
        /// A UITest env override (`AGTERM_UITEST_DOUBLECLICK_ACTION`) takes precedence so the gesture
        /// tests are hermetic regardless of the host machine's setting; it rides the environment
        /// because launch arguments trip the macOS 15+ no-window-at-launch bug (FB11763863, see
        /// `ui-tests.md`). Production never sets it and falls through to the live system default.
        private func performTitlebarDoubleClickAction() {
            guard let window else { return }
            let action = ProcessInfo.processInfo.environment["AGTERM_UITEST_DOUBLECLICK_ACTION"]
                ?? UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            switch action {
            case "Minimize":
                window.performMiniaturize(nil)
            case "None":
                break
            default: // "Maximize", "Fill", or unset (macOS default) → zoom
                window.zoom(nil)
            }
        }
    }
}
