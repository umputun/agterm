import AppKit
import agtermCore

extension AppActions {
    /// coverTakesSearch is true when what sits on top owns ⌘F, so the terminal behind it never opens or closes its
    /// search: the quick terminal holding the keys, or a shown page or program overlay over the pane the user is in,
    /// full or floating. A text page focuses its own field; every other cover keeps the key and does nothing with it.
    func coverTakesSearch() -> Bool {
        if quickTerminal.holdsKey { return true }
        guard let session = store?.activeSession, session.visibleCover != nil else { return false }
        if let page = session.topmostHtmlOverlay, page.source.kind == .text {
            HtmlOverlayRegistry.shared.existing(page.id)?.focusSearch()
        }
        return true
    }
}
