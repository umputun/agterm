import Foundation
import Network

/// Retries remote links the moment they can work again: when the displays wake, which a Mac a user wakes
/// posts, and when the network path turns usable after being unusable. The backoff alone can leave a Mac
/// that slept all night waiting five minutes.
@MainActor
final class RemoteLinkObserver {
    private let onRetry: @MainActor () -> Void
    private let monitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var usable: Bool?

    init(onRetry: @escaping @MainActor () -> Void) {
        self.onRetry = onRetry
    }

    /// Idempotent: the scene `.task` runs once per window. The wake is `SystemWakeObserver`'s bridge.
    func start() {
        guard wakeObserver == nil else { return }
        wakeObserver = NotificationCenter.default.addObserver(
            forName: .agtermScreensDidWake, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.onRetry() }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async { self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.umputun.agterm.remote-link-path"))
    }

    /// The first report is the state at start, never a change.
    func pathChanged(satisfied: Bool) {
        defer { usable = satisfied }
        if usable == false, satisfied { onRetry() }
    }

    isolated deinit {
        monitor.cancel()
        if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
    }
}
