import AppKit
import agtermCore
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
    /// The window library; commands dispatch onto a per-request target window's store. A `tree` or a
    /// placement/`active` command with no `args.window` targets the frontmost window; with
    /// `args.window` it targets that window (which must be open). An id/prefix session/workspace
    /// target with no `args.window` is resolved across ALL open windows so a captured id resolves
    /// regardless of which window is frontmost. The `window.*` commands drive the library itself.
    private let library: WindowLibrary
    private let actions: AppActions
    private let settingsModel: SettingsModel
    private let socketPath: String

    /// The frontmost open window's store — the default target of a placement/`active` command. Falls
    /// back to an empty throwaway only in the all-windows-closed state (the app is quitting), where no
    /// command can meaningfully run; the library is never windowless at launch.
    private lazy var emptyStore = AppStore()
    private var store: AppStore { library.activeStore ?? emptyStore }

    /// The listening socket fd, or -1 when not listening. `start()` is idempotent on this.
    private var listenFD: Int32 = -1

    /// The socket path the listener actually bound, or nil when it isn't listening (bind failed or
    /// not started).
    var boundSocketPath: String? { listenFD >= 0 ? socketPath : nil }

    /// The path the listener will bind (it's resolved at init via `defaultSocketPath()`, honoring a
    /// test's `AGTERM_CONTROL_SOCKET` override). The surface factories read this into `AGTERM_SOCKET` so a
    /// shell spawned BEFORE `start()` binds (the launch window's surfaces can materialize first) still
    /// sees the socket it will be able to reach — `boundSocketPath` would be nil for those, leaking
    /// AGTERM_SOCKET permanently. Equal to `boundSocketPath` once bound.
    var resolvedSocketPath: String { socketPath }
    /// The background queue running the blocking accept loop.
    private let acceptQueue = DispatchQueue(label: "com.umputun.agterm.control.accept")

    /// Thread-safe cached window list, refreshed on the main actor after every dispatched command and
    /// read (under the lock) from the background accept loop. Lets `window.list` / `tree --window`
    /// queries be answered without the main actor, so a brief main-thread stall after a window close
    /// can't make the serial control server unresponsive to polls.
    private let cacheLock = NSLock()
    nonisolated(unsafe) private var cachedWindowNodes: [ControlWindowNode] = []

    nonisolated private func cachedWindows() -> [ControlWindowNode] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cachedWindowNodes
    }

    @MainActor func refreshWindowCache() {
        let nodes = buildWindowList()
        cacheLock.lock(); cachedWindowNodes = nodes; cacheLock.unlock()
    }

    /// A cache-only response for read-only window queries, or nil to fall through to the main actor.
    /// Falls through on a cold cache (the main-actor path will populate it) and for `tree --window`
    /// targeting an OPEN window (building the tree needs the main actor); only the closed-window error
    /// and `window.list` are answered here.
    nonisolated func fastPathResponse(for request: ControlRequest) -> ControlResponse? {
        let nodes = cachedWindows()
        guard !nodes.isEmpty else { return nil }
        switch request.cmd {
        case .windowList:
            return ControlResponse(ok: true, result: ControlResult(windows: nodes))
        case .tree:
            guard let target = request.args?.window, !target.isEmpty else { return nil }
            let candidates = nodes.compactMap { UUID(uuidString: $0.id) }
            let active = nodes.first { $0.active }.flatMap { UUID(uuidString: $0.id) }
            guard case .resolved(let id) = ControlResolve.resolve(target, candidates: candidates, active: active),
                  let node = nodes.first(where: { $0.id == id.uuidString }), !node.open else { return nil }
            return ControlResponse(ok: false, error: "window not open — window.select it first")
        default:
            return nil
        }
    }

    /// 1 MiB cap on a single request line — far above any realistic `session.type` payload. A line that
    /// exceeds it is rejected and the connection closed, so a bad client can never grow the buffer
    /// unbounded.
    nonisolated private static let maxLineBytes = 1 << 20

    /// Seconds a blocking client read may stall before it times out (EAGAIN → connection closed), so a
    /// stalled client can't park the serial accept loop forever.
    nonisolated private static let readTimeoutSeconds = 5

    /// Overall seconds a single connection's request read may take before it's abandoned. `readTimeoutSeconds`
    /// only bounds each `read()`, so a slow-loris client trickling one byte per interval (each under the
    /// per-read timeout) never sends a newline yet keeps the serial accept loop busy indefinitely. This caps
    /// the total read time; a legit one-line request arrives in milliseconds, far under the cap.
    nonisolated private static let readDeadlineSeconds = 10

    init(library: WindowLibrary, actions: AppActions, settingsModel: SettingsModel, socketPath: String? = nil) {
        self.library = library
        self.actions = actions
        self.settingsModel = settingsModel
        self.socketPath = socketPath ?? ControlServer.defaultSocketPath()
        // keep the read cache's `active` flag fresh across async frontmost changes (this server lives
        // for the app's lifetime, so the observer doesn't need removal).
        NotificationCenter.default.addObserver(forName: .agtermWindowFrontmostChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowCache() }
        }
    }

    /// The socket path the app and the CLI rendezvous on. `AGTERM_CONTROL_SOCKET` is an explicit override
    /// (used by tests, whose sandboxed `AGTERM_STATE_DIR` container path is too long for `sun_path`'s
    /// ~104-byte limit). Otherwise it is `<AGTERM_STATE_DIR>/agterm.sock` when that var is set (state
    /// isolation), else `<app support>/agterm.sock`.
    static func defaultSocketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["AGTERM_CONTROL_SOCKET"] { return explicit }
        return ControlResolve.socketPath(stateDir: env["AGTERM_STATE_DIR"], appSupport: PersistenceStore.defaultDirectory.path)
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
        // never let a write to a client that already hung up raise SIGPIPE (default-fatal) — that would
        // take the whole app down mid-request; SO_NOSIGPIPE turns it into a normal EPIPE write error.
        var noSigPipe: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // bound the blocking read so a stalled client can't park the serial accept loop forever — a
        // timed-out read returns EAGAIN, which readLine treats as a read error and closes the connection.
        var readTimeout = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))

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

        // fast-path read-only window queries from a thread-safe cache, WITHOUT hopping to the main
        // actor: a window close can briefly stall the main thread (surface teardown / re-render), and
        // the serial accept loop would otherwise go unresponsive to `window.list` polls behind it.
        if let cached = server.fastPathResponse(for: request) {
            writeResponse(conn, cached)
            return
        }

        // hop to the main actor to execute, blocking this background thread until it returns. dispatch
        // refreshes the window cache itself (single main-actor execution), so the fast path reflects
        // this command's mutations without a second hop that could queue behind a post-close stall.
        let response = runBlocking { await server.dispatch(request) }
        writeResponse(conn, response)
    }

    /// Read bytes from `conn` up to (and excluding) the first newline, capping at `maxLineBytes`. Returns
    /// nil on EOF-before-newline, read error, the `maxLineBytes` cap, or the `readDeadlineSeconds` overall cap.
    nonisolated private static func readLine(_ conn: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        // overall deadline: SO_RCVTIMEO bounds each read, but a slow trickle (a byte per sub-timeout
        // interval) would otherwise loop forever without a newline. cap the total read time too.
        let deadline = DispatchTime.now() + .seconds(readDeadlineSeconds)
        while true {
            if DispatchTime.now() > deadline { return nil }
            let n = read(conn, &byte, 1)
            if n == 0 { return buffer.isEmpty ? nil : buffer } // EOF: accept a trailing line without newline.
            if n < 0 {
                if errno == EINTR { continue } // a signal interrupted the blocking read; retry
                return nil
            }
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
                if n < 0 {
                    if errno == EINTR { continue } // retry an interrupted write
                    return
                }
                if n == 0 { return }
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
        // refresh the read cache within this same main-actor execution (a window mutation just ran), so
        // the background fast path sees the new state without a separate hop that could stall.
        defer { refreshWindowCache() }
        switch request.cmd {
        case .tree:
            return resolvePlacementStore(request.args?.window) { store in
                ControlResponse(ok: true, result: ControlResult(tree: buildTree(in: store)))
            }
        case .sessionSelect:
            return resolveSession(request.target, window: request.args?.window) { store, id in
                store.selectSession(id)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionGo:
            // relative navigation acts on the store's current selection, so no session target — just
            // the frontmost-or-`--window` store. unknown/missing `to` is a structured error.
            guard let dir = (request.args?.to).flatMap(SessionNavigation.init(wire:)) else {
                return ControlResponse(ok: false, error: "session.go requires --to next|prev|first|last|next-attention|prev-attention")
            }
            return resolvePlacementStore(request.args?.window) { store in
                store.navigateSession(dir)
                guard let id = store.selectedSessionID else {
                    return ControlResponse(ok: false, error: "no session to navigate")
                }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .workspaceSelect:
            // selecting a workspace selects its first session (workspace rows are not selectable on
            // their own); an empty workspace just clears nothing and reports the workspace id.
            return resolveWorkspace(request.target, window: request.args?.window) { store, id in
                if let first = store.workspaces.first(where: { $0.id == id })?.sessions.first {
                    store.selectSession(first.id)
                }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .workspaceNew:
            // placement target: the window's frontmost store (or `args.window`'s). name defaults to
            // the auto-generated workspace name when none is given.
            return resolvePlacementStore(request.args?.window) { store in
                let name = trimmed(request.args?.name) ?? store.defaultWorkspaceName
                let workspace = store.addWorkspace(name: name)
                return ControlResponse(ok: true, result: ControlResult(id: workspace.id.uuidString))
            }
        case .workspaceRename:
            guard let name = trimmed(request.args?.name) else {
                return ControlResponse(ok: false, error: "workspace.rename requires a name")
            }
            return resolveWorkspace(request.target, window: request.args?.window) { store, id in
                store.renameWorkspace(id, to: name)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .workspaceDelete:
            // honors keep-at-least-one; returns an error rather than the GUI confirm alert.
            return resolveWorkspace(request.target, window: request.args?.window) { store, id in
                guard store.canRemoveWorkspace else {
                    return ControlResponse(ok: false, error: "cannot delete last workspace")
                }
                store.removeWorkspace(id)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionNew:
            // the destination workspace is addressed one of two mutually-exclusive ways: `workspace`
            // (id / unique prefix / `active`, the default) or `workspaceName` (the sidebar label),
            // the latter optionally with `createWorkspace` to add it when absent. create needs a name —
            // there is nothing to create by id. cwd/command/name are applied in makeSessionResponse.
            let args = request.args
            if args?.workspace != nil, args?.workspaceName != nil {
                return ControlResponse(ok: false, error: "use either --workspace or --workspace-name, not both")
            }
            if args?.createWorkspace == true, args?.workspaceName == nil {
                return ControlResponse(ok: false, error: "--create-workspace requires --workspace-name")
            }
            return resolvePlacementStore(args?.window) { store in
                // name addressing: reuse-or-create with `createWorkspace`, else require an existing match.
                if let name = args?.workspaceName {
                    // a blank name can neither be found NOR created — report that directly rather than
                    // suggesting --create-workspace (which would also reject a blank name).
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return ControlResponse(ok: false, error: "workspace name must not be blank")
                    }
                    let workspace = args?.createWorkspace == true
                        ? store.ensureWorkspace(named: name)
                        : store.workspace(named: name)
                    guard let workspace else {
                        return ControlResponse(ok: false, error: "no workspace named \"\(name)\" (pass --create-workspace to add it)")
                    }
                    return makeSessionResponse(in: store, workspaceID: workspace.id, args: args)
                }
                // id addressing (default `active`): the canonical prefix/active resolver.
                let target = args?.workspace ?? "active"
                return resolve(target, candidates: store.workspaces.map(\.id),
                               active: store.currentWorkspaceID, noun: "workspace") { workspaceID in
                    makeSessionResponse(in: store, workspaceID: workspaceID, args: args)
                }
            }
        case .sessionClose:
            return resolveSession(request.target, window: request.args?.window) { store, id in
                store.closeSession(id)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionRename:
            guard let name = request.args?.name else {
                return ControlResponse(ok: false, error: "session.rename requires a name")
            }
            return resolveSession(request.target, window: request.args?.window) { store, id in
                store.renameSession(id, to: name)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionMove:
            return moveSession(request.target, window: request.args?.window,
                               to: request.args?.to, workspace: request.args?.workspace)
        case .workspaceMove:
            return moveWorkspace(request.target, window: request.args?.window, to: request.args?.to)
        case .workspaceFocus:
            return focusWorkspace(request.target, window: request.args?.window, mode: request.args?.mode)
        case .sessionType:
            guard let text = request.args?.text else {
                return ControlResponse(ok: false, error: "session.type requires text")
            }
            // resolve first (cross-window when no `args.window`), then realize-and-inject; the realize
            // path is async (bounded poll), so this can't go through the synchronous `resolveSession`
            // helper. the not-found / ambiguous error strings must stay in sync with `resolve(...)`.
            switch resolveSessionTarget(request.target, window: request.args?.window) {
            case .failure(let response):
                return response
            case .success(let (store, id)):
                return await injectText(text, into: id, store: store, select: request.args?.select ?? false)
            }
        case .sessionSplit:
            return splitSession(request.target, window: request.args?.window, mode: request.args?.mode)
        case .sessionScratch:
            return scratchSession(request.target, window: request.args?.window, mode: request.args?.mode,
                                  command: request.args?.command)
        case .sessionFocus:
            return focusSessionPane(request.target, window: request.args?.window, pane: request.args?.pane)
        case .sessionStatus:
            return setSessionStatus(request.target, window: request.args?.window,
                                    update: StatusUpdate(status: request.args?.status, blink: request.args?.blink,
                                                         autoReset: request.args?.autoReset, sound: request.args?.sound))
        case .sessionFlag:
            return flagSession(request.target, window: request.args?.window, mode: request.args?.mode)
        case .sessionCopy:
            return copySelection(request.target, window: request.args?.window)
        case .sessionSearch:
            // resolve first (cross-window when no `args.window`), then select + realize the surface; the
            // realize path is async (bounded poll), so this can't go through the synchronous
            // `resolveSession` helper. error strings stay in sync with `resolve(...)`.
            switch resolveSessionTarget(request.target, window: request.args?.window) {
            case .failure(let response):
                return response
            case .success(let (store, id)):
                return await searchSession(id, store: store, text: request.args?.text, to: request.args?.to)
            }
        case .sessionOverlayOpen:
            guard let command = request.args?.command, !command.isEmpty else {
                return ControlResponse(ok: false, error: "session.overlay.open requires a command")
            }
            return resolveSession(request.target, window: request.args?.window) { store, id in
                guard store.openOverlay(id, command: command, cwd: request.args?.cwd,
                                        wait: request.args?.wait ?? false,
                                        sizePercent: request.args?.sizePercent) else {
                    return ControlResponse(ok: false, error: "overlay already open")
                }
                // a FLOATING overlay (sizePercent set) renders only for the ACTIVE session, so on a non-active
                // target its surface never mounts and its program never runs — and `--block` would poll
                // forever. select the target so it mounts and runs (the full overlay mounts in the eager deck
                // regardless, so this only matters for floating).
                if request.args?.sizePercent != nil {
                    store.selectSession(id)
                }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionOverlayClose:
            return resolveSession(request.target, window: request.args?.window) { store, id in
                guard store.closeOverlay(id) else {
                    return ControlResponse(ok: false, error: "no overlay")
                }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionOverlayResult:
            return resolveSession(request.target, window: request.args?.window) { store, id in
                guard let session = store.session(withID: id) else {
                    return ControlResponse(ok: false, error: "no such session")
                }
                if session.overlayActive {
                    return ControlResponse(ok: false, error: OverlayResultError.stillRunning)
                }
                guard let code = session.overlayExitCode else {
                    return ControlResponse(ok: false, error: OverlayResultError.noResult)
                }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, exitCode: code))
            }
        case .quick:
            return setQuickTerminal(mode: request.args?.mode)
        case .sidebar:
            return setSidebar(mode: request.args?.mode)
        case .sidebarMode:
            return setSidebarViewMode(mode: request.args?.mode)
        case .sidebarExpand:
            return expandWorkspaces(window: request.args?.window)
        case .sidebarCollapse:
            return collapseWorkspaces(window: request.args?.window)
        case .notify:
            return sendNotification(request.target, window: request.args?.window,
                                    title: request.args?.title, body: request.args?.body)
        case .fontInc:
            return font(request.target, window: request.args?.window, action: "increase_font_size:1")
        case .fontDec:
            return font(request.target, window: request.args?.window, action: "decrease_font_size:1")
        case .fontReset:
            return font(request.target, window: request.args?.window, action: "reset_font_size")
        case .windowNew:
            return windowNew(name: request.args?.name)
        case .windowList:
            return ControlResponse(ok: true, result: ControlResult(windows: buildWindowList()))
        case .windowSelect:
            return await windowSelect(request.target)
        case .windowClose:
            return await windowClose(request.target)
        case .windowRename:
            return windowRename(request.target, name: request.args?.name)
        case .windowDelete:
            return windowDelete(request.target)
        case .windowResize:
            return windowResize(request.target, width: request.args?.width, height: request.args?.height)
        case .windowMove:
            return windowMove(request.target, x: request.args?.x, y: request.args?.y, display: request.args?.display)
        case .keymapReload:
            return reloadKeymap()
        case .configReload:
            return reloadGhosttyConfig()
        case .themeSet:
            return setTheme(name: request.args?.name)
        case .themeList:
            return ControlResponse(ok: true, result: ControlResult(theme: actions.currentTheme,
                                                                    themes: actions.availableThemes()))
        case .restoreClear:
            return clearSavedCommands()
        }
    }

    /// Clear every open session's saved foreground command (the restore-running-command capture) and
    /// persist, so the next launch restores plain shells. The live fields are normally already nil
    /// (consumed at restore); the SAVE is what wipes the on-disk copy from the last quit, also closing
    /// the force-quit re-fire window. Drives `restore.clear` / `agtermctl restore clear`. App-global like
    /// `keymap.reload` (no `--window` selector — it clears every open window).
    private func clearSavedCommands() -> ControlResponse {
        for session in library.allOpenSessions() {
            session.foregroundCommand = nil
            session.splitForegroundCommand = nil
        }
        library.saveAllOpen()
        return ControlResponse(ok: true)
    }

    // MARK: - Control actions

    /// Resolve the target session and drive the split directly on its owning store (NOT the
    /// argument-less `AppActions.toggleSplit()`, which only acts on the active session). `mode` is
    /// `on|off|toggle`, computed against the session's current `isSplit` so `on`/`off` are
    /// idempotent. Always via `AppStore.toggleSplit` — a keep-alive hide/show that mirrors ⌘D and
    /// never tears the hidden pane's surface down (`closeSplit` stays the shell-exit-only path).
    /// Focus follows via `AppActions.focusSplitPane`.
    private func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        return resolveSession(target, window: window) { store, id in
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
                store.toggleSplit(id) // mirror ⌘D: keep-alive hide/show, never destroys the hidden pane
            }
            actions.focusSplitPane(session, wantSplit: session.splitFocused)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve the target session and show/hide its scratch terminal — a third, full-overlay shell.
    /// `mode` is `on|off|toggle`, computed against the session's current `scratchActive` so `on`/`off`
    /// are idempotent. Like the split, hiding keeps the shell alive (`toggleScratch`); `closeScratch`
    /// (tear down) is reserved for the shell's own `exit`. `command` (only meaningful when showing) runs
    /// that program as the scratch's process instead of a login shell, run-once like `session.new
    /// --command`: a scratch is expendable, so if one is already alive it is torn down and respawned
    /// with the command (otherwise the flag would be silently inert).
    private func scratchSession(_ target: String?, window: String?, mode: String?, command: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        return resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            let want: Bool
            switch mode {
            case "on": want = true
            case "off": want = false
            case "toggle": want = !session.scratchActive
            default: return ControlResponse(ok: false, error: "invalid scratch mode: \(mode)")
            }
            if want, let command, !command.isEmpty {
                // run the command as the scratch process: respawn if one is already alive (a scratch is
                // expendable), so the command is never silently ignored. closeScratch clears scratchActive,
                // so the toggle below re-shows it and the factory consumes scratchCommand.
                if session.scratchSurface != nil { store.closeScratch(id) }
                session.scratchCommand = command
            }
            if want, store.selectedSessionID != id {
                // the scratch is a full-coverage surface that grabs focus on show; it only makes sense on
                // the visible session, so select the target first (mirrors the floating-overlay arm).
                // Otherwise a non-active target's scratch surface would steal first responder while hidden.
                store.selectSession(id)
            }
            if want != session.scratchActive {
                store.toggleScratch(id) // keep-alive hide/show, mirrors ⌘J; never tears the shell down
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Move keyboard focus to a split session's left/right pane. `pane` is `left`|`right`|`other`
    /// (`other` toggles). Errors when the session isn't split or the pane value is unknown.
    private func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse {
        let pane = pane ?? "other"
        return resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard session.hasSplit else {
                return ControlResponse(ok: false, error: "session has no split")
            }
            let toSplit: Bool
            switch pane {
            case "left", "primary": toSplit = false
            case "right", "split": toSplit = true
            case "other", "toggle": toSplit = !session.splitFocused
            default: return ControlResponse(ok: false, error: "invalid pane: \(pane)")
            }
            actions.setSplitFocus(toSplit, of: session)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Set the target session's agent-status indicator (control-native: no GUI/menu equivalent, like
    /// `notify`/`session.type`/`session.copy`). `status` is `idle|active|completed|blocked`; an unknown
    /// value is the structured `invalid status` error. `blink` (default false) pulses the glyph;
    /// `autoReset` (default false) clears the indicator to idle once the session is visited. `sound`, when
    /// non-empty, plays a one-shot sound once the status is applied (`default`/`beep` = system alert, any
    /// other value = named system sound); it is validated up-front so an unknown name is an `unknown sound`
    /// error that leaves the status unchanged (an empty value is treated as no per-call sound). When no
    /// per-call `sound` is given and the session TRANSITIONS into `blocked`, the user's configured Settings
    /// "Blocked sound" (`blockedStatusSoundName`) plays as a best-effort default. The indicator is ephemeral
    /// and rendered on every non-idle session.
    /// The per-call status payload for `setSessionStatus`; the addressing target/window stay separate.
    private struct StatusUpdate {
        let status: String?
        let blink: Bool?
        let autoReset: Bool?
        let sound: String?
    }

    private func setSessionStatus(_ target: String?, window: String?, update: StatusUpdate) -> ControlResponse {
        let status = update.status, blink = update.blink, autoReset = update.autoReset, sound = update.sound
        guard let parsed = AgentStatus(rawValue: status ?? "") else {
            return ControlResponse(ok: false, error: "invalid status")
        }
        // an explicit per-call sound is validated up-front: an unknown name errors without changing status.
        // an empty value is treated as no per-call sound, matching `AgentStatus.effectiveSound`.
        if let sound, !sound.isEmpty, StatusSoundPlayer.shared.action(for: sound) == nil {
            let hint = StatusSoundPlayer.standardNames.joined(separator: ", ")
            return ControlResponse(ok: false, error: "unknown sound: \(sound) (use 'default', 'beep', or one of: \(hint))")
        }
        return resolveSession(target, window: window) { store, id in
            // capture the status BEFORE mutating so the Settings default plays only on a real transition.
            let wasBlocked = store.session(withID: id)?.agentIndicator.status == .blocked
            store.setAgentIndicator(AgentIndicator(status: parsed, blink: blink ?? false,
                                                   autoReset: autoReset ?? false), forSession: id)
            // explicit per-call sound wins on any status; the Settings default plays only when a session
            // newly enters `blocked`, not on a repeated `blocked` set.
            let blockedDefault = wasBlocked ? nil : self.settingsModel.settings.blockedStatusSoundName
            if let name = parsed.effectiveSound(perCall: sound, blockedDefault: blockedDefault) {
                StatusSoundPlayer.shared.play(name)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Flag/unflag the target session for the flagged working-set view (the durable `Session.flagged`
    /// membership the flat sidebar mode projects). `mode` is `on|off|toggle|clear`, computed against the
    /// session's current `flagged` so `on`/`off` are idempotent. `clear` ignores the target and unflags
    /// every session in the resolved store (frontmost or `--window`), via `AppStore.clearFlags()` — it
    /// reports ok with no id. An unknown mode is an error.
    private func flagSession(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        if mode == "clear" {
            return resolvePlacementStore(window) { store in
                store.clearFlags()
                return ControlResponse(ok: true)
            }
        }
        return resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            let want: Bool
            switch mode {
            case "on": want = true
            case "off": want = false
            case "toggle": want = !session.flagged
            default: return ControlResponse(ok: false, error: "invalid flag mode: \(mode)")
            }
            store.setFlag(want, forSession: id) // no-op + no save when unchanged (idempotent)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Mode-bearing `session.move`: `to` reorders the session within its own workspace
    /// (`up`|`down`|`top`|`bottom`), `workspace` relocates it to another workspace (appending). Exactly
    /// one of the two is required; both set or neither set is an error. An invalid `to` direction errors.
    private func moveSession(_ target: String?, window: String?, to: String?, workspace: String?) -> ControlResponse {
        if to != nil && workspace != nil {
            return ControlResponse(ok: false, error: "session.move takes either --to or a workspace, not both")
        }
        if let to {
            guard let dir = ReorderDirection(rawValue: to) else {
                return ControlResponse(ok: false, error: "session.move --to must be up|down|top|bottom")
            }
            return resolveSession(target, window: window) { store, id in
                store.reorderSession(id, dir)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        }
        guard let workspace else {
            return ControlResponse(ok: false, error: "session.move requires --to or a workspace")
        }
        // the session and the destination workspace must live in the same store: resolve the
        // session first (which fixes the store), then the workspace within that same store.
        return resolveSession(target, window: window) { store, sessionID in
            resolve(workspace, candidates: store.workspaces.map(\.id),
                    active: store.currentWorkspaceID, noun: "workspace") { workspaceID in
                store.moveSession(sessionID, toWorkspace: workspaceID)
                return ControlResponse(ok: true, result: ControlResult(id: sessionID.uuidString))
            }
        }
    }

    /// `workspace.move`: reorder a workspace among its siblings (`up`|`down`|`top`|`bottom`). `to` is
    /// required; an invalid direction errors. Resolves the workspace target via `resolveWorkspace`
    /// (honoring the global `--window` selector like other workspace commands).
    private func moveWorkspace(_ target: String?, window: String?, to: String?) -> ControlResponse {
        guard let to else {
            return ControlResponse(ok: false, error: "workspace.move requires --to")
        }
        guard let dir = ReorderDirection(rawValue: to) else {
            return ControlResponse(ok: false, error: "workspace.move --to must be up|down|top|bottom")
        }
        return resolveWorkspace(target, window: window) { store, id in
            store.reorderWorkspace(id, dir)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Focus (or unfocus) a workspace — collapse the sidebar tree to that workspace's subtree, or restore
    /// the full tree. `mode` is `on|off|toggle`: `on` focuses the target, `off` unfocuses it only when it
    /// is the currently focused one (a no-op otherwise), `toggle` flips. Delta-computed via
    /// `AppStore.setFocusedWorkspace` so a no-op mode skips the write (idempotent). An unknown mode is an
    /// error. The control half of the workspace row's Focus/Unfocus menu + the pill ✕.
    private func focusWorkspace(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        return resolveWorkspace(target, window: window) { store, id in
            let want: UUID?
            switch mode {
            case "on": want = id
            case "off": want = store.focusedWorkspaceID == id ? nil : store.focusedWorkspaceID
            case "toggle": want = store.focusedWorkspaceID == id ? nil : id
            default: return ControlResponse(ok: false, error: "invalid focus mode: \(mode)")
            }
            store.setFocusedWorkspace(want) // no-op + no save when unchanged (idempotent)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Post a desktop notification attributed to a session (default: the active session of the
    /// frontmost window, via `resolveSession`). `title` defaults to the session name; `body` is
    /// required. Errors when no open window owns the resolved session.
    private func sendNotification(_ target: String?, window: String?, title: String?, body: String?) -> ControlResponse {
        guard let body, !body.isEmpty else {
            return ControlResponse(ok: false, error: "notify requires a body")
        }
        return resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            guard NotificationManager.shared.send(toSession: session, title: title ?? "", body: body) else {
                return ControlResponse(ok: false, error: "session's window is not open")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Show / hide / toggle the frontmost window's quick terminal (each window owns its own),
    /// flipping only when the requested state differs from the current `isVisible`. An unknown mode
    /// is an error, not a silent no-op; no open window is an error rather than a silent no-op.
    private func setQuickTerminal(mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        guard let controller = QuickTerminalRegistry.shared.controller(for: library.activeWindowID) else {
            return ControlResponse(ok: false, error: "no open window")
        }
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

    /// Show / hide / toggle the frontmost window's sidebar (the custom split owns visibility, so there's
    /// no system toggle). Flips only when the requested state differs; an unknown mode is an error, and no
    /// open window is an error rather than a silent no-op.
    private func setSidebar(mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        guard let store = library.activeStore else {
            return ControlResponse(ok: false, error: "no open window")
        }
        let want: Bool
        switch mode {
        case "show": want = true
        case "hide": want = false
        case "toggle": want = !store.sidebarVisible
        default: return ControlResponse(ok: false, error: "invalid sidebar mode: \(mode)")
        }
        if want != store.sidebarVisible {
            store.sidebarVisible = want
            store.save() // sidebarVisible is persisted per-window
        }
        return ControlResponse(ok: true)
    }

    /// Set the frontmost window's sidebar VIEW mode (the tree vs the flat flagged list) — distinct from
    /// `setSidebar` (visibility). `mode` is `tree|flagged|toggle`, delta-computed so a no-op mode skips
    /// the write (idempotent), via `AppStore.setSidebarMode`. An unknown mode + no-open-window are errors.
    private func setSidebarViewMode(mode: String?) -> ControlResponse {
        let mode = mode ?? "toggle"
        guard let store = library.activeStore else {
            return ControlResponse(ok: false, error: "no open window")
        }
        let want: SidebarMode
        switch mode {
        case "tree": want = .tree
        case "flagged": want = .flagged
        case "toggle": want = store.sidebarMode == .tree ? .flagged : .tree
        default: return ControlResponse(ok: false, error: "invalid sidebar mode: \(mode)")
        }
        store.setSidebarMode(want) // no-op + no save when unchanged (idempotent)
        return ControlResponse(ok: true)
    }

    /// Expand every workspace in a window's sidebar tree — the `--window` selector picks the (OPEN) target,
    /// defaulting to the frontmost window (a graceful no-op in flagged mode, which has no workspace rows).
    /// Drives `AppActions.expandAllWorkspaces(in:)` (the same path the View menu / palette drive on the
    /// frontmost). Idempotent (expanding when all are already expanded is a clean no-op); a named-but-closed
    /// window errors, and no open window at all errors rather than silently no-opping.
    private func expandWorkspaces(window: String?) -> ControlResponse {
        if trimmed(window) == nil, library.activeStore == nil {
            return ControlResponse(ok: false, error: "no open window")
        }
        return resolvePlacementStore(window) { store in
            actions.expandAllWorkspaces(in: store)
            return ControlResponse(ok: true)
        }
    }

    /// Collapse every workspace except the active one (the active session's workspace) in a window's
    /// sidebar, keeping that workspace expanded and scrolled into view. The `--window` selector picks the
    /// (OPEN) target, defaulting to the frontmost. Drives `AppActions.collapseOtherWorkspaces(in:)`.
    /// Graceful no-op in flagged mode; idempotent; a named-but-closed window errors, and no open window
    /// at all errors.
    private func collapseWorkspaces(window: String?) -> ControlResponse {
        if trimmed(window) == nil, library.activeStore == nil {
            return ControlResponse(ok: false, error: "no open window")
        }
        return resolvePlacementStore(window) { store in
            actions.collapseOtherWorkspaces(in: store)
            return ControlResponse(ok: true)
        }
    }

    /// Resolve the target session and run a font binding action on its surface (targets a specific
    /// surface, unlike the menu path which only hits the focused one). A never-shown session has no
    /// surface yet → error.
    private func font(_ target: String?, window: String?, action: String) -> ControlResponse {
        return resolveSession(target, window: window) { store, id in
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
    private func copySelection(_ target: String?, window: String?) -> ControlResponse {
        return resolveSession(target, window: window) { store, id in
            guard let surface = store.session(withID: id)?.surface as? GhosttySurfaceView else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            guard let text = surface.readSelection() else {
                return ControlResponse(ok: false, error: "no selection")
            }
            return ControlResponse(ok: true, result: ControlResult(text: text))
        }
    }

    /// Drive in-terminal search on the session `id`, mirroring the GUI bar and the
    /// `session.type`/floating-overlay arms. On the `close` path it drives the session's pinned
    /// `searchSurface` WITHOUT selecting (so closing a background session's bar never yanks the user's
    /// visible selection — `endSearch()` is a side-effect-free exit, like `session.copy`). For
    /// open/needle/navigate it SELECTS the target so the bar + highlights are visible and the surface
    /// mounts, opens search on the focused pane if not already active (`startSearch`, whose START callback
    /// pins it as `searchSurface`; bounded realize-poll if a never-shown session), then sets the needle if
    /// `text` is present (`sendSearchQuery`) and steps the selection if `to == next|prev` (`navigateSearch`)
    /// — both on the PINNED owner, so a split focus move after open can't retarget them.
    /// `to` must be one of next/prev/close (else an `invalid` error). The match count lands asynchronously
    /// via libghostty's SEARCH_TOTAL callback; `searchTotal`/`searchSelected` are cleared before the query so
    /// the bounded main-actor poll waits for the FRESH count (not a stale prior needle's), then `count` + the
    /// "N of M" display string are returned in `text`.
    private func searchSession(_ id: UUID, store: AppStore, text: String?, to: String?) async -> ControlResponse {
        // validate `to` up front so a bad mode errors before touching the surface.
        if let to, !["next", "prev", "close"].contains(to) {
            return ControlResponse(ok: false, error: "session.search --to must be next|prev|close")
        }
        guard let session = store.session(withID: id) else {
            return ControlResponse(ok: false, error: "no such session")
        }

        // close exits search without selecting: a background session's surface is already realized while
        // hidden, and end_search has no visible side effect, so don't disturb the user's active session.
        // drive the PINNED `searchSurface` (the pane that opened search), not a re-resolved `activeSurface`
        // — if split focus moved after open, `activeSurface` is the wrong pane and would strand the owner.
        // with no open search there's no owner, so close is a clean no-op.
        if to == "close" {
            (session.searchSurface as? GhosttySurfaceView)?.endSearch()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }

        // open/needle/navigate need the bar + highlights visible, so select the target (also realizes a
        // never-shown surface). the OPEN uses the search target — a covering scratch (scratchActive, no
        // overlay) wins, mirroring AppActions.searchTarget(), else the focused pane; the factory pins it as
        // `searchSurface`, and once open needle/navigate target the pinned owner so they can't drift.
        store.selectSession(id)
        // a covering scratch is searchable and sits above the pane, so drive it, not the hidden pane beneath.
        let coverIsScratch = session.scratchActive && !session.overlayActive
        var openSurface = (coverIsScratch ? session.topmostSurface : session.activeSurface) as? GhosttySurfaceView
        if openSurface == nil {
            // a never-shown session realizes a beat after select — bounded poll like `injectText`.
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 30_000_000)
                if let realized = (coverIsScratch ? session.topmostSurface : session.activeSurface) as? GhosttySurfaceView {
                    openSurface = realized
                    break
                }
            }
        }
        guard let openSurface else {
            return ControlResponse(ok: false, error: "session not realized")
        }

        // `searchActive` here means a prior open settled (set by the async START callback); two rapid
        // scripted opens could mis-toggle, but the GUI's single-⌘F path is the common case.
        if !session.searchActive { openSurface.startSearch() }
        // all post-open drives go to the pinned owner; before the first START callback lands it is nil, so
        // fall back to the just-opened focused pane (which the factory is about to pin to the same surface).
        let surface = (session.searchSurface as? GhosttySurfaceView) ?? openSurface
        let needleChanged = text != nil && text != session.searchNeedle
        if let text {
            // on a needle CHANGE, an OLDER query's SEARCH_TOTAL callback can still be queued on the main
            // loop (callbacks hop via DispatchQueue.main.async). drain one run-loop turn FIRST so any such
            // stale callback is delivered, THEN clear — so the settle-poll below waits for THIS needle's
            // callback (sent AFTER the clear) rather than reading a stale count. re-sending the SAME needle
            // must NOT drain/clear: libghostty does not re-emit SEARCH_TOTAL for an unchanged query, so
            // clearing would leave the count nil (the retry idiom re-sends the same needle while the
            // scrollback renders). residual race: a stale callback delivered more than one run-loop turn
            // late (blocked behind heavy render work) could still land after the clear; a per-query epoch
            // through libghostty would close it fully but is out of scope here.
            if needleChanged {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 30_000_000)
                session.searchTotal = nil
                session.searchSelected = nil
            }
            session.searchNeedle = text
            surface.sendSearchQuery(text)
            // an explicitly-empty needle clears the query: libghostty tears the search thread down and
            // emits no fresh SEARCH_TOTAL (its quit event resets the count), so reset the count/selected
            // here and skip the settle-poll below — there is nothing to wait for, and polling would just
            // burn the full timeout reading a count that never lands.
            if text.isEmpty {
                session.searchTotal = nil
                session.searchSelected = nil
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        }
        switch to {
        case "next": surface.navigateSearch(.next)
        case "prev": surface.navigateSearch(.previous)
        default: break
        }
        // let the SEARCH_TOTAL callback land before reporting (the overlay-result / realize poll idiom).
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if session.searchTotal != nil { break }
        }
        // an empty display string (the bar opened with no query yet) maps to a nil `text` so the CLI
        // prints `ok` rather than a blank line; the count is nil until a query runs.
        let display = session.searchDisplayText
        return ControlResponse(ok: true, result: ControlResult(text: display.isEmpty ? nil : display,
                                                               count: session.searchTotal))
    }

    /// Inject `text` into the session `id`'s surface. A session's surface is created lazily (deferred until
    /// it has a non-zero backing size — a never-shown session has `surface == nil`). `ghostty_surface_text`
    /// writes to the child pty, which the kernel buffers, so text is never lost even before the first prompt.
    /// - surface already realized → inject immediately, ok.
    /// - never realized, `select:true` → select it, then poll for the surface (bounded: 12 × 0.03 s, the
    ///   `focusSplitPane` idiom) and inject on the first realized attempt; never realized → error (never a
    ///   false ok).
    /// - never realized, no select → an immediate "use select" error.
    private func injectText(_ text: String, into id: UUID, store: AppStore, select: Bool) async -> ControlResponse {
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

    /// Project a window's workspace tree into the wire `ControlTree`, marking the active session and the
    /// active workspace (the one owning the selected session).
    private func buildTree(in store: AppStore) -> ControlTree {
        let activeID = store.selectedSessionID
        let activeWorkspaceID = activeID.flatMap { store.workspace(forSession: $0)?.id }
        let shellBasename = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        let workspaces = store.workspaces.map { workspace in
            let sessions = workspace.sessions.map { session in
                let fg = (session.surface as? GhosttySurfaceView).flatMap { ForegroundProcess.command(for: $0, shellBasename: shellBasename) }
                let splitFg = (session.splitSurface as? GhosttySurfaceView).flatMap { ForegroundProcess.command(for: $0, shellBasename: shellBasename) }
                let status = session.agentIndicator.status == .idle ? nil : session.agentIndicator.status.rawValue
                return ControlSessionNode(id: session.id.uuidString, name: session.displayName,
                                          cwd: session.effectiveCwd, title: session.oscTitle,
                                          active: session.id == activeID,
                                          split: session.isSplit, overlay: session.overlayActive,
                                          scratch: session.scratchActive, flagged: session.flagged,
                                          foreground: fg, splitForeground: splitFg, status: status)
            }
            return ControlWorkspaceNode(id: workspace.id.uuidString, name: workspace.name,
                                        active: workspace.id == activeWorkspaceID, sessions: sessions)
        }
        return ControlTree(workspaces: workspaces)
    }

    // MARK: - Window resolution & cross-window targeting

    /// A resolution outcome carrying either the resolved value or the structured error response to
    /// return. (`ControlResponse` isn't an `Error`, so this stands in for `Result` with the same case
    /// names.)
    private enum Resolution<T> {
        case success(T)
        case failure(ControlResponse)
    }

    /// The open store a placement/`active` command targets: with `window` set, the resolved open
    /// window's store (an error response when it isn't open / can't be resolved); without it, the
    /// frontmost window's store. Runs `body` with that store on success.
    private func resolvePlacementStore(_ window: String?, _ body: (AppStore) -> ControlResponse) -> ControlResponse {
        switch resolveWindowStore(window) {
        case .failure(let response): return response
        case .success(let store): return body(store)
        }
    }

    /// Creates a session in `workspaceID` of `store` with the `session.new` args (cwd default $HOME,
    /// optional command/name), focuses it when it lands in the frontmost window (so a keymap `session new`
    /// opens focused like the GUI New Session; a background `--window` target keeps focus), and returns the
    /// new id. Shared by the id- and name-addressed paths of the `.sessionNew` arm.
    private func makeSessionResponse(in store: AppStore, workspaceID: UUID, args: ControlArgs?) -> ControlResponse {
        let cwd = args?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let session = store.addSession(toWorkspace: workspaceID, cwd: cwd,
                                             command: args?.command, name: args?.name) else {
            return ControlResponse(ok: false, error: "could not create session")
        }
        if store === library.activeStore { actions.focusActiveSession() }
        return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
    }

    /// Resolve `window` to an OPEN window's store. nil → the frontmost store. A set value resolves the
    /// window id (active=frontmost / exact / prefix / ambiguous / not-found); the window must be open,
    /// else the closed-window error.
    private func resolveWindowStore(_ window: String?) -> Resolution<AppStore> {
        guard let window = trimmed(window) else { return .success(store) }
        let resolution = ControlResolve.resolve(window, candidates: library.windows.map(\.id), active: library.activeWindowID)
        guard case .resolved(let id) = resolution else {
            return .failure(resolutionError("window", target: window, resolution))
        }
        guard let store = library.store(for: id) else {
            return .failure(ControlResponse(ok: false, error: "window not open — window.select it first"))
        }
        return .success(store)
    }

    // MARK: - Session / workspace target resolution

    /// Resolve `target` (defaulting to `active`) to a session and its owning store, then run `body`.
    /// With `window` set, the search is scoped to that open window's store; without it, `active`
    /// resolves against the frontmost store while an id/prefix is matched across ALL open stores so a
    /// captured id resolves regardless of which window is frontmost.
    private func resolveSession(_ target: String?, window: String?,
                                _ body: (AppStore, UUID) -> ControlResponse) -> ControlResponse {
        switch resolveSessionTarget(target, window: window) {
        case .failure(let response): return response
        case .success(let (store, id)): return body(store, id)
        }
    }

    /// Resolve `target` (defaulting to `active`) to a workspace and its owning store, then run `body`.
    /// Same windowed/cross-window rules as `resolveSession`.
    private func resolveWorkspace(_ target: String?, window: String?,
                                  _ body: (AppStore, UUID) -> ControlResponse) -> ControlResponse {
        switch resolveWindowStore(window) {
        case .failure(let response):
            return response
        case .success(let scoped):
            // a window was named, or `active`/placement defaults to the frontmost store.
            if trimmed(window) != nil || (target ?? "active") == "active" {
                return resolve(target ?? "active", candidates: scoped.workspaces.map(\.id),
                               active: scoped.currentWorkspaceID, noun: "workspace") { id in
                    body(scoped, id)
                }
            }
            // no window arg + an id/prefix: match across all open stores, mapping back to the owner.
            return resolveAcrossWindows(target ?? "active", noun: "workspace",
                                        candidates: { $0.workspaces.map(\.id) }, body)
        }
    }

    /// The session target as a `(store, id)` result, used by both `resolveSession` and the async
    /// `session.type` path. See `resolveSession` for the windowed/cross-window rules.
    private func resolveSessionTarget(_ target: String?, window: String?) -> Resolution<(AppStore, UUID)> {
        switch resolveWindowStore(window) {
        case .failure(let response):
            return .failure(response)
        case .success(let scoped):
            if trimmed(window) != nil || (target ?? "active") == "active" {
                let target = target ?? "active"
                let resolution = ControlResolve.resolve(target, candidates: scoped.workspaces.flatMap { $0.sessions.map(\.id) },
                                                         active: scoped.selectedSessionID)
                guard case .resolved(let id) = resolution else {
                    return .failure(resolutionError("session", target: target, resolution))
                }
                return .success((scoped, id))
            }
            return resolveTargetAcrossWindows(target ?? "active", noun: "session",
                                              candidates: { $0.workspaces.flatMap { $0.sessions.map(\.id) } })
        }
    }

    /// Match an id/prefix `target` against the gathered candidates of EVERY open window's store,
    /// returning the resolved id and its owning store, or a structured error.
    private func resolveTargetAcrossWindows(_ target: String, noun: String,
                                            candidates: (AppStore) -> [UUID]) -> Resolution<(AppStore, UUID)> {
        let stores = library.openIDs().compactMap { library.store(for: $0) }
        let all = stores.flatMap(candidates)
        let resolution = ControlResolve.resolve(target, candidates: all, active: nil)
        guard case .resolved(let id) = resolution,
              let owner = stores.first(where: { candidates($0).contains(id) }) else {
            return .failure(resolutionError(noun, target: target, resolution))
        }
        return .success((owner, id))
    }

    /// `resolveTargetAcrossWindows` adapted to the `(store, id) -> ControlResponse` body shape.
    private func resolveAcrossWindows(_ target: String, noun: String, candidates: (AppStore) -> [UUID],
                                      _ body: (AppStore, UUID) -> ControlResponse) -> ControlResponse {
        switch resolveTargetAcrossWindows(target, noun: noun, candidates: candidates) {
        case .failure(let response): return response
        case .success(let (store, id)): return body(store, id)
        }
    }

    private func resolve(_ target: String, candidates: [UUID], active: UUID?, noun: String,
                         _ body: (UUID) -> ControlResponse) -> ControlResponse {
        let resolution = ControlResolve.resolve(target, candidates: candidates, active: active)
        if case .resolved(let id) = resolution { return body(id) }
        return resolutionError(noun, target: target, resolution)
    }

    /// The structured error response for a non-`.resolved` resolution (the single source of the wire
    /// "no such <noun>: …" / "ambiguous <noun> prefix '…' → <prefix8 list>" strings, which tests pin).
    /// `.resolved` maps to the not-found string too, covering the across-windows owner-lookup miss.
    private func resolutionError(_ noun: String, target: String, _ resolution: TargetResolution) -> ControlResponse {
        guard case .ambiguous(let hits) = resolution else {
            return ControlResponse(ok: false, error: "no such \(noun): \(target)")
        }
        let listed = hits.map { String($0.uuidString.prefix(8)) }.joined(separator: ", ")
        return ControlResponse(ok: false, error: "ambiguous \(noun) prefix '\(target)' → \(listed)")
    }

    // MARK: - Window commands

    /// Create a new window (library) and open its on-screen window via the action hub's window opener
    /// (the same `enqueueClaim` + `openWindow(id:)` path the menu uses). Returns the new window id.
    private func windowNew(name: String?) -> ControlResponse {
        let info = library.newWindow(name: trimmed(name))
        actions.openWindow?(info.id)
        return ControlResponse(ok: true, result: ControlResult(id: info.id.uuidString))
    }

    /// Project the window library into the `window.list` response: every window with its open flag and
    /// whether it is the frontmost (active) window.
    private func buildWindowList() -> [ControlWindowNode] {
        let active = library.activeWindowID
        return library.windows.map {
            ControlWindowNode(id: $0.id.uuidString, name: $0.name,
                              open: library.isOpen($0.id), active: $0.id == active)
        }
    }

    /// Resolve a window id and surface it: raise an already-open window, or open a closed one (the
    /// action hub's opener claims its id + spawns the window). A closed window's store loads only when
    /// its SwiftUI window appears, so this bounded-polls for it to open before replying — a script can
    /// then immediately target it (`tree --window <id>`) without racing the window appearing. Returns
    /// the window id.
    private func windowSelect(_ target: String?) async -> ControlResponse {
        switch resolveWindowID(target) {
        case .failure(let response): return response
        case .success(let id):
            actions.openWindow?(id)
            await pollUntil { self.library.isOpen(id) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve a window id and close its on-screen window (the registry's `performClose` runs the
    /// standard teardown + `closeWindow` path, which fires asynchronously). Bounded-polls for the
    /// library to mark it closed before replying, so an immediate follow-up command sees it closed. A
    /// no-op for an already-closed window still reports ok with the id. Returns the window id.
    private func windowClose(_ target: String?) async -> ControlResponse {
        switch resolveWindowID(target) {
        case .failure(let response): return response
        case .success(let id):
            // close the on-screen window if it's registered (drives the willClose teardown), then a
            // semantic fallback: if it isn't registered yet (window.close racing window.new before the
            // NSWindow attaches) or willClose hasn't flipped the flag, drop the store directly so the
            // window is reliably marked closed regardless of the attach timing.
            let hadWindow = WindowRegistry.shared.close(id)
            if hadWindow {
                await pollUntil { !self.library.isOpen(id) }
            }
            if library.isOpen(id) {
                library.closeWindow(id)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Bounded poll for an asynchronous window lifecycle transition (open after `window.select`, closed
    /// after `window.close`): the SwiftUI scene opens/closes the window off this dispatch, so the
    /// library flag flips a beat later. 30 × 0.05 s (≈1.5 s) of `Task.sleep` yields the main actor
    /// between checks — it never blocks the accept loop. Returns when `done()` holds or the budget is
    /// spent (the caller replies ok regardless: fire-and-forget, the poll only narrows the race).
    private func pollUntil(_ done: () -> Bool) async {
        for _ in 0..<30 {
            if done() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Resolve a window id and resize its on-screen window to `width` x `height` points (frame size).
    /// The window must be open; a closed window errors (resize it after `window.select`). Control-native
    /// (no GUI surface — the native title bar already drags-to-resize).
    private func windowResize(_ target: String?, width: Int?, height: Int?) -> ControlResponse {
        guard let width, let height, width > 0, height > 0 else {
            return ControlResponse(ok: false, error: "window.resize requires positive width and height")
        }
        return resolveWindowID(target) { id in
            guard WindowRegistry.shared.resize(id, width: width, height: height) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve a window id and move its on-screen window so its top-left corner is at (`x`, `y`) points in
    /// the global top-left space (origin = the primary display's top-left, spanning all displays). The
    /// window must be open; a closed window errors. Control-native (no GUI surface).
    private func windowMove(_ target: String?, x: Int?, y: Int?, display: Int?) -> ControlResponse {
        guard let x, let y else {
            return ControlResponse(ok: false, error: "window.move requires x and y")
        }
        if let display, display < 0 || display >= NSScreen.screens.count {
            return ControlResponse(ok: false, error: "display \(display) out of range (have \(NSScreen.screens.count))")
        }
        return resolveWindowID(target) { id in
            guard WindowRegistry.shared.move(id, x: x, y: y, display: display) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    // MARK: - Keymap

    /// Re-read and re-parse `keymap.conf`, returning the count of parse diagnostics. The SAME
    /// `reloadKeymap()` path the GUI's File ▸ Reload Keymap menu/palette item drives, so the menu/palette
    /// and `keymap.reload` never diverge — control-native here only in the count it reports back.
    private func reloadKeymap() -> ControlResponse {
        settingsModel.reloadKeymap()
        return ControlResponse(ok: true, result: ControlResult(count: settingsModel.keymapDiagnostics.count))
    }

    // MARK: - Config

    /// Re-read and apply the ghostty config, returning the config-diagnostic count (0 = clean), counted
    /// across ALL config sources (bundled defaults, the global `~/.config/ghostty/config`, the agterm-scoped
    /// `ghostty.conf`, and the UI settings conf) — libghostty diagnostics carry no source-file attribution.
    /// The SAME `AppActions.reloadGhosttyConfig()` path the GUI's File ▸ Reload Config menu/palette item
    /// drives (which posts the warning banner on diagnostics), so the GUI and `config.reload` never diverge
    /// — control-native here only in the count it reports back. The count is the value the reload actually
    /// produced (threaded back from the reload), not a separate re-read. App-global (one settings model +
    /// one GhosttyApp), so no `--window` selector, like `keymap.reload`.
    private func reloadGhosttyConfig() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(count: actions.reloadGhosttyConfig()))
    }

    // MARK: - Theme

    /// Set + persist a theme by name — the control half of the Settings picker / the `.themes` palette
    /// commit (no live preview over the socket). A nil/empty name selects ghostty's built-in colors
    /// ("default ghostty"), NOT the seeded `agterm` app default; any other name must be a bundled theme,
    /// else an error (a typo silently doing nothing is worse than a fail). Returns the applied theme in
    /// `result.theme` (nil = ghostty built-in). App-global: one `SettingsModel`, so no `--window` selector.
    private func setTheme(name: String?) -> ControlResponse {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let resolved = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if let resolved, !actions.availableThemes().contains(resolved) {
            return ControlResponse(ok: false, error: "unknown theme: \(resolved)")
        }
        actions.setTheme(resolved)
        return ControlResponse(ok: true, result: ControlResult(theme: resolved))
    }

    // MARK: - Window commands (cont.)

    /// Resolve a window id and rename it (the name lives in the index). Requires a name. Returns the id.
    private func windowRename(_ target: String?, name: String?) -> ControlResponse {
        guard let name = trimmed(name) else {
            return ControlResponse(ok: false, error: "window.rename requires a name")
        }
        return resolveWindowID(target) { id in
            library.renameWindow(id, to: name)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve a window id and delete it, honoring keep-at-least-one (an error instead of the GUI
    /// confirm). Closes its on-screen window first if open. Returns the id.
    private func windowDelete(_ target: String?) -> ControlResponse {
        return resolveWindowID(target) { id in
            guard library.canRemoveWindow else {
                return ControlResponse(ok: false, error: "cannot delete last window")
            }
            WindowRegistry.shared.close(id)
            library.removeWindow(id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve a window `target` (defaulting to `active` = frontmost) to a window id, or the structured
    /// error. Unlike the session/workspace resolvers, a window need not be open to be a target (select
    /// opens it, delete removes a closed one).
    private func resolveWindowID(_ target: String?) -> Resolution<UUID> {
        let resolution = ControlResolve.resolve(target ?? "active", candidates: library.windows.map(\.id),
                                                active: library.activeWindowID)
        guard case .resolved(let id) = resolution else {
            return .failure(resolutionError("window", target: target ?? "active", resolution))
        }
        return .success(id)
    }

    /// `resolveWindowID` adapted to the callback body shape (rename/delete, which act synchronously).
    private func resolveWindowID(_ target: String?, _ body: (UUID) -> ControlResponse) -> ControlResponse {
        switch resolveWindowID(target) {
        case .failure(let response): return response
        case .success(let id): return body(id)
        }
    }

    /// `value` trimmed of surrounding whitespace, or nil if absent or blank after trimming.
    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func log(_ message: @autoclosure () -> String) {
        NSLog("agterm: %@", message())
    }
}
