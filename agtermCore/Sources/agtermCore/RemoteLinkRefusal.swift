import Foundation

/// RemoteLinkClick is a path clicked in a pane attached from another Mac. `pane` is this Mac's identity of the
/// clicked pane, not the other Mac's.
public struct RemoteLinkClick: Equatable, Sendable {
    public let raw: String
    public let session: UUID
    public let pane: UUID?
    public let mode: LinkOpenMode

    public init(raw: String, session: UUID, pane: UUID?, mode: LinkOpenMode) {
        self.raw = raw
        self.session = session
        self.pane = pane
        self.mode = mode
    }
}

/// RemoteLinkRefusal is why a path clicked in a pane attached from another Mac was not opened. It travels by its raw
/// value, and the presenting Mac builds the text itself, so no wording from the other Mac reaches the screen.
public enum RemoteLinkRefusal: String, Equatable, Sendable, CaseIterable {
    case revealIntent
    case notPresenter
    case originTooOld
    case paneNotAttached
    /// hidden: a HUD, a zoomed terminal or a cover on this Mac would hide the page.
    case hidden
    case notFound
    /// notAPage: the file exists on the other Mac but is not a kind a page can show.
    case notAPage
    /// notOpened: the other Mac could not open the page, for a busy slot or a pane led from there.
    case notOpened

    /// message is the refusal's text for a session attached from `host`.
    public func message(host: String) -> String {
        switch self {
        case .revealIntent: return "the file is on \(host); only a file on this Mac can be revealed in Finder"
        case .notPresenter: return "another Mac presents this session, so \(host) cannot show the file here"
        case .originTooOld: return "the agterm on \(host) is too old to open clicked files"
        case .paneNotAttached: return "this pane is not attached to \(host)"
        case .hidden: return "the page from \(host) would be hidden here"
        case .notFound: return "no such file on \(host)"
        case .notAPage: return "\(host) cannot show this file as a page"
        case .notOpened: return "\(host) could not open the file here"
        }
    }
}
