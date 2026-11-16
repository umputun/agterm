import Foundation
import Observation

/// CatalogPublisher republishes one Mac window's catalog when anything it projects changes. Each publish runs the
/// hub's refresh under Observation tracking, so a change to any field the projection read schedules the next;
/// `markDirty` covers what Observation cannot see (mail counts, Recent Closed). Changes in one turn publish once.
@MainActor
public final class CatalogPublisher {
    public let hub: CatalogHub
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    private var scheduled = false

    /// `schedule` runs the coalesced publish later; the app hops through a main-actor task.
    public init(hub: CatalogHub, schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
        Task { @MainActor in work() }
    }) {
        self.hub = hub
        self.schedule = schedule
    }

    public func markDirty() {
        guard !scheduled else { return }
        scheduled = true
        schedule { [weak self] in
            self?.scheduled = false
            self?.publish()
        }
    }

    /// publish refreshes the hub now and tracks what that read; a receipt op calls it before and after it applies.
    public func publish() {
        withObservationTracking {
            hub.refresh()
        } onChange: { [weak self] in
            Task { @MainActor in self?.markDirty() }
        }
    }
}
