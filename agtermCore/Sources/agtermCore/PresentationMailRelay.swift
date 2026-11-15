import Foundation

/// PresentationMailRelay runs `flush` one main-queue turn after the message bus changes, once per burst of changes.
/// Deferring past the mutation lets a closing pane's identities settle before the counts are read, so no disposal
/// site needs a hook of its own. Owned by a presentation hub's owner, which publishes the counts in `flush`.
@MainActor
public final class PresentationMailRelay {
    private let bus: MessageBus
    private let flush: @MainActor () -> Void
    private var token: MessageBus.ObserverToken?
    private var scheduled = false

    public init(bus: MessageBus = .shared, flush: @escaping @MainActor () -> Void) {
        self.bus = bus
        self.flush = flush
    }

    /// start observes the bus; repeated calls keep the one registration.
    public func start() {
        guard token == nil else { return }
        token = bus.observe { [weak self] in self?.schedule() }
    }

    public func stop() {
        if let token { bus.removeObserver(token) }
        token = nil
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduled = false
                guard self.token != nil else { return }
                self.flush()
            }
        }
    }
}
