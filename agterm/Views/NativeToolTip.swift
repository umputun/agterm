import AppKit
import SwiftUI

extension View {
    /// Shows `text` as an AppKit tooltip and as the control's accessibility hint, in place of `.help`.
    /// SwiftUI's `.help` restarts its delay on every pointer movement inside the control, so a hand that is
    /// not perfectly still never sees it, and a tooltip already up does not pass to the next button the way
    /// AppKit's does (#809).
    func toolTip(_ text: String) -> some View {
        accessibilityHint(text)
            .background(NativeToolTip(text: text).accessibilityHidden(true))
    }
}

/// The view carrying the AppKit tooltip, sized to the control it backs.
struct NativeToolTip: NSViewRepresentable {
    let text: String

    func makeNSView(context _: Context) -> ToolTipView {
        let view = ToolTipView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: ToolTipView, context _: Context) {
        if view.toolTip != text { view.toolTip = text }
    }

    /// Never a click target: AppKit tracks tooltips by area, so a click in the gaps of a plain icon falls
    /// through to the control or the title bar's drag layer as before.
    final class ToolTipView: NSView {
        override func hitTest(_: NSPoint) -> NSView? { nil }
    }
}
