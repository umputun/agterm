import Foundation
import agtermCore

extension ControlServer {
    /// releaseHiddenClickedPage frees the session-wide slot a hidden clicked page holds, for the click page about to
    /// open there. Callers run it after every check that could still refuse that open, so a refused click never
    /// costs the old page; `persistent` adds the saved-store check a web link's open makes.
    func releaseHiddenClickedPage(session id: UUID, persistent: Bool) {
        if persistent, HtmlOverlayRegistry.shared.persistentStoreFailure() != nil { return }
        library.store(forSession: id)?.releaseHiddenClickedPage(id)
    }
}
