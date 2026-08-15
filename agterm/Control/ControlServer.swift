import AppKit
import agtermCore
import Darwin
import Foundation

/// The programmatic control channel: a POSIX unix-domain-socket listener turning newline-delimited JSON
/// `ControlRequest`s into calls on the `AppActions`/`AppStore` seam the toolbar, menu bar and palettes
/// share. One request per connection: read a line, dispatch, write one `ControlResponse`, close.
///
/// `@MainActor` because the store is: only the blocking accept/read loop runs on a background queue, each
/// decoded request hopping back to execute. Best-effort — a bind failure logs and the app still launches.
@MainActor
final class ControlServer {
    /// The window library; commands dispatch onto a per-request target window's store. `tree` and
    /// placement/`active` commands take `args.window` else the frontmost (a named window must be open); an
    /// id/prefix session/workspace target without `args.window` resolves across ALL open windows, so a
    /// captured id works regardless of which is frontmost. `window.*` drives the library itself.
    let library: WindowLibrary
    let actions: AppActions
    let settingsModel: SettingsModel
    private let socketPath: String

    /// The target-resolution query layer: owns the `emptyStore`/`store` frontmost-fallback and wraps the
    /// pure `ControlResolve` matcher with app-side store scoping and the pinned wire-error strings.
    let resolver: ControlTargetResolver

    /// The listening socket fd, or -1 when not listening. `start()` is idempotent on this.
    private var listenFD: Int32 = -1

    /// The held ownership lock fd, or -1 when this process does not own `socketPath`.
    private var lockFD: Int32 = -1

    /// Set when `start()` found another live instance owning the path, so this one will never serve it.
    private var refused = false

    /// The bound socket path, nil when not listening (bind failed or never started).
    var boundSocketPath: String? { listenFD >= 0 ? socketPath : nil }

    /// Suffix marking the stand-in path a refused instance advertises. Nothing ever creates it, so every
    /// connection to it fails.
    static let unavailableSuffix = ".unavailable"

    /// The path spawned surfaces point `AGTERM_SOCKET` at. Once this instance has REFUSED the real path
    /// because another one owns it, this becomes an unbindable sibling: a shell here must not reach the
    /// other app, which for a second instance sharing state is the user's live terminal (persisted session
    /// ids resolve there too). Leaving the variable UNSET is worse than a dead value — the shipped status
    /// hooks drop `--socket` when it is absent, and `agtermctl` then resolves the very default the other
    /// instance is serving. Not `boundSocketPath`: the launch window's surfaces can materialize BEFORE
    /// `start()` binds, and a nil there would leak `AGTERM_SOCKET` permanently. Equals it once bound.
    var resolvedSocketPath: String { refused ? socketPath + ControlServer.unavailableSuffix : socketPath }
    private let acceptQueue = DispatchQueue(label: "com.umputun.agterm.control.accept")

    /// Thread-safe window-list cache: refreshed on the main actor after every dispatched command, read under
    /// the lock from the background accept loop, so a post-window-close main-thread stall can't wedge the
    /// serial server against `window.list` / `tree --window` polls.
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

    /// A cache-only response for read-only window queries, nil to fall through to the main actor: on a cold
    /// cache (which the main-actor path populates) and for `tree --window` on an OPEN window (building the
    /// tree needs the main actor). Only the closed-window error and `window.list` land here.
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

    /// Cap on a request line, shared with the client via `ControlWire` so the two sides can't drift; over
    /// it the line is rejected and the connection closed, so a bad client can't grow the buffer unbounded.
    nonisolated private static let maxLineBytes = ControlWire.maxRequestLineBytes

    /// Seconds a blocking client read may stall before timing out (EAGAIN → connection closed), so a stalled
    /// client can't park the serial accept loop forever.
    nonisolated private static let readTimeoutSeconds = 5

    /// Seconds a blocking response `write()` may stall before timing out: a multi-MB `session.text --all`
    /// response won't fit the socket buffer in one write, so a client that stops reading would park the loop.
    nonisolated private static let writeTimeoutSeconds = 5

    /// Overall cap on a connection's request read: `readTimeoutSeconds` bounds each `read()` only, so a
    /// slow-loris trickling a byte per interval, never a newline, never trips it and holds the loop forever.
    nonisolated private static let readDeadlineSeconds = 10

    /// Overall cap on a response write, symmetric with `readDeadlineSeconds`: `SO_SNDTIMEO` bounds each
    /// `write()` only, so a slow-drip reader draining a multi-MB `session.text --all` keeps every write
    /// progressing and parks the accept loop. A normal reader drains in milliseconds.
    nonisolated private static let writeDeadlineSeconds = 10

    init(library: WindowLibrary, actions: AppActions, settingsModel: SettingsModel, socketPath: String? = nil) {
        self.library = library
        self.actions = actions
        self.settingsModel = settingsModel
        self.resolver = ControlTargetResolver(library: library)
        self.socketPath = socketPath ?? ControlServer.defaultSocketPath()
        // ownership is decided HERE, not in `start()`. The launch window's surfaces are built during the
        // initial render pass and SNAPSHOT `AGTERM_SOCKET` into the pty environment (`GhosttySurfaceView.env`
        // is a `let` read at spawn), while `start()` runs from the scene's `.task` afterwards. Deciding late
        // would hand that first shell the owner's live socket, which is the one thing this guard exists to
        // prevent. Binding stays in `start()`; this only answers who owns the path.
        _ = acquireOwnership()
        // keep the `active` flag fresh across async frontmost changes; the server lives for the app's
        // lifetime, so the observer needs no removal.
        NotificationCenter.default.addObserver(forName: .agtermWindowFrontmostChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowCache() }
        }
        // a GUI-only sidebar toggle runs no control command, so window.list's cached copy would lag. queue
        // nil (NOT .main) delivers synchronously on the posting @MainActor thread, so the refresh lands
        // before the toggle returns; an async .main hop leaves a window for a stale fast-path read.
        NotificationCenter.default.addObserver(forName: .agtermSidebarVisibilityChanged, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowCache() }
        }
        // window.list carries LIVE NSWindow geometry + fullscreen/zoom read at cache-build time, which a user
        // drag/resize/zoom/fullscreen changes with NO control command — and a polling window.list is
        // fast-path-served, so it never refreshes its own cache. the fullscreen notifications fire AFTER the
        // async transition, so the settled `styleMask` is captured. the non-Sendable `Notification` is
        // ignored, not captured (it can't cross into `assumeIsolated` under Swift 6), so this fires for ANY
        // window — harmless, a foreign panel just rebuilds the same cheap agterm nodes.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindowCache() }
            }
        }
        // an NSWindow attaches a render pass or two AFTER its store loads, so the node cached right after
        // window.new carries no geometry/flags. attach/detach also covers GUI New Window and launch
        // reopen-all, which run no control command at all.
        NotificationCenter.default.addObserver(forName: .agtermWindowAttachmentChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowCache() }
        }
    }

    /// The socket path the app and the CLI rendezvous on. `AGTERM_CONTROL_SOCKET` wins (tests need it —
    /// their sandboxed `AGTERM_STATE_DIR` container path exceeds `sun_path`'s ~104 bytes), then
    /// `<AGTERM_STATE_DIR>/agterm.sock` (state isolation), then `<app support>/agterm.sock`.
    static func defaultSocketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["AGTERM_CONTROL_SOCKET"] { return explicit }
        return ControlResolve.socketPath(stateDir: env["AGTERM_STATE_DIR"], appSupport: PersistenceStore.defaultDirectory.path)
    }

    // MARK: - Lifecycle

    /// Bind and start listening. Idempotent — the scene `.task` re-runs when a window is recreated and a
    /// second `bind` must not be attempted. Any failure logs and returns, leaving the app to launch.
    func start() {
        guard listenFD < 0 else { return }

        guard socketPath.utf8.count < 104 else {
            log("control socket path too long (\(socketPath.utf8.count) bytes): \(socketPath)")
            return
        }

        // normally taken at init; retry here for the instance refused while the owner was still alive, which
        // reaches this again on a later window. `lockFD >= 0` first because flock is per open file
        // description: a second `open` of a file THIS process already locked conflicts with itself.
        guard lockFD >= 0 || acquireOwnership() else { return }

        // every failure below KEEPS the lock. Releasing it would let another instance bind the path while
        // this one still advertises it, which is the leak the lock exists to close, and it buys nothing:
        // the next window's `start()` retries the bind through the `lockFD >= 0` arm above.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("control socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        // unlink the stale socket file. Holding the lock is what makes this safe: nobody else is serving
        // the path, so whatever is on disk is a force-quit leftover.
        unlink(socketPath)

        var addr = ControlServer.unixAddress(for: socketPath)

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

    func stop() {
        // outside the guard: the lock is taken in `init`, so an instance that never bound (path too long,
        // or a bind that failed) still holds one and would otherwise keep it for the whole process.
        defer { releaseOwnership() }
        guard listenFD >= 0 else { return }
        close(listenFD)
        listenFD = -1
        unlink(socketPath)
    }

    /// Take the exclusive advisory lock that marks this process the owner of `socketPath`, held from init
    /// until `stop()`, and set `refused` when another live instance holds it.
    ///
    /// `connect` cannot answer the ownership question on Darwin. A live listener whose backlog is full
    /// refuses with the same `ECONNREFUSED` a socket nobody listens on returns (measured: the app's
    /// backlog is 8 and one stalled client parks the serial accept loop for up to `readDeadlineSeconds`,
    /// so saturation is reachable), and a blocking `connect` against it returns immediately rather than
    /// stalling. `flock` carries no such ambiguity, is atomic against a second instance launching in the
    /// same moment, and the kernel releases it when a force-quit kills the holder — which is the case the
    /// `unlink` in `start()` exists for.
    private func acquireOwnership() -> Bool {
        let lockPath = socketPath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            log("control lock open(\(lockPath)) failed: \(String(cString: strerror(errno)))")
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            refused = true
            log("control socket \(socketPath) is already served by another instance — not binding")
            return false
        }
        lockFD = fd
        // clear it: `start()` re-runs from every window scene's task, so an instance refused while the
        // owner was alive reaches this line once the owner quits, and a stale `refused` would leave it
        // advertising the unavailable path forever on a socket it now serves.
        refused = false
        return true
    }

    /// Drop the ownership lock. The lock FILE is deliberately left behind: unlinking it would let the next
    /// instance create a fresh inode and lock that instead, which excludes nobody.
    private func releaseOwnership() {
        guard lockFD >= 0 else { return }
        close(lockFD)
        lockFD = -1
    }

    /// Fill a `sockaddr_un` with `path`. Callers guard the ~104-byte `sun_path` limit first; a longer path
    /// would overrun the tuple.
    nonisolated private static func unixAddress(for path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                pathBytes.withUnsafeBufferPointer { src in
                    buf.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        return addr
    }

    // MARK: - Accept / read loop

    /// Run the blocking accept loop on the background queue, each connection handled inline (one request →
    /// one response → close): connections are rare and short, so a per-connection thread is unnecessary.
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

    /// Read one newline-delimited request from `conn`, decode it, dispatch it on `server` (main actor), write
    /// the response back, close. A decode failure replies with a structured error. Runs on the background queue.
    nonisolated private static func handleConnection(_ conn: Int32, server: ControlServer) {
        defer { close(conn) }
        // a write to a client that already hung up would raise the default-fatal SIGPIPE and take the whole
        // app down mid-request; SO_NOSIGPIPE turns it into a normal EPIPE write error.
        var noSigPipe: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var readTimeout = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))

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

        // answer read-only window queries from the cache without a main-actor hop: a window close briefly
        // stalls the main thread (surface teardown / re-render), wedging the accept loop against polls.
        if let cached = server.fastPathResponse(for: request) {
            writeResponse(conn, cached)
            return
        }

        // hop to the main actor, blocking this background thread. dispatch refreshes the window cache in that
        // same execution, so the fast path sees this command's mutations without a second, stallable hop.
        let response = runBlocking { await server.dispatch(request) }
        writeResponse(conn, response)
    }

    /// Read bytes from `conn` up to (and excluding) the first newline. Returns nil on EOF-before-newline, a
    /// read error, the `maxLineBytes` cap, or the `readDeadlineSeconds` overall cap.
    nonisolated private static func readLine(_ conn: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
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

    /// Run an async closure on a fresh task, blocking the calling background thread until it finishes —
    /// bridges the synchronous read loop to the main-actor dispatch without hopping the loop thread itself.
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
        // refresh the read cache in this same main-actor execution, so the background fast path sees the new
        // state without a separate, stallable hop.
        defer { refreshWindowCache() }
        if let response = await ControlDispatcher(actions: self).dispatch(request) {
            return response
        }
        switch request.cmd {
        case .tree, .eventsRead, .sessionNew, .sessionDuplicate, .sessionSelect, .sessionGo, .sessionClose, .sessionRename,
                .sessionReveal, .sessionMove,
                .workspaceNew, .workspaceSelect, .workspaceGo, .workspaceRename, .workspaceDelete, .workspaceMove,
                .workspaceFocus,
                .workspaceFilter, .workspaceCollapse, .workspaceExpand,
                .sessionSplit, .sessionSplitClose, .sessionScratch, .sessionFocus, .sessionResize, .surfaceZoom,
                .sessionStatus, .sessionFlag, .sessionSeen, .sessionRestore, .notify,
                .fontInc, .fontDec, .fontReset, .keymapReload, .keymapList, .configReload, .themeSet, .themeList,
                .sidebar, .sidebarMode, .sidebarExpand, .sidebarCollapse, .sessionType, .sessionCopy,
                .sessionPaste, .sessionSelectAll,
                .sessionSearch, .sessionOverlayOpen, .sessionOverlayClose, .sessionOverlayResize,
                .sessionOverlayResult, .sessionOverlayCopy, .sessionOverlayText,
                .sessionBackground, .sessionText, .quick, .quickType, .quickText,
                .windowNew, .windowList, .windowSelect,
                .windowClose, .windowRename, .windowDelete, .windowResize, .windowMove, .windowZoom,
                .windowFullscreen, .windowMinimize,
                .restoreClear, .dashboard:
            return ControlResponse(ok: false, error: "control dispatcher did not handle \(request.cmd.rawValue)")
        case .debugAppearance:
            return setDebugAppearance(args: request.args)
        case .pickOpen, .pickResult, .pickCancel:
            preconditionFailure("pick command returned nil from ControlDispatcher")
        case .sessionHudOpen, .sessionHudUpdate, .sessionHudClose:
            preconditionFailure("hud command returned nil from ControlDispatcher")
        }
    }

    /// UI-TEST-ONLY seam: forces the app-level appearance so an XCUITest can simulate a macOS light/dark flip
    /// deterministically (XCUITest has no API for it). `NSApp.appearance` moves `effectiveAppearance`, and
    /// this arm ALSO posts `.agtermSystemAppearanceChanged` so the REAL flip path (scheme sync → debounced
    /// zoom-preserving reload) runs end to end without waiting on KVO, which production relies on for a
    /// genuine system flip. Refused outside an XCUITest launch, and EXEMPT from the four-point keep-in-sync
    /// as test scaffolding — no `agtermctl` subcommand, absent from the catalog/skill. A set echoes the
    /// effective side in `result.text`; the BARE form reads `SettingsModel.lastAppliedIsDark`, which a test
    /// polls to prove the flip drove the reload — a suppressed flip leaves it on the old side.
    private func setDebugAppearance(args: ControlArgs?) -> ControlResponse {
        guard ContentView.isUITestLaunch else {
            return ControlResponse(ok: false, error: "debug.appearance is a UI-test-only seam")
        }
        guard args?.name != nil else {
            return ControlResponse(ok: true, result: ControlResult(
                text: settingsModel.lastAppliedIsDark ? "dark" : "light"))
        }
        guard let side = trimmed(args?.name), side == "light" || side == "dark" else {
            return ControlResponse(ok: false, error: "debug.appearance requires light|dark")
        }
        // take the validated `side`, never re-read `currentIsDark()` — `effectiveAppearance` may not have
        // settled right after the set (the production `SystemAppearanceObserver`'s never-re-read rule).
        let isDark = side == "dark"
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        // drive the flip pipeline directly (a duplicate KVO post, if any, is same-side-suppressed).
        NotificationCenter.default.post(name: .agtermSystemAppearanceChanged, object: nil,
                                        userInfo: ["isDark": isDark])
        return ControlResponse(ok: true, result: ControlResult(text: isDark ? "dark" : "light"))
    }

    /// Clear every open session's captured foreground command and persist, so the next launch restores plain
    /// shells. The live fields are usually already nil (consumed at restore); the SAVE is what wipes the
    /// on-disk copy from the last quit, closing the force-quit re-fire window. App-global like
    /// `keymap.reload`: no `--window` selector, every open window is cleared.
    ///
    /// Also disarms the PENDING capture slots, where a launch restore parks the argv until each surface
    /// mounts: the socket binds before the later windows' decks do, so a clear arriving in that gap would
    /// answer ok and then watch those windows run the commands anyway. The `session.restore` pins are
    /// deliberately untouched — they are sticky, and this command clears captures.
    func clearRestoreCommands() -> ControlResponse {
        for session in library.allOpenSessions() {
            session.foregroundCommand = nil
            session.splitForegroundCommand = nil
            session.clearPendingForegroundCommands()
        }
        library.saveAllOpen()
        return ControlResponse(ok: true)
    }

    /// Open or close the target window's dashboard overlay — the app side of the host-free `dashboard`
    /// command (the dispatcher validated the args and built `fontMode`, but does not cap the ids). Resolves
    /// `window ?? frontmost` to an OPEN window's store. `mru` takes up to `DashboardLayout.maxCells` of that
    /// store's most-recently-used sessions (fewer if it has fewer, nothing unresolved); otherwise each id
    /// parses as a `DashboardTarget` and its head resolves within THAT store, misses reported in
    /// `result.text`. A bare id EXPANDS in order into pane cells — always `.primary`, plus `.split` when it
    /// `hasSplit` (both shells alive), so a split shows as TWO cells — while a `:left`/`:right` suffix (#331)
    /// takes that cell alone; a `:right` naming no live pane is a miss, not an error. Cells dedup by
    /// session+pane, NOT by session, so `A:left A:right` is two cells and `A A:left` is still two. The
    /// `maxCells` (9) cap counts PANES, applied here after expansion, its drops reported alongside
    /// `unresolved` (joined with "; "). Emptiness is judged on the expanded CELLS, since a resolved id can
    /// now contribute none.
    /// Each cell reparents its OWN pane surface (`\.surface` / `\.splitSurface`) app-side in
    /// `WindowContentView`. Opening closes the window's terminal zoom (mutually exclusive); `--close` calls
    /// `close()`. The registry returns nil until `WindowContentView` registers the controller (or while the
    /// window tears down), reported as the window not being open.
    func setDashboard(targets: [String], window: String?, close: Bool,
                      fontMode: DashboardFontMode, mru: Bool) -> ControlResponse {
        resolver.resolvePlacementStore(window) { store in
            guard let windowID = library.windowID(for: store),
                  let controller = DashboardControllerRegistry.shared.controller(for: windowID) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            if close {
                controller.close()
                return ControlResponse(ok: true)
            }
            if PickRegistry.shared.controller(for: windowID)?.pending != nil {
                return ControlResponse(ok: false, error: "pick pending")
            }
            var resolvedTargets: [ResolvedDashboardTarget] = []
            var unresolved: [String] = []
            if mru {
                let recent = store.recentSessions(limit: DashboardLayout.maxCells)
                guard !recent.isEmpty else {
                    return ControlResponse(ok: false, error: "no recent sessions")
                }
                resolvedTargets = recent.map { ResolvedDashboardTarget(session: $0, pane: nil) }
            } else {
                let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
                for target in targets {
                    guard let parsed = DashboardTarget(rawValue: target),
                          case .resolved(let id) = ControlResolve.resolve(parsed.head, candidates: candidates,
                                                                          active: store.selectedSessionID),
                          let session = store.session(withID: id) else {
                        unresolved.append(target)
                        continue
                    }
                    // a `:right` ref to a session with no split is a MISS, not a malformed command: the
                    // dispatcher already passed the grammar. `hasSplit` is the same test
                    // `dashboardValidMembers` reconciles against, so this never admits a cell reconcile
                    // would immediately prune.
                    guard parsed.pane != .split || session.hasSplit else {
                        unresolved.append(target)
                        continue
                    }
                    resolvedTargets.append(ResolvedDashboardTarget(session: id, pane: parsed.pane))
                }
            }
            // the shared host-free helper: ONE expansion+cap implementation with AppActions.toggleDashboard.
            // it also dedups, so a bare id beside a pane ref for the same session cannot double-host a surface.
            let (members, droppedPanes) = store.dashboardMembers(for: resolvedTargets,
                                                                 limit: DashboardLayout.maxCells)
            // guard the EXPANSION, not the resolved targets: with pane refs they are no longer equivalent.
            // `dashboard <id>:right` on a session with no split resolves the id but expands to nothing, and
            // opening with an empty member set would clear the window's zoom and silently close a live
            // dashboard while reporting ok (`DashboardController.isOpen` is `!members.isEmpty`).
            guard !members.isEmpty else {
                return ControlResponse(ok: false, error: "no dashboard sessions resolved")
            }
            TerminalZoomRegistry.shared.controller(for: windowID)?.clear()
            controller.open(members: members, fontMode: fontMode)
            // set the applied size SYNCHRONOUSLY so the `dashboardFontSize` read-back is authoritative at
            // command return: the SwiftUI onChange applying the surface overrides runs a runloop turn later,
            // and open() never resets appliedFontSize, so an untouched re-open would leak the prior
            // fixed/auto size. idempotent with the wiring — both go through DashboardFontMode.appliedFontSize.
            let base = settingsModel.settings.fontSize ?? DashboardLayout.ghosttyDefaultFontSize
            controller.setAppliedFontSize(fontMode.appliedFontSize(memberCount: members.count, base: base))
            var notes: [String] = []
            if !unresolved.isEmpty { notes.append("unresolved: \(unresolved.joined(separator: ", "))") }
            if droppedPanes > 0 {
                notes.append("dropped \(droppedPanes) pane(s) beyond the \(DashboardLayout.maxCells)-cell limit")
            }
            guard !notes.isEmpty else { return ControlResponse(ok: true) }
            return ControlResponse(ok: true, result: ControlResult(text: notes.joined(separator: "; ")))
        }
    }

    /// Project a window's workspace tree into the wire `ControlTree`, marking the active session and the
    /// active workspace (`currentWorkspaceID`, what `--target active` resolves to — not necessarily the
    /// selected session's owner, since an empty or foreground-created workspace becomes current on its own).
    func buildTree(in store: AppStore) -> ControlTree {
        let shellBasename = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        // the projected window owns its quick terminal; find its id by store identity to read the live
        // QuickTerminalController.isVisible (a nil controller — never opened, or tearing down — reads false).
        let windowID = library.windowID(for: store)
        // the window's dashboard controller (nil until WindowContentView registers it), read LIVE for the four
        // dashboard read-backs: the keyboard-driven dashboard bypasses the command path, so a cache goes stale.
        let dashboard = DashboardControllerRegistry.shared.controller(for: windowID)
        return store.controlTree(
            foreground: { session in
                (session.surface as? GhosttySurfaceView).flatMap {
                    ForegroundProcess.running(for: $0, shellBasename: shellBasename)
                }
            },
            splitForeground: { session in
                (session.splitSurface as? GhosttySurfaceView).flatMap {
                    ForegroundProcess.running(for: $0, shellBasename: shellBasename)
                }
            },
            fontSize: { ($0.addressableSurface as? GhosttySurfaceView)?.currentFontSize() },
            splitFontSize: { ($0.splitSurface as? GhosttySurfaceView)?.currentFontSize() },
            scratchFontSize: { ($0.scratchSurface as? GhosttySurfaceView)?.currentFontSize() },
            // both are app-level facts now that the quick terminal is one detached panel, so every projected
            // window reports the same value for them rather than one of its own.
            quickVisible: { QuickTerminalController.shared.isVisible },
            zoomedSurface: {
                if QuickTerminalController.shared.isZoomed { return TerminalZoomTarget.quick.controlID }
                return windowID.flatMap { TerminalZoomRegistry.shared.controller(for: $0)?.target?.controlID }
            },
            // resolved through the projected window's registry entry on every tree build, and tree-only:
            // window.list is cache-backed, so mirroring a GUI-resolved pick there would go stale.
            pickPending: { windowID.flatMap { PickRegistry.shared.controller(for: $0)?.pending?.id } },
            dashboardMembers: {
                guard let dashboard, dashboard.isOpen else { return nil }
                return dashboard.members.map(\.controlRef)
            },
            dashboardHighlighted: {
                guard let dashboard, dashboard.isOpen else { return nil }
                return dashboard.highlighted?.controlRef
            },
            dashboardFontSize: {
                guard let dashboard, dashboard.isOpen else { return nil }
                return dashboard.appliedFontSize
            },
            dashboardFontMode: {
                guard let dashboard, dashboard.isOpen else { return nil }
                switch dashboard.fontMode {
                case .auto: return "auto"
                case .fixed: return "fixed"
                case .untouched: return "untouched"
                }
            }
        )
    }

    /// Creates a session in `workspaceID` of `store` with the `session.new` args (cwd default $HOME, optional
    /// command/name) and returns its id; shared by the id- and name-addressed `.sessionNew` paths. Focuses it
    /// only when it lands in the frontmost window, so a keymap `session new` opens focused like GUI New
    /// Session while a background `--window` target keeps focus. `at` is the anchor-relative
    /// `--after`/`--before` slot (clamped in `AppStore`), nil appends; `options.noSelect` creates in the
    /// background, selection and focus untouched.
    func makeSessionResponse(in store: AppStore, workspaceID: UUID,
                             options: ControlSessionCreateOptions, at index: Int? = nil) -> ControlResponse {
        let cwd = options.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let session = store.addSession(toWorkspace: workspaceID, cwd: cwd,
                                             command: options.command, name: options.name,
                                             wait: options.wait ?? false, at: index, select: !options.noSelect) else {
            return ControlResponse(ok: false, error: "could not create session")
        }
        if !options.noSelect, store === library.activeStore { actions.focusActiveSession() }
        return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
    }

    /// `value` trimmed of surrounding whitespace, or nil if absent or blank after trimming.
    func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Internal, not private: the `ControlServer+*.swift` extensions holding the command arms cannot reach a
    /// private member declared here.
    func log(_ message: @autoclosure () -> String) {
        NSLog("agterm: %@", message())
    }
}
