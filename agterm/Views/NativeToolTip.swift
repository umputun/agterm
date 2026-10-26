import AppKit
import SwiftUI

extension View {
    /// An AppKit tooltip and accessibility hint in place of `.help`, whose delay restarts on any move.
    /// It ignores SwiftUI opacity and views drawn over it: pass `isShown` where the control can be hidden.
    func toolTip(_ text: String, isShown: Bool = true) -> some View {
        accessibilityHint(text)
            .background(NativeToolTip(text: isShown ? text : nil).accessibilityHidden(true))
    }
}

/// The view carrying the AppKit tooltip, sized to the control it backs.
struct NativeToolTip: NSViewRepresentable {
    let text: String?

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
