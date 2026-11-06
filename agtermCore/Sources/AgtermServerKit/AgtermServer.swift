import Foundation
import agtermCore

/// AgtermServer is one running agterm-server: it owns the state directory, the catalog, the headless store and
/// the control socket.
@MainActor
public final class AgtermServer {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case stateDirectoryHeld(String)
        case stateDirectoryUnavailable(String)
        case unreadableCatalog(String)

        public var description: String {
            switch self {
            case .stateDirectoryHeld(let path): "another agterm-server owns \(path)"
            case .stateDirectoryUnavailable(let reason): reason
            case .unreadableCatalog(let reason): "the saved catalog cannot be read, left untouched: \(reason)"
            }
        }
    }

    public let configuration: ServerConfiguration
    public let store: AppStore
    public let catalog: CatalogRoot
    let actions: ServerActions
    let observer: PaneObserver
    private var lock: StateDirectoryLock?
    private var socket: ServerControlSocket?

    private init(configuration: ServerConfiguration, store: AppStore, catalog: CatalogRoot, identity: AppIdentity,
                 panes: ServerPanes, lock: StateDirectoryLock) {
        self.configuration = configuration
        self.store = store
        self.catalog = catalog
        self.lock = lock
        actions = ServerActions(store: store, catalog: catalog, identity: identity, panes: panes)
        observer = PaneObserver(store: store, panes: panes)
    }

    /// start takes the state directory, loads the catalog and the saved store and serves the control socket. A
    /// saved store that exists but does not read is an error rather than an empty catalog, which the next save
    /// would write over it.
    public static func start(configuration: ServerConfiguration, identity: AppIdentity,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             runner: (any ZmxRunner)? = nil) throws -> AgtermServer {
        let directory = URL(fileURLWithPath: configuration.stateDirectory, isDirectory: true)
        let lock: StateDirectoryLock
        switch StateDirectoryLock.acquire(directory: directory) {
        case .owned(let owned): lock = owned
        case .heldByAnother: throw Failure.stateDirectoryHeld(configuration.stateDirectory)
        case .unavailable(let reason): throw Failure.stateDirectoryUnavailable(reason)
        }
        let catalog = try CatalogRoot.load(directory: directory, name: configuration.catalogName)
        let runner = runner ?? ProcessZmxRunner(zmxPath: configuration.zmxPath, socketDirectory: configuration.zmxSocketDirectory,
                                                placement: ServerPlacement.detect(environment: environment),
                                                baseEnvironment: environment)
        let panes = ServerPanes(configuration: configuration, runner: runner, shellPath: configuration.loginShell,
                                catalogID: catalog.id, programVersion: identity.version, environment: environment)
        let persistence = PersistenceStore(directory: directory)
        let store = AppStore(persistence: persistence, paneFinalizer: { identities in
            MainActor.assumeIsolated { panes.end(identities) }
        }, headless: true)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("workspaces.json").path) {
            do {
                store.restore(from: try persistence.loadChecked())
            } catch {
                throw Failure.unreadableCatalog("\(error)")
            }
        }
        CatalogRoot.seedWorkspace(in: store)
        store.save()

        let server = AgtermServer(configuration: configuration, store: store, catalog: catalog, identity: identity,
                                  panes: panes, lock: lock)
        let socket = ServerControlSocket(path: configuration.socketPath) { [weak server] request in
            guard let server else { return ControlResponse(ok: false, error: "agterm-server is stopping") }
            return await server.handle(request)
        }
        server.adopt(runner)
        try socket.start()
        server.socket = socket
        server.observer.start()
        return server
    }

    /// adopt applies one listing before the socket serves anything: a restarted server takes its surviving
    /// daemons back and settles the ones gone meanwhile. A listing that fails is retried; the observer keeps
    /// trying after that, and nothing is settled from a failed one.
    private func adopt(_ runner: any ZmxRunner) {
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
            let began = Date()
            guard let records = try? runner.list() else { continue }
            observer.apply(records, listedAt: began)
            return
        }
    }

    var zmx: any ZmxRunner { actions.panes.runner }

    /// handle refuses a command the server does not serve, then dispatches the rest.
    func handle(_ request: ControlRequest) async -> ControlResponse {
        if let refusal = ServerCommandPolicy.refusal(request.cmd) { return ControlResponse(ok: false, error: refusal) }
        return await ControlDispatcher(actions: actions).dispatch(request)
            ?? ControlResponse(ok: false, error: "\(request.cmd.rawValue) is not available on agterm-server")
    }

    /// stop closes the socket, saves the store and gives up the state directory.
    public func stop() {
        guard lock != nil else { return }
        observer.stop()
        socket?.stop()
        socket = nil
        store.save()
        lock = nil
    }
}
