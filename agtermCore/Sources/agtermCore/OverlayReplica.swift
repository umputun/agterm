import Foundation

/// OverlayReplica marks a viewer's overlay as the surface of a job whose program runs on the origin, reached
/// through the job's helper over ssh.
public struct OverlayReplica: Equatable, Sendable {
    public let job: String
    /// The job's ssh ended and `--wait` holds the surface on its exit prompt.
    public var ended = false
    /// The stream the job came over is gone, and no later one closes it: the surface closes when its ssh
    /// ends, held or not.
    public var orphaned = false

    public init(job: String) { self.job = job }
}

extension Session {
    /// The replica overlays on the session, with the slot each occupies.
    var overlayReplicas: [(pane: OverlayPane?, replica: OverlayReplica)] {
        var replicas: [(pane: OverlayPane?, replica: OverlayReplica)] = overlayReplica.map { [(nil, $0)] } ?? []
        for pane in OverlayPane.allCases {
            if let replica = paneOverlay(pane)?.replica { replicas.append((pane, replica)) }
        }
        return replicas
    }

    /// overlayRunsOnOrigin says whether `surface` is one of this session's overlay surfaces showing a job whose program
    /// runs on the origin, so a loopback address it prints names the origin's.
    public func overlayRunsOnOrigin(_ surface: any TerminalSurface) -> Bool {
        if overlaySurface === surface { return overlayReplica != nil }
        return paneOverlayRole(of: surface).flatMap { paneOverlay($0)?.replica } != nil
    }

    func setOverlayReplica(_ replica: OverlayReplica, pane: OverlayPane?) {
        guard let pane else {
            overlayReplica = replica
            return
        }
        var overlay = paneOverlay(pane)
        overlay?.replica = replica
        setPaneOverlay(overlay, pane: pane)
    }
}
