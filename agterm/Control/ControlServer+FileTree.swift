import Foundation
import agtermCore

/// `ControlServer` file-tree action arm — the `session.filetree` command's app-side side effects
/// (show/hide/refresh/reroot), including the app-side path existence/directory validation the host-free
/// dispatcher can't do. Split out of `ControlServer+SessionActions.swift` for the swiftlint size limit.
extension ControlServer {
    func fileTreeSession(_ target: String?, window: String?, mode: String?, path: String?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            // `refresh` re-roots the tree to the session's current cwd and re-reads it (bumps
            // `fileTreeRefreshToken`) — no visibility change — so it short-circuits before the on|off|toggle
            // parse. FSEvents already auto-re-reads on file changes, so the manual refresh means "sync to cwd".
            if mode == "refresh" {
                store.rerootFileTree(id)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
            // `reroot` points the tree at an arbitrary path (not the cwd) and re-reads it. FS validation is
            // app-side (the dispatcher stays host-free): the path must exist AND be a directory. Mirrors the
            // `session.background image` existence check in ControlServer+SurfaceIO.
            if mode == "reroot" {
                guard let path, !path.isEmpty else {
                    return ControlResponse(ok: false, error: "session.filetree reroot requires a path")
                }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                    return ControlResponse(ok: false, error: "no such directory: \(path)")
                }
                store.rerootFileTree(id, to: path)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
            guard let parsedMode = ControlToggleMode.parse(mode) else {
                return ControlResponse(ok: false, error: "invalid filetree mode: \(mode ?? "toggle")")
            }
            // seeds the root on the show edge + persists visibility; mirrors ⌃⌘E / AppActions.toggleFileTree.
            store.setFileTreeVisible(parsedMode.desiredValue(current: session.fileTreeVisible), forSession: id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }
}
