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
    let library: WindowLibrary
    let actions: AppActions
    let settingsModel: SettingsModel
    private let socketPath: String

    /// The target-resolution query layer: owns the `emptyStore`/`store` frontmost-fallback and wraps the
    /// pure `ControlResolve` matcher with app-side store scoping and the pinned wire-error strings.
    let resolver: ControlTargetResolver

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

    /// Seconds a blocking response `write()` may stall before it times out, so a client that stops reading
    /// can't park the serial accept loop — `session.text --all` responses can be multi-MB and won't fit
    /// the socket buffer in one write, so an unresponsive reader would otherwise block indefinitely.
    nonisolated private static let writeTimeoutSeconds = 5

    /// Overall seconds a single connection's request read may take before it's abandoned. `readTimeoutSeconds`
    /// only bounds each `read()`, so a slow-loris client trickling one byte per interval (each under the
    /// per-read timeout) never sends a newline yet keeps the serial accept loop busy indefinitely. This caps
    /// the total read time; a legit one-line request arrives in milliseconds, far under the cap.
    nonisolated private static let readDeadlineSeconds = 10

    /// Overall seconds a single response write may take before it's abandoned. `SO_SNDTIMEO` only bounds
    /// each `write()`, so a slow-drip reader draining a multi-MB `session.text --all` a few bytes per
    /// interval keeps every write making progress and never trips the per-write timeout, parking the serial
    /// accept loop. This caps the total write time, symmetric with `readDeadlineSeconds`; a normal reader
    /// drains a response in milliseconds, far under the cap.
    nonisolated private static let writeDeadlineSeconds = 10

    init(library: WindowLibrary, actions: AppActions, settingsModel: SettingsModel, socketPath: String? = nil) {
        self.library = library
        self.actions = actions
        self.settingsModel = settingsModel
        self.resolver = ControlTargetResolver(library: library)
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

        // bound the blocking response write too — a large `session.text --all` reply may not fit the socket
        // buffer in one write, so a client that stopped reading would otherwise wedge the accept loop.
        var writeTimeout = timeval(tv_sec: writeTimeoutSeconds, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))

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
            // overall deadline: SO_SNDTIMEO bounds each write(), but a slow-drip reader making a few bytes
            // of progress per interval never trips it, so cap the total write time like readLine's deadline.
            let deadline = DispatchTime.now() + .seconds(writeDeadlineSeconds)
            while offset < data.count {
                if DispatchTime.now() > deadline { return }
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
            return resolver.resolvePlacementStore(request.args?.window) { store in
                ControlResponse(ok: true, result: ControlResult(tree: buildTree(in: store)))
            }
        case .sessionSelect:
            return resolver.resolveSession(request.target, window: request.args?.window) { store, id in
                store.selectSession(id)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionGo:
            // relative navigation acts on the store's current selection, so no session target — just
            // the frontmost-or-`--window` store. unknown/missing `to` is a structured error.
            guard let dir = (request.args?.to).flatMap(SessionNavigation.init(wire:)) else {
                return ControlResponse(ok: false, error: "session.go requires --to next|prev|first|last|next-attention|prev-attention")
            }
            return resolver.resolvePlacementStore(request.args?.window) { store in
                store.navigateSession(dir)
                guard let id = store.selectedSessionID else {
                    return ControlResponse(ok: false, error: "no session to navigate")
                }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .workspaceSelect:
            // selecting a workspace selects its first session (workspace rows are not selectable on
            // their own); an empty workspace just clears nothing and reports the workspace id.
            return resolver.resolveWorkspace(request.target, window: request.args?.window) { store, id in
                if let first = store.workspaces.first(where: { $0.id == id })?.sessions.first {
                    store.selectSession(first.id)
                }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .workspaceNew:
            // placement target: the window's frontmost store (or `args.window`'s). name defaults to
            // the auto-generated workspace name when none is given.
            return resolver.resolvePlacementStore(request.args?.window) { store in
                let name = trimmed(request.args?.name) ?? store.defaultWorkspaceName
                let workspace = store.addWorkspace(name: name)
                return ControlResponse(ok: true, result: ControlResult(id: workspace.id.uuidString))
            }
        case .workspaceRename:
            guard let name = trimmed(request.args?.name) else {
                return ControlResponse(ok: false, error: "workspace.rename requires a name")
            }
            return resolver.resolveWorkspace(request.target, window: request.args?.window) { store, id in
                store.renameWorkspace(id, to: name)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .workspaceDelete:
            // honors keep-at-least-one; returns an error rather than the GUI confirm alert.
            return resolver.resolveWorkspace(request.target, window: request.args?.window) { store, id in
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
            return resolver.resolvePlacementStore(args?.window) { store in
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
                return resolver.resolve(target, candidates: store.workspaces.map(\.id),
                               active: store.currentWorkspaceID, noun: "workspace") { workspaceID in
                    makeSessionResponse(in: store, workspaceID: workspaceID, args: args)
                }
            }
        case .sessionClose:
            return resolver.resolveSession(request.target, window: request.args?.window) { store, id in
                store.closeSession(id)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionRename:
            guard let name = request.args?.name else {
                return ControlResponse(ok: false, error: "session.rename requires a name")
            }
            return resolver.resolveSession(request.target, window: request.args?.window) { store, id in
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
            switch resolver.resolveSessionTarget(request.target, window: request.args?.window) {
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
        case .sessionResize:
            return resizeSplit(request.target, window: request.args?.window,
                               ratio: request.args?.ratio, delta: request.args?.ratioDelta)
        case .sessionStatus:
            return setSessionStatus(request.target, window: request.args?.window,
                                    update: StatusUpdate(status: request.args?.status, blink: request.args?.blink,
                                                         autoReset: request.args?.autoReset, sound: request.args?.sound))
        case .sessionFlag:
            return flagSession(request.target, window: request.args?.window, mode: request.args?.mode)
        case .sessionBackground:
            return setBackground(request.target, request.args)
        case .sessionCopy:
            return copySelection(request.target, window: request.args?.window)
        case .sessionText:
            return readText(request.target, window: request.args?.window, pane: request.args?.pane,
                            all: request.args?.all ?? false, lines: request.args?.lines)
        case .sessionSearch:
            // resolve first (cross-window when no `args.window`), then select + realize the surface; the
            // realize path is async (bounded poll), so this can't go through the synchronous
            // `resolveSession` helper. error strings stay in sync with `resolve(...)`.
            switch resolver.resolveSessionTarget(request.target, window: request.args?.window) {
            case .failure(let response):
                return response
            case .success(let (store, id)):
                return await searchSession(id, store: store, text: request.args?.text, to: request.args?.to)
            }
        case .sessionOverlayOpen:
            guard let command = request.args?.command, !command.isEmpty else {
                return ControlResponse(ok: false, error: "session.overlay.open requires a command")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            return resolver.resolveSession(request.target, window: request.args?.window) { store, id in
                guard store.openOverlay(id, command: command, cwd: request.args?.cwd,
                                        wait: request.args?.wait ?? false,
                                        sizePercent: request.args?.sizePercent,
                                        backgroundColor: request.args?.color) else {
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
            return resolver.resolveSession(request.target, window: request.args?.window) { store, id in
                guard store.closeOverlay(id) else {
                    return ControlResponse(ok: false, error: "no overlay")
                }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        case .sessionOverlayResult:
            return resolver.resolveSession(request.target, window: request.args?.window) { store, id in
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
        case .windowZoom:
            return windowZoom(request.target)
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

    /// Project a window's workspace tree into the wire `ControlTree`, marking the active session and the
    /// active workspace (the one owning the selected session).
    private func buildTree(in store: AppStore) -> ControlTree {
        let shellBasename = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        return store.controlTree(
            foreground: { session in
                (session.surface as? GhosttySurfaceView).flatMap {
                    ForegroundProcess.command(for: $0, shellBasename: shellBasename)
                }
            },
            splitForeground: { session in
                (session.splitSurface as? GhosttySurfaceView).flatMap {
                    ForegroundProcess.command(for: $0, shellBasename: shellBasename)
                }
            }
        )
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
        let resolved = ThemeCatalog.resolvedName(name)
        let catalog = ThemeCatalog(names: actions.availableThemes())
        if let resolved, !catalog.contains(name: resolved) {
            return ControlResponse(ok: false, error: "unknown theme: \(resolved)")
        }
        actions.setTheme(resolved)
        return ControlResponse(ok: true, result: ControlResult(theme: resolved))
    }

    /// `value` trimmed of surrounding whitespace, or nil if absent or blank after trimming.
    func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func log(_ message: @autoclosure () -> String) {
        NSLog("agterm: %@", message())
    }
}
