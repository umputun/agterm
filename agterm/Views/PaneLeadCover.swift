import agtermCore
import SwiftUI

/// PaneLeadCover covers a pane whose zmx client does not lead, since its terminal is laid out for another
/// client's grid. It stays mounted so the pane's ZStack keeps one shape (see `sessionDetail`). The cover
/// takes hits and a click takes the lead, as a key does; the remote notice draws uncovered too and never takes hits.
/// Every host of a pane's terminal, a Live scratch's included, mounts one directly over it, under any pane overlay.
struct PaneLeadCover: View {
    let session: Session
    let pane: StatusPane
    var background = WindowContentView.resolvedTerminalColor()
    var foreground = WindowContentView.resolvedChromeText()
    /// The pane sits under its own pane overlay, which draws on a transparent backing.
    var hidden = false
    /// False in a dashboard cell, which owns the click and the keys, so the cover offers no takeover there.
    var interactive = true

    var body: some View {
        let identity = session.paneIdentity(for: pane)
        let book = ZmxLeadBook.shared
        let covered = book.covered(pane: identity) && !hidden
        let waiting = RemoteReconnectBook.shared.waiting(pane: identity)
        ZStack {
            ZStack {
                if covered {
                    background
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.on.rectangle.slash")
                            .font(.system(size: 28, weight: .light))
                        let state = identity.flatMap { book.states[$0] }
                        Text(Self.title(state: state, remote: session.remoteHost != nil))
                            .font(.system(size: 14, weight: .medium))
                        if let hint = Self.hint(state: state, interactive: interactive, waiting: waiting) {
                            Text(hint)
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
            .onTapGesture { takePane() }
            .allowsHitTesting(covered && interactive)
            if !hidden, let notice = RemotePaneNotice.Kind(identity: identity, host: session.remoteHost,
                                                           keyCloses: session.remotePresentation?.binding.catalogOwned != true) {
                RemotePaneNotice(kind: notice, pane: pane, background: background, foreground: foreground,
                                 retry: interactive ? { retryPane() } : nil)
            }
        }
    }

    static func hint(state: ZmxLeadState?, interactive: Bool, waiting: Bool) -> String? {
        guard interactive, !waiting, state?.reattaching != true || state?.attachment.claim == false else { return nil }
        return "Press any key or click to use it here"
    }

    static func title(state: ZmxLeadState?, remote: Bool) -> String {
        if let state, state.reattaching, state.attachment.claim { return "Taking over…" }
        if state?.reattaching == true || state?.role == .unowned { return "Reconnecting…" }
        return remote ? "In use on the Mac it runs on" : "In use from another Mac"
    }

    private var surfaceView: GhosttySurfaceView? {
        let surface = switch pane {
        case .left: session.surface
        case .right: session.splitSurface
        case .scratch: session.scratchSurface
        }
        return surface as? GhosttySurfaceView
    }

    private func takePane() {
        if let view = surfaceView { PaneLead.coverClicked(view) }
    }

    private func retryPane() {
        if let view = surfaceView { PaneLead.noticeClicked(view) }
    }
}

/// RemotePaneNotice is the panel over a remote pane whose attach ended: one waiting to reconnect, or one whose
/// session ended on its origin. Only the reconnecting card takes clicks, and only with `retry`; the rest of the
/// panel passes them to the pane.
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
    /// Retries the reconnect now; nil in a dashboard cell, which owns its clicks and keys, so no hint names either.
    var retry: (() -> Void)?

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
            .contentShape(.rect(cornerRadius: 10))
            .onTapGesture { retry?() }
            .allowsHitTesting(retries)
            .padding(16)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("remote-pane-notice-\(pane.rawValue)")
        }
    }

    var retries: Bool {
        guard case .reconnecting = kind else { return false }
        return retry != nil
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

    var hint: String? {
        switch kind {
        case .reconnecting: retries ? "Reconnecting… · any key or click retries now" : "Reconnecting…"
        case .ended(_, _, let keyCloses): keyCloses && retry != nil ? "Any key closes" : nil
        }
    }
}
