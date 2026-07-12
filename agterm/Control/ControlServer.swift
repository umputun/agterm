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
        // a GUI-only sidebar toggle (⌃⌘S / toolbar / menu / palette) mutates sidebarVisible without a
        // control command, so refresh the cache on it too — otherwise window.list's sidebarVisible lags.
        // queue nil (NOT .main) delivers synchronously on the posting thread: setSidebarVisible is
        // @MainActor, so the refresh runs on the main actor BEFORE the toggle returns. An async .main hop
        // would leave a window where a background window.list fast-path read still sees the stale cache.
        NotificationCenter.default.addObserver(forName: .agtermSidebarVisibilityChanged, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowCache() }
        }
        // window.list carries LIVE NSWindow geometry + fullscreen/zoom state, read at cache-build time. A
        // user drag/resize/zoom/fullscreen changes it with NO control command, and a polling window.list is
        // fast-path-served so it never refreshes its own cache — so observe the AppKit window notifications
        // and refresh the cache on each. The fullscreen enter/exit notifications fire AFTER the async
        // transition, so the refreshed cache sees the settled `styleMask`. The notification is ignored (not
        // captured — a non-Sendable `Notification` can't cross into the `assumeIsolated` region under Swift 6);
        // it fires for ANY window, but a non-agterm panel just rebuilds the same cheap agterm nodes, and a
        // drag's didMove/didResize storm just keeps the cache current.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindowCache() }
            }
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
        if let response = await ControlDispatcher(actions: self).dispatch(request) {
            return response
        }
        switch request.cmd {
        case .tree, .sessionNew, .sessionSelect, .sessionGo, .sessionClose, .sessionRename, .sessionReveal,
                .sessionMove,
                .workspaceNew, .workspaceSelect, .workspaceRename, .workspaceDelete, .workspaceMove, .workspaceFocus,
                .sessionSplit, .sessionScratch, .sessionFocus, .sessionResize, .surfaceZoom,
                .sessionStatus, .sessionFlag, .sessionSeen, .notify,
                .fontInc, .fontDec, .fontReset, .keymapReload, .configReload, .themeSet, .themeList,
                .sidebar, .sidebarMode, .sidebarExpand, .sidebarCollapse, .sessionType, .sessionCopy,
                .sessionPaste, .sessionSelectAll,
                .sessionSearch, .sessionOverlayOpen, .sessionOverlayClose, .sessionOverlayResize,
                .sessionOverlayResult, .sessionBackground, .sessionText, .quick, .quickType, .quickText,
                .windowNew, .windowList, .windowSelect,
                .windowClose, .windowRename, .windowDelete, .windowResize, .windowMove, .windowZoom,
                .windowFullscreen, .restoreClear, .dashboard:
            return ControlResponse(ok: false, error: "control dispatcher did not handle \(request.cmd.rawValue)")
        case .debugAppearance:
            return setDebugAppearance(args: request.args)
        }
    }

    /// UI-TEST-ONLY seam: force the app-level appearance so an XCUITest can simulate a macOS light/dark
    /// flip deterministically (macOS XCUITest has no API to change the system appearance). Setting
    /// `NSApp.appearance` changes `NSApp.effectiveAppearance`; this arm ALSO posts
    /// `.agtermSystemAppearanceChanged` directly, so the REAL flip path (scheme sync → debounced
    /// zoom-preserving reload) is exercised end to end without depending on whether KVO fires on an
    /// explicit set (production relies on the KVO observer firing on a genuine system flip). Refused
    /// outside an XCUITest launch, and deliberately EXEMPT from the four-point keep-in-sync (no agtermctl
    /// subcommand, absent from the catalog/skill) — test scaffolding, not a control surface. Setting
    /// echoes the resulting effective side in `result.text`; the BARE form (no name) reads the side the
    /// last config feed applied (`SettingsModel.lastAppliedIsDark`), which a test polls to assert the
    /// flip actually drove the reload — a suppressed flip leaves it on the old side.
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
        // take the validated `side` directly — do NOT re-read `currentIsDark()`, whose
        // `effectiveAppearance` may not have settled synchronously right after the set (the same
        // "take the delivered value, never re-read" rule the production `SystemAppearanceObserver` follows).
        let isDark = side == "dark"
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        // drive the flip pipeline directly (a duplicate KVO post, if any, is same-side-suppressed).
        NotificationCenter.default.post(name: .agtermSystemAppearanceChanged, object: nil,
                                        userInfo: ["isDark": isDark])
        return ControlResponse(ok: true, result: ControlResult(text: isDark ? "dark" : "light"))
    }

    /// Clear every open session's saved foreground command (the restore-running-command capture) and
    /// persist, so the next launch restores plain shells. The live fields are normally already nil
    /// (consumed at restore); the SAVE is what wipes the on-disk copy from the last quit, also closing
    /// the force-quit re-fire window. Drives `restore.clear` / `agtermctl restore clear`. App-global like
    /// `keymap.reload` (no `--window` selector — it clears every open window).
    func clearRestoreCommands() -> ControlResponse {
        for session in library.allOpenSessions() {
            session.foregroundCommand = nil
            session.splitForegroundCommand = nil
        }
        library.saveAllOpen()
        return ControlResponse(ok: true)
    }

    /// Open or close the target window's dashboard overlay — the app side of the host-free `dashboard`
    /// command (the dispatcher validated the args and built `fontMode`; it no longer caps the ids). Resolves
    /// `window ?? frontmost` to an OPEN window's store. With `mru` it pulls up to `DashboardLayout.maxCells`
    /// of that window's most-recently-used sessions from the store's recency (fewer if it has fewer; nothing
    /// goes unresolved); otherwise it resolves each id to a session in THAT store, deduping by resolved UUID
    /// (order preserved) and reporting any that don't resolve in `result.text` (never a silent drop). It then
    /// EXPANDS each resolved session IN ORDER into pane cells — always its `.primary` pane, plus a `.split`
    /// cell when the session `hasSplit` (both shells alive) — so a split session shows as TWO cells. The
    /// `DashboardLayout.maxCells` (9) cap now counts PANES, applied here after expansion; any dropped panes
    /// are reported alongside `unresolved` (joined with "; "). Each cell reparents its OWN pane surface
    /// (`.primary` → `\.surface`, `.split` → `\.splitSurface`) app-side in `WindowContentView`. Opening closes
    /// any active terminal zoom for the window (zoom and dashboard are mutually exclusive) and drives that
    /// window's `DashboardController` via the registry; `--close` calls `close()`. The per-window controller
    /// is registered by `WindowContentView`; until it is (or while the window is tearing down) the registry
    /// returns nil and this reports the window isn't open.
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
            var sessionIDs: [UUID] = []
            var unresolved: [String] = []
            if mru {
                // --mru: pull the window's most-recently-used sessions (≤ maxCells) from the store's recency;
                // there are no explicit ids to resolve, so nothing goes unresolved.
                sessionIDs = store.recentSessions(limit: DashboardLayout.maxCells)
                guard !sessionIDs.isEmpty else {
                    return ControlResponse(ok: false, error: "no recent sessions")
                }
            } else {
                let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
                var seen = Set<UUID>()
                for target in targets {
                    guard case .resolved(let id) = ControlResolve.resolve(target, candidates: candidates,
                                                                          active: store.selectedSessionID),
                          store.session(withID: id) != nil else {
                        unresolved.append(target)
                        continue
                    }
                    if seen.insert(id).inserted { sessionIDs.append(id) }
                }
                guard !sessionIDs.isEmpty else {
                    return ControlResponse(ok: false, error: "no dashboard sessions resolved")
                }
            }
            // expand each resolved session into pane cells (always the primary pane, plus the split pane when the
            // session hasSplit) and cap the resulting PANE list to the 9-cell limit — the shared host-free
            // AppStore helper, so this expansion+cap has one implementation with AppActions.toggleDashboard.
            let (members, droppedPanes) = store.dashboardMembers(for: sessionIDs, limit: DashboardLayout.maxCells)
            // zoom and dashboard are mutually exclusive: drop any active zoom for this window on open.
            TerminalZoomRegistry.shared.controller(for: windowID)?.clear()
            controller.open(members: members, fontMode: fontMode)
            // set the applied font size SYNCHRONOUSLY so the `dashboardFontSize` tree read-back is
            // authoritative at command return: the SwiftUI onChange that applies the surface overrides runs a
            // runloop turn later, and open() never resets appliedFontSize — an untouched re-open would
            // otherwise leak the prior fixed/auto size. Idempotent with the wiring, which resolves the same
            // (base, member-count, mode) through the shared DashboardFontMode.appliedFontSize seam.
            let base = settingsModel.settings.fontSize ?? DashboardLayout.ghosttyDefaultFontSize
            controller.setAppliedFontSize(fontMode.appliedFontSize(memberCount: members.count, base: base))
            // combine "unresolved: …" (ids that didn't resolve) with a dropped-panes note (panes past the
            // 9-cell cap) into one message, joined with "; " — neither clobbers the other.
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
    /// active workspace (the one owning the selected session).
    func buildTree(in store: AppStore) -> ControlTree {
        let shellBasename = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        // the projected window owns its quick terminal; find its id by store identity to read the live
        // QuickTerminalController.isVisible (a nil controller — never opened, or the window is tearing
        // down — reads as not visible).
        let windowID = library.windowID(for: store)
        // the projected window's dashboard controller (nil until WindowContentView registers it), read
        // LIVE for the four dashboard read-backs — tree-only, since the keyboard-driven dashboard bypasses
        // the command path and a cached copy would go stale (same reason as zoomedSurface/quickVisible).
        let dashboard = DashboardControllerRegistry.shared.controller(for: windowID)
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
            },
            fontSize: { ($0.addressableSurface as? GhosttySurfaceView)?.currentFontSize() },
            splitFontSize: { ($0.splitSurface as? GhosttySurfaceView)?.currentFontSize() },
            scratchFontSize: { ($0.scratchSurface as? GhosttySurfaceView)?.currentFontSize() },
            quickVisible: { windowID.flatMap { QuickTerminalRegistry.shared.controller(for: $0)?.isVisible } ?? false },
            zoomedSurface: { windowID.flatMap { TerminalZoomRegistry.shared.controller(for: $0)?.target?.controlID } },
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

    /// Creates a session in `workspaceID` of `store` with the `session.new` args (cwd default $HOME,
    /// optional command/name), focuses it when it lands in the frontmost window (so a keymap `session new`
    /// opens focused like the GUI New Session; a background `--window` target keeps focus), and returns the
    /// new id. Shared by the id- and name-addressed paths of the `.sessionNew` arm. `at` is the anchor-relative
    /// insertion slot for `--after`/`--before` (clamped in `AppStore`); nil appends.
    func makeSessionResponse(in store: AppStore, workspaceID: UUID,
                             options: ControlSessionCreateOptions, at index: Int? = nil) -> ControlResponse {
        let cwd = options.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let session = store.addSession(toWorkspace: workspaceID, cwd: cwd,
                                             command: options.command, name: options.name, at: index) else {
            return ControlResponse(ok: false, error: "could not create session")
        }
        if store === library.activeStore { actions.focusActiveSession() }
        return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
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
