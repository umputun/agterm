import Foundation

/// OriginCatalog is one Mac window's catalog, kept from first use until the app quits: its hub, publisher, row
/// projection and receipt book outlive the window's store, which `bind` swaps when the window closes and reopens.
@MainActor
public final class OriginCatalog {
    public let window: UUID
    public let projection = OriginCatalogProjection()
    public let book = CatalogOperationBook()
    public private(set) var store: AppStore?
    public private(set) lazy var hub = CatalogHub(epoch: epoch, staleTimeout: staleTimeout) { [unowned self] in snapshot() }
    public private(set) lazy var publisher = CatalogPublisher(hub: hub, schedule: schedule)

    private let epoch: String
    private let staleTimeout: TimeInterval
    private let shape: CatalogProjection
    private let versions: CatalogVersions
    private let recent: (UUID) -> [ControlRecentItem]
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    private var last: [CatalogWorkspace] = []

    /// Options are what every window's catalog on this Mac shares.
    public struct Options {
        public var epoch: String
        public var staleTimeout: TimeInterval
        public var shape: CatalogProjection
        public var versions: CatalogVersions
        /// recent is a window's own Recent Closed items, newest first.
        public var recent: (UUID) -> [ControlRecentItem]
        public var schedule: (@escaping @MainActor () -> Void) -> Void

        public init(epoch: String, staleTimeout: TimeInterval, shape: CatalogProjection, versions: CatalogVersions,
                    recent: @escaping (UUID) -> [ControlRecentItem],
                    schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { work in Task { @MainActor in work() } }) {
            self.epoch = epoch
            self.staleTimeout = staleTimeout
            self.shape = shape
            self.versions = versions
            self.recent = recent
            self.schedule = schedule
        }
    }

    public init(window: UUID, options: Options) {
        self.window = window
        epoch = options.epoch
        staleTimeout = options.staleTimeout
        shape = options.shape
        versions = options.versions
        recent = options.recent
        schedule = options.schedule
    }

    /// bind attaches the window's store, adopting the receipts saved with it into this epoch, or detaches it (nil)
    /// when the window closes; a detached catalog keeps its last rows and publishes nothing.
    public func bind(_ store: AppStore?) {
        self.store = store
        guard let store else { return }
        publisher.publish()
        store.catalogOperations?.adopt(epoch: hub.epoch, rev: hub.rev)
    }

    /// operation is the host that runs one operation in this window through `run`, keeping its receipts in the store
    /// `library` has open for the window at each step.
    public func operation(in library: WindowLibrary,
                          run: @escaping @MainActor (ControlRequest) async -> ControlResponse) -> some CatalogOperationHost {
        OriginCatalogOperation(catalog: self, library: library, run: run)
    }

    private func snapshot() -> CatalogSnapshot {
        if let store { last = projection.workspaces(of: store, projection: shape) }
        return CatalogSnapshot(epoch: epoch, rev: 0, catalogID: window, versions: versions, workspaces: last, recent: recent(window))
    }
}

/// OriginCatalogOperation lends an origin window's store, hub and refusals to its receipt book for one operation.
@MainActor
final class OriginCatalogOperation: CatalogOperationHost {
    let catalog: OriginCatalog
    let library: WindowLibrary
    let run: @MainActor (ControlRequest) async -> ControlResponse

    init(catalog: OriginCatalog, library: WindowLibrary, run: @escaping @MainActor (ControlRequest) async -> ControlResponse) {
        self.catalog = catalog
        self.library = library
        self.run = run
    }

    // a window closed while the operation ran must not be saved: a reopen gives its file to a new store, a delete
    // removed it
    var operationStore: AppStore? { library.store(for: catalog.window) }
    var operationHub: CatalogHub { catalog.hub }

    /// operationRefusal refuses what reaches outside the window, what a page row cannot take, and an operation
    /// decided on panes or a scratch the row no longer has as the catalog shows it.
    func operationRefusal(_ request: ControlRequest) -> String? {
        guard let store = operationStore else { return "the window is closed" }
        if let refusal = OriginCatalogScope.refusal(request, in: store) { return refusal }
        guard let session = request.target.flatMap(UUID.init(uuidString:)).flatMap(store.session(withID:)) else { return nil }
        if let refusal = PageSessionRefusal.refusal(request, isPageSession: { _, _ in session.content == .page })?.error {
            return refusal
        }
        if let expected = request.args?.panes {
            let current = session.content == .page ? [] : CatalogProjection.identities(of: session).map(\.uuidString)
            if current != expected.map({ $0.uppercased() }) { return "the session's panes changed; take the catalog again" }
        }
        if let expected = request.args?.scratch {
            let running = session.localScratchIdentity.flatMap { catalog.projection.evidence.runs($0) ? $0 : nil }
            if (running?.uuidString.lowercased() ?? "none") != expected.lowercased() {
                return "the session's scratch changed; take the catalog again"
            }
        }
        return nil
    }

    /// runOperation runs the command as an ordinary request against this window, without the receipt fields.
    func runOperation(_ request: ControlRequest) async -> ControlResponse {
        var plain = request
        var args = plain.args ?? ControlArgs()
        (args.opID, args.epoch, args.rev, args.panes, args.scratch) = (nil, nil, nil, nil, nil)
        args.window = catalog.window.uuidString
        plain.args = args
        return await run(plain)
    }
}
