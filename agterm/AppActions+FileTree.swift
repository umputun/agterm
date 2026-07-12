import agtermCore
import AppKit
import SwiftUI

extension AppActions {
    /// Show/hide the active session's file-tree panel — a right-hand `NSOutlineView` browsing the session's
    /// captured cwd. Per-session and seeded on the show edge by `AppStore.toggleFileTree`, so each session
    /// keeps its own panel state. Shared by the View menu, the palette, and (Phase 2) the control channel.
    func toggleFileTree() {
        guard let store, let session = store.activeSession else { return }
        store.toggleFileTree(session.id)
        // the tree outline accepts first responder (for Space Quick Look / arrow-nav), so when HIDING it
        // hand keyboard focus back to the terminal rather than leaving it stranded on the gone panel.
        if !session.fileTreeVisible { focusActiveSession() }
    }

    /// Re-root the active session's file-tree panel to the shell's current cwd and re-read it — FSEvents
    /// already keeps the tree fresh on file changes, so the manual ↻ now means "sync the tree to where the
    /// session is now" rather than a re-read in place.
    func rerootFileTree() {
        guard let store, let session = store.activeSession else { return }
        store.rerootFileTree(session.id)
    }

    /// Paste a file's path (shell-escaped) at the active session's prompt — the file tree's "Insert Path"
    /// context action. Uses the bracketed-paste path (like a file drop), so it lands at the cursor without
    /// auto-submitting.
    func insertPath(_ url: URL) {
        // target the ON-SCREEN surface (the scratch when it covers the session, else the focused pane) so the
        // path lands where the user is actually typing — matching the file-drop path and session.text's
        // no-pane resolution, NOT the main-pane-only addressableSurface.
        guard let store, let session = store.activeSession,
              let surface = session.onScreenSurface as? GhosttySurfaceView else { return }
        surface.insertPasted(text: ShellEscape.path(url.path))
    }
}
