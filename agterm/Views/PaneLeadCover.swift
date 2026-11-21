import agtermCore
import SwiftUI

/// PaneLeadCover covers a pane whose zmx client does not lead, since its terminal is laid out for another
/// client's grid. It stays mounted so the pane's ZStack keeps one shape (see `sessionDetail`). The cover
/// takes hits and a click focuses the pane; the remote notice draws uncovered too and never takes hits.
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
                    let state = identity.flatMap { book.states[$0] }
                    Text(Self.title(state: state, remote: session.remoteHost != nil))
                        .font(.system(size: 14, weight: .medium))
                    if state?.reattaching != true || state?.attachment.claim == false {
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
            if !hidden, let notice = RemotePaneNotice.Kind(identity: identity, host: session.remoteHost,
                                                           keyCloses: session.remotePresentation?.binding.catalogOwned != true) {
                RemotePaneNotice(kind: notice, pane: pane, background: background, foreground: foreground)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focusPane() }
        .allowsHitTesting(covered)
    }

    static func title(state: ZmxLeadState?, remote: Bool) -> String {
        if let state, state.reattaching, state.attachment.claim { return "Taking over…" }
        if state?.reattaching == true || state?.role == .unowned { return "Reconnecting…" }
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

/// RemotePaneNotice is the panel over a remote pane whose attach ended: one waiting to reconnect, or one whose
/// session ended on its origin. The key it names is the pane's own, so the panel never takes hits.
struct RemotePaneNotice: View {
    enum Kind: Equatable {
        /// reason is what ssh said on the last failed probe, never the outcome of the attach that follows.
        case reconnecting(host: String, reason: String?)
        /// keyCloses is false on a remote window's row, whose ended pane a key reattaches or leaves as it is.
        case ended(name: String, host: String, keyCloses: Bool)

        @MainActor
        init?(identity: UUID?, host: String?, keyCloses: Bool) {
            if let host, RemoteReconnectBook.shared.waiting(pane: identity) {
                self = .reconnecting(host: host, reason: RemoteReconnectBook.shared.readback(pane: identity)?.reason)
            } else if let ended = RemoteEndBook.shared.notice(pane: identity) {
                self = .ended(name: ended.name, host: ended.host, keyCloses: keyCloses)
            } else {
                return nil
            }
        }
    }

    let kind: Kind
    let pane: StatusPane
    let background: Color
    let foreground: Color

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .light))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .medium))
                    if let hint {
                        Text(verbatim: hint)
                            .font(.system(size: 12))
                            .opacity(0.7)
                    }
                    if case .reconnecting(_, let reason?) = kind {
                        Text(verbatim: "ssh: \(reason)")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .opacity(0.7)
                    }
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background.opacity(0.94), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(foreground.opacity(0.2)))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .padding(16)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("remote-pane-notice-\(pane.rawValue)")
        }
        .allowsHitTesting(false)
    }

    private var symbol: String {
        switch kind {
        case .reconnecting: "wifi.exclamationmark"
        case .ended: "xmark.circle"
        }
    }

    private var title: String {
        switch kind {
        case .reconnecting(let host, _): "Connection to \(host) lost"
        case .ended(let name, let host, _): "\(name) on \(host) ended"
        }
    }

    private var hint: String? {
        switch kind {
        case .reconnecting: "Reconnecting… · any key retries now"
        case .ended(_, _, let keyCloses): keyCloses ? "Any key closes" : nil
        }
    }
}
