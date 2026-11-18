import Foundation

/// SnapshotOfferBook holds the files this host offered for viewers' `open` rules. A claim travels through
/// `session.overlay.page.serve` but never takes part in page ownership: no reservation, reoffer or page loss.
@MainActor
public final class SnapshotOfferBook {
    private struct Offer {
        let file: String
        let name: String
        let size: Int
        let created: Date
    }

    private var offers: [String: Offer] = [:]
    private var claimed: [UUID: Offer] = [:]
    private var streams: [UUID: SnapshotServeStream] = [:]
    private let clock: () -> Date

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// offer registers `file`, offered as `name` of `size` bytes, and returns the token that claims it.
    public func offer(file: String, name: String, size: Int) -> String {
        prune()
        let token = UUID().uuidString
        offers[token] = Offer(file: file, name: name, size: size, created: clock())
        return token
    }

    /// claim admits `token` once within `AppStore.pageClaimWindow` of its offer; the id names the claim to adopt.
    public func claim(_ token: String) -> UUID? {
        prune()
        guard let offer = offers.removeValue(forKey: token) else { return nil }
        let claim = UUID()
        claimed[claim] = offer
        return claim
    }

    /// adopt starts the channel of `claim` on `descriptor`; false for a claim this book does not hold.
    public func adopt(descriptor: Int32, claim: UUID) -> Bool {
        guard let offer = claimed.removeValue(forKey: claim) else { return false }
        let stream = SnapshotServeStream(descriptor: descriptor, file: offer.file, name: offer.name, size: offer.size) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.streams[claim] = nil } }
        }
        streams[claim] = stream
        stream.start()
        return true
    }

    /// drop forgets a claim whose reply never reached its helper; false for one this book does not hold.
    public func drop(claim: UUID) -> Bool {
        claimed.removeValue(forKey: claim) != nil
    }

    /// shutdown closes every channel and forgets every offer, for a host that stops serving.
    public func shutdown() {
        offers.removeAll()
        claimed.removeAll()
        for stream in streams.values { stream.shutdown() }
        streams.removeAll()
    }

    var isIdle: Bool { offers.isEmpty && claimed.isEmpty && streams.isEmpty }

    private func prune() {
        let cutoff = clock().addingTimeInterval(-AppStore.pageClaimWindow)
        offers = offers.filter { $0.value.created >= cutoff }
        claimed = claimed.filter { $0.value.created >= cutoff }
    }
}

/// SnapshotServeStream answers exactly one read of the offered file, requested by its offered name, and refuses every
/// other request by id. The reader thread never waits: a cancel applies at once and the file is read and sent on a
/// queue of its own. The viewer closes the channel once it has drained the read; a frame no viewer sends closes it.
public final class SnapshotServeStream: Sendable {
    private struct State {
        var served = false
        var active: Int?
        var cancelled = false
    }

    private let owner: ControlStreamOwner
    private let file: String
    private let name: String
    private let size: Int
    private let onClose: @Sendable () -> Void
    private let state = Locked(State())
    private let queue = DispatchQueue(label: "com.umputun.agterm.snapshot.serve")

    @MainActor
    init(descriptor: Int32, file: String, name: String, size: Int, onClose: @escaping @Sendable () -> Void) {
        owner = ControlStreamOwner(descriptor: descriptor, limits: PageServeStream.limits)
        self.file = file
        self.name = name
        self.size = size
        self.onClose = onClose
    }

    func start() {
        owner.start(onLine: { [weak self] line in self?.take(Data(line)) }, onClose: onClose)
    }

    func shutdown() {
        owner.shutdown()
    }

    private func take(_ line: Data) {
        guard let frame = try? PageServeCodec.decode(line) else { return owner.shutdown() }
        switch frame {
        case .cancel(let id):
            state.withLock { if $0.active == id { $0.cancelled = true } }
        case .resource(let id, let path):
            let admitted = state.withLock { state -> Bool in
                guard !state.served, path == name else { return false }
                state.served = true
                state.active = id
                return true
            }
            guard admitted else { return refuse(id) }
            queue.async { [self] in transfer(id) }
        case .bridge(let id, _), .logTail(let id, _):
            refuse(id)
        case .head, .chunk, .end, .failure, .reply, .logHead, .logUnchanged:
            owner.shutdown()
        }
    }

    // a viewer past the writer queue while asking for what was never offered is not reading its answers
    private func refuse(_ id: Int) {
        guard let line = try? PageServeCodec.encode(.failure(id: id, error: "not offered")), owner.send(line) else {
            return owner.shutdown()
        }
    }

    private func transfer(_ id: Int) {
        let cancelled = { [state] in state.withLock { $0.cancelled } }
        let send = { [owner] (frame: PageServeFrame) -> Bool in
            guard let line = try? PageServeCodec.encode(frame) else { return false }
            return owner.sendWaiting(line)
        }
        let data: Data
        switch BoundedFile.read(path: file, maxBytes: size) {
        case .success(let read) where read.count == size: data = read
        case .success, .failure(.tooLarge): return _ = send(.failure(id: id, error: "file changed since it was offered"))
        case .failure(.unreadable): return _ = send(.failure(id: id, error: "file cannot be read"))
        }
        guard !cancelled() else { return _ = send(.failure(id: id, error: PageServeFrame.cancelled)) }
        guard send(.head(id: id, mimeType: "application/octet-stream")) else { return }
        for start in stride(from: 0, to: data.count, by: PageServeCodec.maxChunkBytes) {
            guard !cancelled() else { return _ = send(.failure(id: id, error: PageServeFrame.cancelled)) }
            guard send(.chunk(id: id, data: data.subdata(in: start..<min(start + PageServeCodec.maxChunkBytes, data.count)))) else {
                return
            }
        }
        _ = send(.end(id: id))
    }
}
