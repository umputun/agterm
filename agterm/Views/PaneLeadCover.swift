import agtermCore
import SwiftUI

/// PaneLeadCover covers a pane whose zmx client does not lead, since its terminal is laid out for another
/// client's grid. It stays mounted so the pane's ZStack keeps one shape (see `sessionDetail`). The cover
/// takes hits and a click focuses the pane; the reconnect note draws uncovered too and never takes hits.
/// Every host of a pane's terminal, a Live scratch's included, mounts one directly over it, under any pane overlay.
struct PaneLeadCover: View {
    let session: Session
    let pane: StatusPane
    var background = WindowContentView.resolvedTerminalColor()
    var foreground = WindowContentView.resolvedChromeText()
    /// The pane sits under its own pane overlay, which draws on a transparent backing.
    var hidden = false

    var body: some View {
        let identity = session.paneIdentity(for: pane)
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
            if !hidden, let overlayPane = OverlayPane(rawValue: pane.rawValue),
               let reason = RemoteReconnectBook.shared.readback(pane: identity)?.reason {
                RemoteReconnectNote(reason: reason, pane: overlayPane)
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
        let surface = switch pane {
        case .left: session.surface
        case .right: session.splitSurface
        case .scratch: session.scratchSurface
        }
        (surface as? GhosttySurfaceView)?.focusAfterReparent()
    }
}

/// RemoteReconnectNote shows what ssh said on the last failed probe, never the outcome of the attach that
/// follows a probe that answered.
struct RemoteReconnectNote: View {
    let reason: String
    let pane: OverlayPane

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(verbatim: "ssh: \(reason)")
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.black)
                .background(Color.yellow)
                .accessibilityIdentifier("remote-reconnect-note-\(pane.rawValue)")
        }
        .allowsHitTesting(false)
    }
}
