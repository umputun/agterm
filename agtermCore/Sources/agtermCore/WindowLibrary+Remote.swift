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
        return ControlRemoteWindow(host: source.host, catalogID: source.catalogID, state: stores[id]?.catalogState)
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

/// ControlRemoteWindow is a remote window's read-back: the server it mirrors, the catalog it is bound to, and
/// its connection, `state` being connecting, connected, disconnected or refused with `reason` for the last two.
public struct ControlRemoteWindow: Codable, Sendable, Equatable {
    public let host: String
    public let catalogID: String?
    public let state: String?
    public let reason: String?

    public init(host: String, catalogID: UUID?, state: RemoteCatalogMirror.State?) {
        self.host = host
        self.catalogID = catalogID?.uuidString
        switch state {
        case nil: (self.state, reason) = (nil, nil)
        case .connecting: (self.state, reason) = ("connecting", nil)
        case .connected: (self.state, reason) = ("connected", nil)
        case .disconnected(let why): (self.state, reason) = ("disconnected", why)
        case .refused(let why): (self.state, reason) = ("refused", why)
        }
    }
}
