import Foundation

extension RemoteLinkRefusal: Error {}

extension AppStore {
    /// linkClickRequest builds the frame that forwards `click` to its session's origin, or names why it cannot go:
    /// this Mac must present the session, the origin must speak `link.click`, nothing here may hide the page it
    /// opens (`hidden`, read from this Mac's HUD, zoom and cover), and the clicked pane must have an origin twin.
    public func linkClickRequest(_ click: RemoteLinkClick, originSupportsClick: Bool,
                                 hidden: Bool) -> Result<PresentationLinkClick, RemoteLinkRefusal> {
        guard let presentation = session(withID: click.session)?.remotePresentation,
              presentation.mode == .presenter else { return .failure(.notPresenter) }
        guard originSupportsClick else { return .failure(.originTooOld) }
        guard !hidden else { return .failure(.hidden) }
        guard let local = click.pane, let pane = presentation.binding.remotePane(forLocal: local) else {
            return .failure(.paneNotAttached)
        }
        return .success(PresentationLinkClick(raw: click.raw, pane: pane, mode: click.mode))
    }
}
