import Foundation
import Network

/// Retries remote links when the displays wake or the network path changes; `control-api.md` says when and why.
@MainActor
final class RemoteLinkObserver {
    private let onRetry: @MainActor () -> Void
    private let monitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var reported = false

    init(watchPath: Bool = true, onRetry: @escaping @MainActor () -> Void) {
        self.onRetry = onRetry
        monitor = watchPath ? NWPathMonitor() : nil
    }

    /// Idempotent: the scene `.task` runs once per window. The wake is `SystemWakeObserver`'s bridge.
    func start() {
        guard wakeObserver == nil else { return }
        wakeObserver = NotificationCenter.default.addObserver(
            forName: .agtermScreensDidWake, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.onRetry() }
        }
        monitor?.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async { self?.pathChanged(satisfied: satisfied) }
        }
        monitor?.start(queue: DispatchQueue(label: "com.umputun.agterm.remote-link-path"))
    }

    /// The first report is the state at start, never a change.
    func pathChanged(satisfied: Bool) {
        defer { reported = true }
        if reported, satisfied { onRetry() }
    }

    isolated deinit {
        monitor?.cancel()
        if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
    }
}
