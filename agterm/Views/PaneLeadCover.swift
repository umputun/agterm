import agtermCore
import SwiftUI

/// Covers a pane whose zmx client does not lead: what its terminal drew is laid out for another client's
/// grid. Always mounted, so the pane's ZStack keeps one shape (see `sessionDetail`); it draws and takes
/// hits only while the pane is covered. A click focuses the pane, whose next key press takes the lead.
/// Every host of a pane's terminal mounts one, the deck, terminal zoom and the dashboard alike, directly
/// over that terminal: a pane overlay above it is another program's and stays visible.
struct PaneLeadCover: View {
    let session: Session
    let pane: OverlayPane
    var background = WindowContentView.resolvedTerminalColor()
    var foreground = WindowContentView.resolvedChromeText()
    /// The pane sits under its own pane overlay, which draws on a transparent backing.
    var hidden = false

    var body: some View {
        let identity = session.paneIdentity(for: pane == .left ? StatusPane.left : .right)
        let book = ZmxLeadBook.shared
        let covered = book.covered(pane: identity) && !hidden
        ZStack {
            if covered {
                background
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .font(.system(size: 28, weight: .light))
                    Text(Self.title(role: book.role(pane: identity), reattaching: book.reattaching(pane: identity),
                                    remote: session.remoteHost != nil))
                        .font(.system(size: 14, weight: .medium))
                    if !book.reattaching(pane: identity) {
                        Text("Press any key to use it here")
                            .font(.system(size: 12))
                            .opacity(0.7)
                    }
                }
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .padding()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pane-lead-cover-\(pane.rawValue)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focusPane() }
        .allowsHitTesting(covered)
    }

    static func title(role: ZmxLeadRole?, reattaching: Bool, remote: Bool) -> String {
        if reattaching { return "Taking over…" }
        if role == .unowned { return "Reconnecting…" }
        return remote ? "In use on the Mac it runs on" : "In use from another Mac"
    }

    private func focusPane() {
        let surface = pane == .left ? session.surface : session.splitSurface
        (surface as? GhosttySurfaceView)?.focusAfterReparent()
    }
}
