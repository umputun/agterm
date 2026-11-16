import Foundation
import agtermCore

/// ServerActions is agterm-server's side of `ControlDispatcher`: the headless store answering as the catalog's one
/// logical window. Window arguments name that window or nothing.
@MainActor
public final class ServerActions: ControlActions {
    let store: AppStore
    let catalog: CatalogRoot
    let identity: AppIdentity
    let panes: ServerPanes
    let streams: ServerStreams
    let events: ServerEvents
    var hudAutoHide: [UUID: HudTimer] = [:]
    var infoAutoHide: [UUID: InfoTimer] = [:]
    /// macDefaults are the settings the server's status and badge clears follow: it has no settings of its own.
    static let macDefaults = AppSettings()
    /// foregroundArgv reads the foreground program of the terminal whose shell is the given pid.
    var foregroundArgv: (Int32) -> [String]? = ProcForeground.argv
    /// replayObservation reads, for a replay, the process holding the terminal of the shell with the given pid.
    var replayObservation: (_ leader: Int32, _ shell: String?) -> RestartReplay.Observation = ProcReplay.observation
    /// processes is the host's process table, through which a kill hangs up the pane's foreground job.
    var processes: any ProcessTable = ProcProcessTable()
    /// paneExited runs the exit transition of a pane whose daemon a confirmed kill ended.
    var paneExited: ((Session, UUID) -> Void)?
    /// restartWaits bounds a restart's waits for the old program to end and the new shell to appear.
    var restartWaits = (program: Duration.seconds(1), shell: Duration.seconds(10), poll: Duration.milliseconds(100))
    /// operationBook runs each operation id at most once against the server's catalog.
    let operationBook = CatalogOperationBook()
    /// recentClosed is the history the store writes its closes into; nil serves no `recent.*`.
    var recentClosed: RecentClosedStore?
    /// pendingCloses is rewritten after each served command, so a crash inside a close's grace is finished at start.
    var pendingCloses: PendingCloseJournal?
    /// recentItems caches `recentClosed` for the catalog, which projects it on every refresh; a served command drops it.
    var recentItems: [ControlRecentItem]?

    init(store: AppStore, catalog: CatalogRoot, identity: AppIdentity, panes: ServerPanes, events: ServerEvents,
         overlayJobs: OverlayJobs = OverlayJobs()) {
        self.store = store
        self.events = events
        self.catalog = catalog
        self.identity = identity
        self.panes = panes
        streams = ServerStreams(store: store, catalogID: catalog.id, overlayJobs: overlayJobs)
        streams.dispatch = { [weak self] request in
            await self?.serve(request) ?? ControlResponse(ok: false, error: "agterm-server is stopping")
        }
        wireAskOwners()
        streams.catalogVersions = catalogVersions
        streams.catalogWorkspaces = { [weak self] in self?.catalogWorkspaces() ?? [] }
        streams.catalogRecent = { [weak self] in self?.catalogRecent() }
    }

    /// serve refuses a command the server does not serve, then dispatches the rest: the socket's requests and a
    /// handed-over page's bridge requests alike. The catalog is published after each, whatever it changed.
    func serve(_ request: ControlRequest) async -> ControlResponse {
        if let refusal = ServerCommandPolicy.refusal(request.cmd) { return ControlResponse(ok: false, error: refusal) }
        defer {
            pendingCloses?.record(store)
            recentItems = nil
            streams.catalogHub.refresh()
        }
        if let opID = request.args?.opID { return await operationBook.serve(request, opID: opID, host: self) }
        if let refusal = pageRowRefusal(request) { return refusal }
        let response = await ControlDispatcher(actions: self).dispatch(request)
            ?? ControlResponse(ok: false, error: "\(request.cmd.rawValue) is not available on agterm-server")
        streams.catalogHub.refresh()
        return response
    }

    func catalogRecent() -> [ControlRecentItem]? {
        guard let recentClosed else { return nil }
        if let recentItems { return recentItems }
        let items = recentClosed.load().map(ControlRecentItem.init)
        recentItems = items
        return items
    }

    /// pageRowRefusal answers a command a page row cannot take; an operation records it as its refused receipt.
    func pageRowRefusal(_ request: ControlRequest) -> ControlResponse? {
        PageSessionRefusal.refusal(request) { target, _ in
            if case .success(let session) = self.resolveSession(target) { return session.content == .page }
            return false
        }
    }

    public func claimOverlayJob(_ job: String) -> ControlResponse { streams.claimJobStream(job) }

    public func claimOverlayJob(_ job: String, token: String?) -> ControlResponse { streams.claimJobStream(job, token: token) }

    public func claimPageServe(_ token: String) -> ControlResponse { streams.claimPageStream(token) }

    public func controlTree(window: String?) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        return ControlResponse(ok: true, result: ControlResult(tree: tree()))
    }

    /// tree is the catalog's tree with each pane's foreground program read through its shell's pid.
    func tree() -> ControlTree {
        store.controlTree(paneForeground: { self.foreground(of: $0.paneIdentity) },
                          splitPaneForeground: { $0.hasSplit ? $0.splitPaneIdentity.flatMap(self.foreground) : nil }, app: identity)
    }

    private func foreground(of identity: UUID) -> CommandRestore.PaneForeground? {
        guard let leader = panes.leaders[identity], let argv = foregroundArgv(leader) else { return nil }
        return CommandRestore.paneForeground(argv: argv, extra: (panes.shellPath as NSString).lastPathComponent)
    }

    public func readEvents(_ options: ControlEventReadOptions) -> ControlResponse {
        events.flushTree()
        return events.ring.readResponse(options)
    }

    public func appIdentity() -> ControlResponse {
        var result = ControlResult(app: identity)
        result.headless = true
        result.versions = catalogVersions
        return ControlResponse(ok: true, result: result)
    }

    public func windowList() -> ControlResponse {
        let node = ControlWindowNode(id: catalog.id.uuidString, name: catalog.name, open: true, active: true)
        return ControlResponse(ok: true, result: ControlResult(windows: [node]))
    }

    /// windowRefusal accepts no window, the catalog's id (any case) or `active`, and refuses any other.
    func windowRefusal(_ window: String?) -> ControlResponse? {
        guard let window, !window.isEmpty, window != "active",
              UUID(uuidString: window) != catalog.id else { return nil }
        return ControlResponse(ok: false, error: "window not found: \(window); agterm-server has one window, \(catalog.id.uuidString)")
    }
}

/// ActionRefusal carries the reply for a target that did not resolve.
struct ActionRefusal: Error {
    let response: ControlResponse
}

extension Result where Failure == ActionRefusal {
    static func refused(_ response: ControlResponse) -> Self { .failure(ActionRefusal(response: response)) }
}
