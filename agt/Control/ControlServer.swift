import agtCore
import Darwin
import Foundation

/// The programmatic control channel: a POSIX unix-domain-socket listener that turns newline-delimited
/// JSON `ControlRequest`s into calls on the existing `AppActions` / `AppStore` seam — the same seam the
/// toolbar, menu bar, and palettes use. One request per connection: read a line, dispatch, write one
/// `ControlResponse`, close.
///
/// `@MainActor`: lifecycle and dispatch run on the main actor (the store is main-actor isolated). Only
/// the blocking accept/read loop runs on a background `DispatchQueue`; each decoded request hops back to
/// the main actor to execute. Best-effort: a bind failure logs and the app still launches.
@MainActor
final class ControlServer {
    private let store: AppStore
    private let actions: AppActions
    private let socketPath: String

    /// The listening socket fd, or -1 when not listening. `start()` is idempotent on this.
    private var listenFD: Int32 = -1
    /// The background queue running the blocking accept loop.
    private let acceptQueue = DispatchQueue(label: "com.umputun.agt.control.accept")

    /// 1 MiB cap on a single request line — far above any realistic `session.type` payload. A line that
    /// exceeds it is rejected and the connection closed, so a bad client can never grow the buffer
    /// unbounded.
    nonisolated private static let maxLineBytes = 1 << 20

    init(store: AppStore, actions: AppActions, socketPath: String? = nil) {
        self.store = store
        self.actions = actions
        self.socketPath = socketPath ?? ControlServer.defaultSocketPath()
    }

    /// The socket path the app and the CLI rendezvous on. `AGT_CONTROL_SOCKET` is an explicit override
    /// (used by tests, whose sandboxed `AGT_STATE_DIR` container path is too long for `sun_path`'s
    /// ~104-byte limit). Otherwise it is `<AGT_STATE_DIR>/agt.sock` when that var is set (state
    /// isolation), else `<app support>/agt.sock`.
    static func defaultSocketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["AGT_CONTROL_SOCKET"] { return explicit }
        return ControlResolve.socketPath(stateDir: env["AGT_STATE_DIR"], appSupport: PersistenceStore.defaultDirectory.path)
    }

    // MARK: - Lifecycle

    /// Bind and start listening. Idempotent: a no-op if already listening (the scene `.task` may re-run if
    /// the window is recreated, so a second `start()` must not attempt a second `bind`). On any failure it
    /// logs and returns, leaving the app to launch normally.
    func start() {
        guard listenFD < 0 else { return }

        guard socketPath.utf8.count < 104 else {
            log("control socket path too long (\(socketPath.utf8.count) bytes): \(socketPath)")
            return
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("control socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        // unlink any stale socket file first (a force-quit that skipped applicationWillTerminate leaves one).
        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                pathBytes.withUnsafeBufferPointer { src in
                    buf.update(from: src.baseAddress!, count: src.count)
                }
            }
        }

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            log("control bind(\(socketPath)) failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        // owner-only access (0600).
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else {
            log("control listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(socketPath)
            return
        }

        listenFD = fd
        acceptLoop(fd: fd)
    }

    /// Close the listener and unlink the socket file.
    func stop() {
        guard listenFD >= 0 else { return }
        close(listenFD)
        listenFD = -1
        unlink(socketPath)
    }

    // MARK: - Accept / read loop

    /// Run the blocking accept loop on the background queue. Each accepted connection is handled inline
    /// (one request → one response → close); connections are rare and short, so a per-connection thread is
    /// unnecessary.
    private func acceptLoop(fd: Int32) {
        acceptQueue.async {
            while true {
                let conn = accept(fd, nil, nil)
                if conn < 0 {
                    // a closed listener (stop()) makes accept fail — exit the loop.
                    if errno == EBADF || errno == EINVAL { return }
                    continue
                }
                ControlServer.handleConnection(conn, server: self)
            }
        }
    }

    /// Read one newline-delimited request from `conn`, decode it, dispatch it on `server` (main actor),
    /// write the encoded response back, and close. A decode failure replies with a structured error rather
    /// than crashing. Runs on the background queue (called from `acceptLoop`).
    nonisolated private static func handleConnection(_ conn: Int32, server: ControlServer) {
        defer { close(conn) }

        guard let line = readLine(conn) else {
            writeResponse(conn, ControlResponse(ok: false, error: "request too large or read failed"))
            return
        }

        let request: ControlRequest
        do {
            request = try JSONDecoder().decode(ControlRequest.self, from: line)
        } catch {
            writeResponse(conn, ControlResponse(ok: false, error: "invalid request: \(error.localizedDescription)"))
            return
        }

        // hop to the main actor to execute, blocking this background thread until it returns.
        let response = runBlocking { await server.dispatch(request) }
        writeResponse(conn, response)
    }

    /// Read bytes from `conn` up to (and excluding) the first newline, capping at `maxLineBytes`. Returns
    /// nil on EOF-before-newline, read error, or cap exceeded.
    nonisolated private static func readLine(_ conn: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(conn, &byte, 1)
            if n == 0 { return buffer.isEmpty ? nil : buffer } // EOF: accept a trailing line without newline.
            if n < 0 { return nil }
            if byte == UInt8(ascii: "\n") { return buffer }
            buffer.append(byte)
            if buffer.count > maxLineBytes { return nil }
        }
    }

    /// Encode `response` and write it back as a single newline-terminated line.
    nonisolated private static func writeResponse(_ conn: Int32, _ response: ControlResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let n = write(conn, base + offset, data.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    /// Run an async closure to completion on a fresh task, blocking the calling (background) thread until it
    /// finishes. Used to bridge the synchronous read loop to the main-actor dispatch without an actor hop on
    /// the loop thread itself.
    nonisolated private static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    /// A minimal mutable box to ferry the async result back across the semaphore.
    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    // MARK: - Dispatch

    /// Execute a request against the store/actions seam. Never throws across the socket: any failure is a
    /// `{"ok":false,"error":…}` response.
    private func dispatch(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .tree:
            return ControlResponse(ok: true, result: ControlResult(tree: buildTree()))
        case .sessionSelect:
            return resolveSession(request.target) { id in
                store.selectSession(id)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .workspaceSelect:
            // selecting a workspace selects its first session (workspace rows are not selectable on
            // their own); an empty workspace just clears nothing and reports the workspace id.
            return resolveWorkspace(request.target) { id in
                if let first = store.workspaces.first(where: { $0.id == id })?.sessions.first {
                    store.selectSession(first.id)
                }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .workspaceNew:
            // name defaults to the auto-generated workspace name when none is given.
            let name = trimmed(request.args?.name) ?? store.defaultWorkspaceName
            let workspace = store.addWorkspace(name: name)
            return ControlResponse(ok: true, result: ControlResult(id: workspace.id.uuidString))
        case .workspaceRename:
            guard let name = trimmed(request.args?.name) else {
                return ControlResponse(ok: false, error: "workspace.rename requires a name")
            }
            return resolveWorkspace(request.target) { id in
                store.renameWorkspace(id, to: name)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .workspaceDelete:
            // honors keep-at-least-one; returns an error rather than the GUI confirm alert.
            return resolveWorkspace(request.target) { id in
                guard store.canRemoveWorkspace else {
                    return ControlResponse(ok: false, error: "cannot delete last workspace")
                }
                store.removeWorkspace(id)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionNew:
            // defaults: the current workspace and $HOME. An explicit `workspace` arg overrides the
            // target workspace; `cwd` overrides the directory.
            let cwd = request.args?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            return resolveWorkspace(request.args?.workspace) { workspaceID in
                guard let session = store.addSession(toWorkspace: workspaceID, cwd: cwd) else {
                    return ControlResponse(ok: false, error: "could not create session")
                }
                return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
            }
        case .sessionClose:
            return resolveSession(request.target) { id in
                store.closeSession(id)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionRename:
            guard let name = request.args?.name else {
                return ControlResponse(ok: false, error: "session.rename requires a name")
            }
            return resolveSession(request.target) { id in
                store.renameSession(id, to: name)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionMove:
            guard let workspace = request.args?.workspace else {
                return ControlResponse(ok: false, error: "session.move requires a workspace")
            }
            return resolveSession(request.target) { sessionID in
                resolveWorkspace(workspace) { workspaceID in
                    store.moveSession(sessionID, toWorkspace: workspaceID)
                    return ControlResponse(ok: true, result: ControlResult(id: sessionID.uuidString))
                }
            }
        case .sessionType:
            guard let text = request.args?.text else {
                return ControlResponse(ok: false, error: "session.type requires text")
            }
            // resolve first, then realize-and-inject; the realize path is async (bounded poll), so this
            // can't go through the synchronous `resolveSession` helper. the not-found / ambiguous error
            // strings below must stay in sync with `resolve(_:candidates:active:noun:_:)`.
            let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
            switch ControlResolve.resolve(request.target ?? "active", candidates: candidates,
                                          active: store.selectedSessionID) {
            case .resolved(let id):
                return await injectText(text, into: id, select: request.args?.select ?? false)
            case .notFound:
                return ControlResponse(ok: false, error: "no such session: \(request.target ?? "active")")
            case .ambiguous(let hits):
                let listed = hits.map { String($0.uuidString.prefix(8)) }.joined(separator: ", ")
                return ControlResponse(ok: false, error: "ambiguous session prefix '\(request.target ?? "active")' → \(listed)")
            }
        case .sessionSplit:
            return splitSession(request.target, mode: request.args?.mode)
        case .sessionCopy:
            return copySelection(request.target)
        case .sessionOverlayOpen:
            guard let command = request.args?.command, !command.isEmpty else {
                return ControlResponse(ok: false, error: "session.overlay.open requires a command")
            }
            return resolveSession(request.target) { id in
                guard store.openOverlay(id, command: command, cwd: request.args?.cwd,
                                        wait: request.args?.wait ?? false) else {
                    return ControlResponse(ok: false, error: "overlay already open")
                }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionOverlayClose:
            return resolveSession(request.target) { id in
                guard store.closeOverlay(id) else {
                    return ControlResponse(ok: false, error: "no overlay")
                }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .quick:
            return setQuickTerminal(mode: request.args?.mode)
        case .statusbar:
            return setStatusBar(mode: request.args?.mode)
        case .fontInc:
            return font(request.target, action: "increase_font_size:1")
        case .fontDec:
            return font(request.target, action: "decrease_font_size:1")
        case .fontReset:
            return font(request.target, action: "reset_font_size")
        }
    }

    // MARK: - Control actions

    /// Resolve the target session and drive the split directly on the store (NOT the argument-less
    /// `AppActions.toggleSplit()`, which only acts on the active session). `mode` is `on|off|toggle`,
    /// computed against the session's current `isSplit` so `on`/`off` are idempotent. Focus follows
    /// via `AppActions.focusSplitPane`.
    private func splitSession(_ target: String?, mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        return resolveSession(target) { id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            let want: Bool
            switch mode {
            case "on": want = true
            case "off": want = false
            case "toggle": want = !session.isSplit
            default: return ControlResponse(ok: false, error: "invalid split mode: \(mode)")
            }
            if want != session.isSplit {
                if want { store.toggleSplit(id) } else { store.closeSplit(id) }
            }
            actions.focusSplitPane(session, wantSplit: want)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Show / hide / toggle the quick terminal, flipping only when the requested state differs from
    /// the current `isVisible`. An unknown mode is an error, not a silent no-op.
    private func setQuickTerminal(mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        let controller = QuickTerminalController.shared
        let want: Bool
        switch mode {
        case "show": want = true
        case "hide": want = false
        case "toggle": want = !controller.isVisible
        default: return ControlResponse(ok: false, error: "invalid quick mode: \(mode)")
        }
        if want != controller.isVisible {
            if want { controller.show() } else { controller.hide() }
        }
        return ControlResponse(ok: true)
    }

    /// Show / hide / toggle the status bar, flipping only when the requested state differs from the
    /// current `statusBarHidden` (`on` shows it → not hidden). An unknown mode is an error.
    private func setStatusBar(mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        let wantHidden: Bool
        switch mode {
        case "on": wantHidden = false
        case "off": wantHidden = true
        case "toggle": wantHidden = !store.statusBarHidden
        default: return ControlResponse(ok: false, error: "invalid statusbar mode: \(mode)")
        }
        if wantHidden != store.statusBarHidden {
            store.setStatusBarHidden(wantHidden)
        }
        return ControlResponse(ok: true)
    }

    /// Resolve the target session and run a font binding action on its surface (targets a specific
    /// surface, unlike the menu path which only hits the focused one). A never-shown session has no
    /// surface yet → error.
    private func font(_ target: String?, action: String) -> ControlResponse {
        return resolveSession(target) { id in
            guard let surface = store.session(withID: id)?.surface as? GhosttySurfaceView else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            surface.performBindingAction(action)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve the target session and return its surface's current selection text in the response (it does
    /// NOT write the system clipboard — automation pipes the returned text into another `session.type`). A
    /// never-shown session has no surface yet → error; an empty or absent selection → "no selection".
    private func copySelection(_ target: String?) -> ControlResponse {
        return resolveSession(target) { id in
            guard let surface = store.session(withID: id)?.surface as? GhosttySurfaceView else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            guard let text = surface.readSelection() else {
                return ControlResponse(ok: false, error: "no selection")
            }
            return ControlResponse(ok: true, result: ControlResult(text: text))
        }
    }

    /// Inject `text` into the session `id`'s surface. A session's surface is created lazily (deferred until
    /// it has a non-zero backing size — a never-shown session has `surface == nil`). `ghostty_surface_text`
    /// writes to the child pty, which the kernel buffers, so text is never lost even before the first prompt.
    /// - surface already realized → inject immediately, ok.
    /// - never realized, `select:true` → select it, then poll for the surface (bounded: 12 × 0.03 s, the
    ///   `focusSplitPane` idiom) and inject on the first realized attempt; never realized → error (never a
    ///   false ok).
    /// - never realized, no select → an immediate "use select" error.
    private func injectText(_ text: String, into id: UUID, select: Bool) async -> ControlResponse {
        if let surface = store.session(withID: id)?.surface as? GhosttySurfaceView {
            surface.inject(text: text)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
        guard select else {
            return ControlResponse(ok: false, error: "session not realized; use select")
        }
        store.selectSession(id)
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if let surface = store.session(withID: id)?.surface as? GhosttySurfaceView {
                surface.inject(text: text)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        }
        return ControlResponse(ok: false, error: "session not realized")
    }

    /// Project the current workspace tree into the wire `ControlTree`, marking the active session and the
    /// active workspace (the one owning the selected session).
    private func buildTree() -> ControlTree {
        let activeID = store.selectedSessionID
        let activeWorkspaceID = activeID.flatMap { store.workspace(forSession: $0)?.id }
        let workspaces = store.workspaces.map { workspace in
            let sessions = workspace.sessions.map { session in
                ControlSessionNode(id: session.id.uuidString, name: session.displayName,
                                   cwd: session.effectiveCwd, active: session.id == activeID,
                                   split: session.isSplit, overlay: session.overlayActive)
            }
            return ControlWorkspaceNode(id: workspace.id.uuidString, name: workspace.name,
                                        active: workspace.id == activeWorkspaceID, sessions: sessions)
        }
        return ControlTree(workspaces: workspaces)
    }

    // MARK: - Target resolution

    /// Resolve `target` (defaulting to `active`) against the session id set and run `body` on success; map
    /// the resolver's not-found / ambiguous outcomes to structured errors.
    private func resolveSession(_ target: String?, _ body: (UUID) -> ControlResponse) -> ControlResponse {
        let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
        return resolve(target ?? "active", candidates: candidates, active: store.selectedSessionID,
                       noun: "session", body)
    }

    /// Resolve `target` (defaulting to `active`) against the workspace id set and run `body` on success.
    private func resolveWorkspace(_ target: String?, _ body: (UUID) -> ControlResponse) -> ControlResponse {
        let candidates = store.workspaces.map(\.id)
        return resolve(target ?? "active", candidates: candidates, active: store.currentWorkspaceID,
                       noun: "workspace", body)
    }

    private func resolve(_ target: String, candidates: [UUID], active: UUID?, noun: String,
                         _ body: (UUID) -> ControlResponse) -> ControlResponse {
        switch ControlResolve.resolve(target, candidates: candidates, active: active) {
        case .resolved(let id):
            return body(id)
        case .notFound:
            return ControlResponse(ok: false, error: "no such \(noun): \(target)")
        case .ambiguous(let hits):
            let listed = hits.map { String($0.uuidString.prefix(8)) }.joined(separator: ", ")
            return ControlResponse(ok: false, error: "ambiguous \(noun) prefix '\(target)' → \(listed)")
        }
    }

    /// `value` trimmed of surrounding whitespace, or nil if absent or blank after trimming.
    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func log(_ message: @autoclosure () -> String) {
        NSLog("agt: %@", message())
    }
}
