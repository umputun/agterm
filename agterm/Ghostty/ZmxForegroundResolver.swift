import agtermCore
import Darwin
import Foundation
import os

/// Maps a wrapped pane's stable zmx name to the daemon-side pty foreground process group. One leader scan
/// (`ZmxClient.sessionLeaderPIDs`) populates every pane; per-pane lookups are a cached name lookup plus one sysctl.
@MainActor
final class ZmxForegroundResolver {
    enum LeaderProbe: Equatable {
        case foreground(pid_t)
        case noForeground
        case dead
    }

    typealias LeaderProvider = () -> [String: pid_t]?
    typealias Probe = (pid_t) -> LeaderProbe

    private static let logger = Logger(subsystem: "com.umputun.agterm", category: "ZmxForeground")
    private let leaderProvider: LeaderProvider
    private let leaderProbe: Probe
    private var leaders: [String: pid_t] = [:]
    private var refreshGate = ZmxRefreshGate()

    init(leaderProvider: @escaping LeaderProvider, leaderProbe: @escaping Probe = ZmxForegroundResolver.probe) {
        self.leaderProvider = leaderProvider
        self.leaderProbe = leaderProbe
    }

    func noteLifecycleChange() {
        refreshGate.noteLifecycleChange()
    }

    func refreshIfNeeded(now: Date = Date()) {
        guard refreshGate.shouldRefresh(now: now), let refreshed = leaderProvider() else { return }
        leaders = refreshed
    }

    /// A nil snapshot means the leader scan failed, and stale leaders are dropped rather than kept so no pane
    /// reports a foreground from a daemon that may be gone. Accepting either counts as a refresh.
    func acceptLeaderSnapshot(_ snapshot: [String: pid_t]?) {
        leaders = snapshot ?? [:]
        refreshGate.noteLifecycleChange()
        _ = refreshGate.shouldRefresh(now: Date())
    }

    /// cachedLeader is the leader pid the last scan found for `sessionName`, nil when it found none.
    func cachedLeader(sessionName: String) -> pid_t? { leaders[sessionName] }

    func foregroundPID(sessionName: String) -> pid_t? {
        guard let leader = leaders[sessionName] else {
            refreshGate.noteLifecycleChange()
            return nil
        }
        switch leaderProbe(leader) {
        case .foreground(let pid): return pid
        case .noForeground: return nil
        case .dead:
            leaders[sessionName] = nil
            refreshGate.noteLifecycleChange()
            Self.logger.debug("evicted dead zmx leader \(leader, privacy: .public)")
            return nil
        }
    }

    private nonisolated static func probe(_ leader: pid_t) -> LeaderProbe {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, leader]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size > 0, info.kp_proc.p_pid == leader else { return .dead }
        let foreground = info.kp_eproc.e_tpgid
        return foreground > 0 ? .foreground(foreground) : .noForeground
    }
}
