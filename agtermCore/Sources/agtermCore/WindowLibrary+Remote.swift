import Foundation

extension WindowLibrary {
    /// CatalogBinding is what binding a remote window to the catalog its server reported settles to.
    public enum CatalogBinding: Equatable, Sendable {
        case bound
        /// another window already shows this catalog; the caller raises it and closes the new one
        case duplicate(UUID)
        /// the server reports another catalog than the one this window was bound to, so its rows are a
        /// different set: the server was reinstalled or its state directory replaced
        case rebound(previous: UUID)
    }

    var remoteDirectory: URL { directory.appendingPathComponent("remote", isDirectory: true) }

    /// newRemoteWindow opens a window for `host`, or returns the one already showing it. It is never seeded:
    /// its rows arrive with the first catalog snapshot.
    @discardableResult
    public func newRemoteWindow(host: String) -> WindowInfo {
        if let existing = windows.first(where: { $0.source?.host == host }) {
            loadStore(for: existing.id)
            return existing
        }
        let info = WindowInfo(name: TerminalText.sanitized(host), source: WindowSource(host: host))
        windows.append(info)
        let store = makeStore(for: info.id, persistence: remotePersistence(for: info.id), remote: true)
        stores[info.id] = store
        openSetVersion += 1
        frontmostWindowID = info.id
        saveIndex()
        onRemoteStoreOpened?(info.id, store)
        return info
    }

    /// bindCatalog records the catalog `id`'s window reported, refusing one another window already shows.
    public func bindCatalog(_ catalogID: UUID, toWindow id: UUID) -> CatalogBinding {
        guard let index = windows.firstIndex(where: { $0.id == id }), let source = windows[index].source else { return .bound }
        if let other = windows.first(where: { $0.id != id && $0.source?.catalogID == catalogID }) {
            remoteDuplicates[id] = other.id
            return .duplicate(other.id)
        }
        guard source.catalogID != catalogID else { return .bound }
        windows[index].source?.catalogID = catalogID
        saveIndex()
        guard let previous = source.catalogID else { return .bound }
        return .rebound(previous: previous)
    }

    /// loadRemoteStore opens a remote window with no rows and its saved view state; the mirror fills it.
    func loadRemoteStore(for id: UUID) -> AppStore {
        if let existing = stores[id] { return existing }
        let store = makeStore(for: id, persistence: remotePersistence(for: id), remote: true)
        stores[id] = store
        openSetVersion += 1
        saveIndex()
        onRemoteStoreOpened?(id, store)
        return store
    }

    /// openRemoteStores is every remote window whose store is loaded, for a caller wiring the hooks late.
    public var openRemoteStores: [(id: UUID, store: AppStore)] {
        windows.filter(\.isRemote).compactMap { info in stores[info.id].map { (info.id, $0) } }
    }

    /// settledRemoteWindowID is the window a just-opened remote window `id` turned out to be: the window already
    /// showing its server's catalog, `id` itself once its connection left Connecting or its store is gone, and
    /// nil while it is still connecting.
    public func settledRemoteWindowID(for id: UUID) -> UUID? {
        if let other = remoteDuplicates[id] { return other }
        guard let store = stores[id] else { return id }
        return store.catalogState == .connecting ? nil : id
    }

    /// remoteNode is `id`'s server and connection for `tree` and `window.list`; nil for a local window.
    public func remoteNode(for id: UUID) -> ControlRemoteWindow? {
        guard let source = windows.first(where: { $0.id == id })?.source else { return nil }
        let store = stores[id]
        return ControlRemoteWindow(host: source.host, catalogID: source.catalogID, state: store?.catalogState,
                                   detachedSessions: store?.catalogDetachedSessions ?? [],
                                   detachedWorkspaces: store?.catalogDetachedWorkspaces ?? [],
                                   operations: store?.remoteActions?.marks ?? [])
    }

    /// CloseTarget is where a `session.close` id or prefix lands once hidden rows count: a local window's row (closed
    /// there as before), a remote window's row shown or hidden, or the resolver's error.
    public enum CloseTarget {
        case local
        case remote(AppStore, UUID)
        case refused(String)
        case unresolvedWindow
    }

    /// resolveCloseTarget resolves `target` once over every session a close can reach: local windows' rows and remote
    /// windows' whole catalogs, detached rows included, in `window` alone when one is named. A window that does not
    /// resolve is left to the ordinary resolver's error, never widened to every window.
    public func resolveCloseTarget(_ target: String, window: String?) -> CloseTarget {
        var scope: UUID?
        if let window = window?.trimmingCharacters(in: .whitespaces), !window.isEmpty {
            guard case .resolved(let id) = resolveWindow(window), stores[id] != nil else { return .unresolvedWindow }
            scope = id
        }
        var candidates: [UUID: AppStore] = [:]
        for (id, store) in stores where scope == nil || id == scope {
            let sessions = store.isRemoteWindow ? store.remoteActions?.mirror.catalog?.workspaces.flatMap(\.sessions).map(\.id) ?? []
                : store.workspaces.flatMap { $0.sessions.map(\.id) }
            for session in sessions { candidates[session] = store }
        }
        let resolution = ControlResolve.resolve(target, candidates: Array(candidates.keys), active: nil)
        guard case .resolved(let id) = resolution, let store = candidates[id] else {
            return .refused(ControlResolve.errorMessage(noun: "session", target: target, resolution: resolution))
        }
        return store.isRemoteWindow ? .remote(store, id) : .local
    }

    /// DetachedKind names which of a remote window's detached sets a reattach looks in.
    public enum DetachedKind: Sendable {
        case session, workspace
    }

    /// resolveDetached finds a detached `target` (id or unique prefix) among the open remote windows, or in `window`
    /// alone, answering its store and id or the resolver's error.
    public func resolveDetached(_ target: String, kind: DetachedKind, window: UUID?) -> Result<(AppStore, UUID), DetachedResolutionError> {
        let owners = stores.filter { id, store in store.isRemoteWindow && (window == nil || id == window) }.values
        var candidates: [UUID: AppStore] = [:]
        for store in owners {
            for id in kind == .session ? store.catalogDetachedSessions : store.catalogDetachedWorkspaces { candidates[id] = store }
        }
        let noun = kind == .session ? "detached session" : "detached workspace"
        let resolution = ControlResolve.resolve(target, candidates: Array(candidates.keys), active: nil)
        guard case .resolved(let id) = resolution, let store = candidates[id] else {
            return .failure(DetachedResolutionError(message: ControlResolve.errorMessage(noun: noun, target: target, resolution: resolution)))
        }
        return .success((store, id))
    }

    func remoteStoreClosing(_ id: UUID) {
        guard windows.first(where: { $0.id == id })?.isRemote == true else { return }
        onRemoteStoreClosed?(id)
    }

    public func remoteViewState(for id: UUID) -> RemoteWindowViewState {
        guard let data = try? Data(contentsOf: viewStateURL(for: id)),
              let state = try? JSONDecoder().decode(RemoteWindowViewState.self, from: data) else { return RemoteWindowViewState() }
        return state
    }

    /// saveRemoteViewState writes how `id` shows its rows; a failure is logged and leaves the last state on disk.
    /// A store that has not received its catalog yet writes nothing, keeping the state it will apply.
    @discardableResult
    public func saveRemoteViewState(for id: UUID) -> Bool {
        guard let store = stores[id], store.catalogMirrored, windows.first(where: { $0.id == id })?.isRemote == true else {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(RemoteWindowViewState.capture(from: store)).write(to: viewStateURL(for: id), options: .atomic)
            return true
        } catch {
            log("remote window view state for \(id) could not be saved: \(error)")
            return false
        }
    }

    func removeRemoteFiles(_ id: UUID) {
        try? FileManager.default.removeItem(at: viewStateURL(for: id))
        try? FileManager.default.removeItem(at: remotePersistence(for: id).fileURL)
    }

    // a remote store saves into its own directory, never `windows/`, so orphan recovery cannot resurrect it as a
    // local window
    private func remotePersistence(for id: UUID) -> PersistenceStore {
        PersistenceStore(directory: remoteDirectory, fileName: "\(id.uuidString).store.json")
    }

    private func viewStateURL(for id: UUID) -> URL {
        remoteDirectory.appendingPathComponent("\(id.uuidString).view.json")
    }
}

/// WindowSource names the agterm-server a remote window mirrors. `catalogID` is nil until the first snapshot
/// binds the window to that server's catalog.
public struct WindowSource: Codable, Sendable, Equatable {
    public var host: String
    public var catalogID: UUID?

    public init(host: String, catalogID: UUID? = nil) {
        self.host = host
        self.catalogID = catalogID
    }
}

extension WindowInfo {
    public var isRemote: Bool { source != nil }
}

/// ControlRemoteOperation is one action a remote window sent its server: `state` is `pending` while on its way or
/// `unknown` when its outcome was lost; `session` or `workspace` names the row it acts on, neither for a new workspace.
public struct ControlRemoteOperation: Codable, Sendable, Equatable {
    public let id: String
    public let action: String
    public let session: String?
    public let workspace: String?
    public let state: String

    init(mark: RemoteOperationMark) {
        id = mark.opID
        action = mark.label
        switch mark.target {
        case .session(let id)?: (session, workspace) = (id.uuidString, nil)
        case .workspace(let id)?: (session, workspace) = (nil, id.uuidString)
        case nil: (session, workspace) = (nil, nil)
        }
        state = mark.unknown ? "unknown" : "pending"
    }
}

/// DetachedResolutionError is why a reattach target matched no single detached row.
public struct DetachedResolutionError: Error, Equatable, Sendable {
    public let message: String
}

/// ControlRemoteWindow is a remote window's read-back: the server it mirrors, the catalog it is bound to, and
/// its connection, `state` being connecting, connected, disconnected or refused with `reason` for the last two.
/// `detachedSessions` and `detachedWorkspaces` are what it hides and leaves running, and `operations` the actions
/// still on their way to its server or whose outcome it could not learn; each is omitted when empty.
public struct ControlRemoteWindow: Codable, Sendable, Equatable {
    public let host: String
    public let catalogID: String?
    public let state: String?
    public let reason: String?
    public let detachedSessions: [String]?
    public let detachedWorkspaces: [String]?
    public let operations: [ControlRemoteOperation]?

    public init(host: String, catalogID: UUID?, state: RemoteCatalogMirror.State?, detachedSessions: Set<UUID> = [],
                detachedWorkspaces: Set<UUID> = [], operations: [RemoteOperationMark] = []) {
        self.host = host
        self.catalogID = catalogID?.uuidString
        self.detachedSessions = detachedSessions.isEmpty ? nil : detachedSessions.map(\.uuidString).sorted()
        self.detachedWorkspaces = detachedWorkspaces.isEmpty ? nil : detachedWorkspaces.map(\.uuidString).sorted()
        self.operations = operations.isEmpty ? nil : operations.map(ControlRemoteOperation.init(mark:))
        switch state {
        case nil: (self.state, reason) = (nil, nil)
        case .connecting: (self.state, reason) = ("connecting", nil)
        case .connected: (self.state, reason) = ("connected", nil)
        case .disconnected(let why): (self.state, reason) = ("disconnected", why)
        case .refused(let why): (self.state, reason) = ("refused", why)
        }
    }
}
