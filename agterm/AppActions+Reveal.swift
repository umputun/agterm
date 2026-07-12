import agtermCore
import AppKit
import SwiftUI

extension AppActions {
    /// Reveal the active session's focused-pane cwd in Finder. Finder gets the directory itself selected
    /// (rather than opening arbitrary terminal output), matching "Reveal in Finder" behavior elsewhere on Mac.
    func revealActiveSessionInFinder() {
        guard let store, let id = store.selectedSessionID else { return }
        revealSessionInFinder(id, in: store)
    }

    var canRevealActiveSessionInFinder: Bool {
        guard let store, let id = store.selectedSessionID else { return false }
        return canRevealSessionInFinder(id, in: store)
    }

    func canRevealSessionInFinder(_ id: UUID, in store: AppStore) -> Bool {
        guard let session = store.session(withID: id) else { return false }
        return DirectoryPanelDefaults.existingDirectoryURL(for: session.focusedCwd) != nil
    }

    /// Reveal a specific session's focused-pane cwd in Finder, scoped to the caller's store so a sidebar
    /// context menu in a background window still acts on the clicked row in that window.
    @discardableResult
    func revealSessionInFinder(_ id: UUID, in store: AppStore) -> Bool {
        guard let session = store.session(withID: id),
              let url = DirectoryPanelDefaults.existingDirectoryURL(for: session.focusedCwd)
        else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}
