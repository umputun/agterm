import Foundation
import os
import agtermCore

private let catalogLogger = Logger(subsystem: "com.umputun.agterm", category: "RemoteCatalog")

/// RemoteCatalogLink is one remote window's catalog stream, retaining the effects its mirror holds only weakly.
struct RemoteCatalogLink {
    let client: RemoteCatalogClient
    let effects: RemoteCatalogWindow
    let pool: SshConnectionPool
    let actions: RemoteCatalogActions
}

extension ControlServer {
    /// wireRemoteCatalogs runs a stream for every remote window open now and every one that opens later.
    func wireRemoteCatalogs() {
        guard library.onRemoteStoreOpened == nil else { return }
        library.onRemoteStoreOpened = { [weak self] id, store in self?.startRemoteCatalog(window: id, store: store) }
        library.onRemoteStoreClosed = { [weak self] id in self?.stopRemoteCatalog(window: id) }
        PaneLead.scratchStopped = { [weak self] view in self?.remoteScratchStopped(view) ?? false }
        for (id, store) in library.openRemoteStores { startRemoteCatalog(window: id, store: store) }
    }

    func startRemoteCatalog(window id: UUID, store: AppStore) {
        guard remoteCatalogs[id] == nil, let source = library.windows.first(where: { $0.id == id })?.source else { return }
        let host = source.host
        let runner = remoteRunner
        let pool = SshConnectionPool(host: host, root: Self.sshPoolRoot, key: "\(socketPath)|\(id.uuidString)") { argv in
            await runner.run(argv, deadline: 15).status
        }
        let effects = RemoteCatalogWindow(window: id, server: self, pool: pool)
        let mirror = RemoteCatalogMirror(host: host, store: store, effects: effects, viewState: library.remoteViewState(for: id),
                                         pool: pool, originWindow: source.originWindow, claimOnOpen: library.takeOpenClaim(id))
        let run: RemoteCatalogClient.Runner = { argv in
            let result = await runner.run(argv, deadline: 15)
            return (result.status, result.stdout)
        }
        let client = RemoteCatalogClient(mirror: mirror, transport: remoteTransport, runner: run, pool: pool)
        let actions = RemoteCatalogActions(mirror: mirror, runner: run, pool: pool)
        actions.onChange = { [weak self] in self?.refreshWindowCache() }
        store.remoteActions = actions
        remoteCatalogs[id] = RemoteCatalogLink(client: client, effects: effects, pool: pool, actions: actions)
        client.start()
    }

    /// sshPoolRoot holds the pools' master sockets: under `/tmp`, since a socket path caps near 104 bytes, and
    /// private to this user.
    static let sshPoolRoot: String = {
        let root = "/tmp/agterm-ssh-\(getuid())"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return root
    }()

    /// catalogPool is the ssh pool of the remote window holding catalog row `sessionID`, nil for any other row.
    func catalogPool(forSession sessionID: UUID) -> SshConnectionPool? {
        guard let store = library.store(forSession: sessionID),
              store.session(withID: sessionID)?.remotePresentation?.binding.catalogOwned == true,
              let window = library.windowID(for: store) else { return nil }
        return remoteCatalogs[window]?.pool
    }

    /// stopRemoteCatalog detaches a closing window: its stream and its rows' presentation streams end here, the
    /// window's own teardown ends the pane attaches, and the server keeps every session.
    func stopRemoteCatalog(window id: UUID) {
        guard let link = remoteCatalogs.removeValue(forKey: id) else { return }
        link.client.stop()
        link.actions.stop()
        for session in library.store(for: id)?.workspaces.flatMap(\.sessions) ?? [] { stopRemotePresentation(session.id) }
        linkForwards.stop(window: id)
        let runner = remoteRunner
        for command in link.pool.close() {
            Task { _ = await runner.run(command, deadline: 5) }
        }
    }

    func stopRemoteCatalogs() {
        for id in Array(remoteCatalogs.keys) { stopRemoteCatalog(window: id) }
    }

    func windowRemoteOpen(host: String) async -> ControlResponse {
        await windowRemoteOpen(host: host, originWindow: nil)
    }

    /// windowRemoteOpen opens the window showing `host`: a Mac's `originWindow`, or its one open window when none is
    /// named; any other host as agterm-server.
    func windowRemoteOpen(host: String, originWindow: String?) async -> ControlResponse {
        switch await remoteOrigin(host: host) {
        case .failed(let reason):
            return ControlResponse(ok: false, error: reason)
        case .mac(let windows):
            switch RemoteOriginWindow.choose(host: host, windows: windows, requested: originWindow) {
            case .failure(let refusal): return ControlResponse(ok: false, error: refusal.message)
            case .success(let window):
                guard let id = UUID(uuidString: window.id) else { return ControlResponse(ok: false, error: "\(host) listed window \(window.id)") }
                return await openRemote(library.newRemoteWindow(host: host, originWindow: id, originName: window.name))
            }
        case .unanswered where originWindow != nil:
            return ControlResponse(ok: false, error: "\(host) did not answer")
        case .server where originWindow != nil:
            return ControlResponse(ok: false, error: "\(host) runs agterm-server, which has no windows to name")
        case .server, .unanswered:
            return await openRemote(library.newRemoteWindow(host: host))
        }
    }

    /// remoteOrigin asks `host` what it serves remote windows from. A host that does not answer is opened as
    /// agterm-server was, so its window shows the connection and retries, unless a window of it names a Mac's window:
    /// that host is a Mac, whose window an origin-less one could never show.
    func remoteOrigin(host: String) async -> RemoteOrigin {
        let unanswered: RemoteOrigin = library.windows.contains { $0.source?.host == host && $0.source?.originWindow != nil }
            ? .failed("\(host) did not answer") : .unanswered
        guard let probe = try? RemoteSession.controlCommand(host: host, arguments: ["version"]) else { return unanswered }
        let version = await remoteRunner.run(probe, deadline: 15)
        guard version.status == 0, let answer = try? JSONDecoder().decode(ControlResponse.self, from: Data(version.stdout.utf8)) else {
            return unanswered
        }
        guard let mac = answer.result?.macCatalog else { return .server }
        if mac.live == false { return .failed(OriginCatalogRefusal.notLive.message(host: host)) }
        guard let windows = await originWindows(host: host) else { return .failed("\(host) did not list its windows") }
        return .mac(windows)
    }

    /// originWindows is the Mac `host`'s `window list`, nil when it does not answer with one.
    func originWindows(host: String) async -> [ControlWindowNode]? {
        guard let listing = try? RemoteSession.controlCommand(host: host, arguments: ["window", "list"]) else { return nil }
        let listed = await remoteRunner.run(listing, deadline: 15)
        guard listed.status == 0, let response = try? JSONDecoder().decode(ControlResponse.self, from: Data(listed.stdout.utf8)) else {
            return nil
        }
        return response.result?.windows
    }

    /// openRemote opens `info` and replies once it knows which window shows that catalog: a host that is another
    /// name for a server already open settles on that window, which is raised in its place.
    private func openRemote(_ info: WindowInfo) async -> ControlResponse {
        actions.openWindow?(info.id)
        // up to 20 s, the version probe's ssh deadline with room to spare; a duplicate may never register
        for _ in 0..<400 {
            if let settled = library.settledRemoteWindowID(for: info.id),
               settled != info.id || WindowRegistry.shared.isRegistered(info.id) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let settled = library.settledRemoteWindowID(for: info.id) ?? info.id
        // `remoteCatalogDuplicate` opens the winner, which may have been closed, a turn after the snapshot
        if settled != info.id {
            for _ in 0..<60 {
                if WindowRegistry.shared.isRegistered(settled) { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        // a background caller gets no key-window handoff, so frontmost is published here
        takeFrontmost(settled)
        return ControlResponse(ok: true, result: ControlResult(id: settled.uuidString))
    }

    /// remoteCatalogDuplicate replaces window `id`, whose server turned out to be `existing`'s, with `existing`.
    /// Deferred one turn: the mirror is still inside the snapshot that found it.
    func remoteCatalogDuplicate(_ id: UUID, of existing: UUID) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.actions.openWindow?(existing)
                WindowRegistry.shared.close(id)
                self.library.removeWindow(id)
                self.refreshWindowCache()
            }
        }
    }

    func catalogPaneNeedsAttach(_ identity: UUID, session sessionID: UUID) {
        guard let session = library.store(forSession: sessionID)?.session(withID: sessionID) else { return }
        let surface = session.paneIdentity == identity ? session.surface
            : session.splitPaneIdentity == identity ? session.splitSurface : nil
        // no surface yet: the slot's own command is the attach
        guard let view = surface as? GhosttySurfaceView else { return }
        PaneLead.reattach?(view, false)
    }

    /// catalogClaimLead takes the lead of a running pane this Mac owes it: a covered one attaches again with the claim,
    /// one that has not reported a role yet takes it on its first report.
    func catalogClaimLead(_ identity: UUID, session sessionID: UUID) {
        guard let session = library.store(forSession: sessionID)?.session(withID: sessionID) else { return }
        let surface = session.paneIdentity == identity ? session.surface
            : session.splitPaneIdentity == identity ? session.splitSurface : nil
        guard let view = surface as? GhosttySurfaceView, !view.isDestroyed else { return }
        let book = ZmxLeadBook.shared
        guard book.role(pane: identity) != nil else { return book.claimOnReport(pane: identity) }
        if view.leadCovered, !book.reattaching(pane: identity) { PaneLead.reattach?(view, true) }
    }
}

/// RemoteCatalogWindow is the app side of one remote window's mirror.
@MainActor
final class RemoteCatalogWindow: RemoteCatalogEffects {
    let window: UUID
    private weak var server: ControlServer?
    private let pool: SshConnectionPool

    init(window: UUID, server: ControlServer, pool: SshConnectionPool) {
        self.window = window
        self.server = server
        self.pool = pool
    }

    /// attachCommand claims the lead only when the mirror says so, on a user's open or a row this Mac created: a remote
    /// window attaches again on every reconnect, and a claim each time would take the pane from another Mac at every
    /// network blip. A covered pane takes over on a key.
    func attachCommand(host: String, pane: CatalogPane, claim: Bool) -> String {
        let lead = ZmxLeadAttachment(claim: claim)
        guard let command = try? RemoteSession.attachPaneCommand(host: host, endpoint: pane.endpoint, daemon: pane.daemon,
                                                                 session: pane.daemon, pane: .left, lead: lead,
                                                                 controlPath: pool.lease("pane:\(pane.identity)")) else {
            catalogLogger.error("\(host, privacy: .public) listed pane \(pane.identity, privacy: .public) agterm cannot address")
            return CommandRestore.shellQuotedLine(["/usr/bin/env", "/bin/sh", "-c",
                                                   "printf '%s\\n' 'agterm: \(host) listed a pane agterm cannot address'; exit 1"])
        }
        ZmxLeadBook.shared.begin(lead, pane: pane.identity)
        return command
    }

    func scratchAttachCommand(host: String, pane: CatalogPane) -> String {
        (try? RemoteSession.attachPaneCommand(host: host, endpoint: pane.endpoint, daemon: pane.daemon, session: "scratch",
                                              pane: .left, linkNonce: ZmxLeadAttachment.makeNonce(), controlPath: pool.lease("pane:\(pane.identity)")))
            ?? CommandRestore.shellQuotedLine(["/usr/bin/env", "/bin/sh", "-c",
                                               "printf '%s\\n' 'agterm: \(host) listed a scratch agterm cannot address'; exit 1"])
    }

    /// catalogRowAdded starts a row's presentation stream, and a page row's page beside it.
    func catalogRowAdded(_ session: Session) {
        if session.content == .page { server?.attachCatalogPage(session.id) }
        server?.startRemotePresentation(for: session)
    }

    func catalogRowRemoved(_ sessionID: UUID) { server?.stopRemotePresentation(sessionID) }

    func catalogRowEnded(_ sessionID: UUID) { server?.stopRemotePresentation(sessionID) }

    func catalogClaimLead(_ identity: UUID, session: UUID) {
        server?.catalogClaimLead(identity, session: session)
    }

    func catalogPaneNeedsAttach(_ identity: UUID, session: UUID) {
        server?.catalogPaneNeedsAttach(identity, session: session)
    }

    func catalogWorkspaceCollapsed(_ id: UUID) {
        guard let server, let store = server.library.store(for: window) else { return }
        server.actions.setWorkspaceExpanded(id, expanded: false, in: store)
    }

    func catalogBound(_ catalogID: UUID) -> Bool {
        guard let server else { return false }
        guard case .duplicate(let existing) = server.library.bindCatalog(catalogID, toWindow: window) else { return true }
        server.remoteCatalogDuplicate(window, of: existing)
        return false
    }

    func catalogViewStateChanged() {
        _ = server?.library.saveRemoteViewState(for: window)
        server?.refreshWindowCache()
    }

    func catalogStateChanged(_ state: RemoteCatalogMirror.State) {
        server?.refreshWindowCache()
        catalogLogger.notice("remote window \(self.window, privacy: .public): \(String(describing: state), privacy: .public)")
    }
}
