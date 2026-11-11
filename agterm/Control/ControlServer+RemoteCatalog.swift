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
        PaneLead.scratchStopped = { [weak self] view in self?.catalogScratchStopped(view) ?? false }
        for (id, store) in library.openRemoteStores { startRemoteCatalog(window: id, store: store) }
    }

    func startRemoteCatalog(window id: UUID, store: AppStore) {
        guard remoteCatalogs[id] == nil, let host = library.windows.first(where: { $0.id == id })?.source?.host else { return }
        let runner = remoteRunner
        let pool = SshConnectionPool(host: host, root: Self.sshPoolRoot, key: "\(socketPath)|\(id.uuidString)") { argv in
            await runner.run(argv, deadline: 15).status
        }
        let effects = RemoteCatalogWindow(window: id, server: self, pool: pool)
        let mirror = RemoteCatalogMirror(host: host, store: store, effects: effects, viewState: library.remoteViewState(for: id),
                                         pool: pool)
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
        let runner = remoteRunner
        for command in link.pool.close() {
            Task { _ = await runner.run(command, deadline: 5) }
        }
    }

    func stopRemoteCatalogs() {
        for id in Array(remoteCatalogs.keys) { stopRemoteCatalog(window: id) }
    }

    /// windowRemoteOpen opens `host`'s window and replies once it knows which window shows that catalog: a host
    /// that is another name for a server already open settles on that window, which is raised in its place.
    func windowRemoteOpen(host: String) async -> ControlResponse {
        let info = library.newRemoteWindow(host: host)
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

    /// attachCommand never claims the lead: a remote window attaches again on every reconnect, and a claim each
    /// time would take the pane from another Mac at every network blip. A covered pane takes over on a key.
    func attachCommand(host: String, pane: CatalogPane) -> String {
        let lead = ZmxLeadAttachment(claim: false)
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

    func catalogRowAdded(_ session: Session) { server?.startRemotePresentation(for: session) }

    func catalogRowRemoved(_ sessionID: UUID) { server?.stopRemotePresentation(sessionID) }

    func catalogRowEnded(_ sessionID: UUID) { server?.stopRemotePresentation(sessionID) }

    func catalogPaneNeedsAttach(_ identity: UUID, session: UUID) {
        server?.catalogPaneNeedsAttach(identity, session: session)
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
