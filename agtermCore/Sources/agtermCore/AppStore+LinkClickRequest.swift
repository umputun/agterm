import Foundation

extension RemoteLinkRefusal: Error {}

extension AppStore {
    /// linkClickRequest builds the frame that forwards `click` to its session's origin, or names why it cannot go:
    /// this Mac must present the session or, with an origin taking lead reports, lead the clicked pane; the origin
    /// must speak `link.click`, nothing here may hide the page it opens (`hidden`, read from this Mac's HUD, zoom and
    /// cover), and the clicked pane must have an origin twin.
    public func linkClickRequest(_ click: RemoteLinkClick, originSupportsClick: Bool, hidden: Bool,
                                 originTakesLeads: Bool = false) -> Result<PresentationLinkClick, RemoteLinkRefusal> {
        guard let row = session(withID: click.session), let presentation = row.remotePresentation else { return .failure(.notPresenter) }
        // this Mac leads the origin's scratch under its own key for it, not the origin's identity the click carries
        let leadPane = click.pane != nil && click.pane == row.originScratch ? row.scratchClientIdentity : click.pane
        let leads = originTakesLeads && ZmxLeadBook.shared.role(pane: leadPane) == .leader
        guard presentation.mode == .presenter || leads else { return .failure(.notPresenter) }
        guard originSupportsClick else { return .failure(.originTooOld) }
        guard !hidden else { return .failure(.hidden) }
        // a scratch running on the origin is named by the origin's own identity on both sides
        guard let local = click.pane,
              let pane = local == row.originScratch ? local : presentation.binding.remotePane(forLocal: local) else {
            return .failure(.paneNotAttached)
        }
        return .success(PresentationLinkClick(raw: click.raw, pane: pane, mode: click.mode))
    }
}
