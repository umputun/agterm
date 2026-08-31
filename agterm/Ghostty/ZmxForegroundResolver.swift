import agtermCore
import Darwin
import Foundation
import os

/// Maps a wrapped pane's stable zmx name to the daemon-side pty foreground process group. One bounded
/// `zmx list` refresh populates every pane; per-pane lookups are a cached name lookup plus one sysctl.
@MainActor
final class ZmxForegroundResolver {
    enum LeaderProbe: Equatable {
        case foreground(pid_t)
        case noForeground
        case dead
    }

    typealias LeaderProvider = (TimeInterval?) -> [String: pid_t]?
    typealias Probe = (pid_t) -> LeaderProbe

    struct Snapshot {
        let leaders: [String: pid_t]
        let leaderProbe: Probe

        func foregroundPID(sessionName: String) -> pid_t? {
            guard let leader = leaders[sessionName] else { return nil }
            guard case .foreground(let pid) = leaderProbe(leader) else { return nil }
            return pid
        }
    }

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
        guard refreshGate.shouldRefresh(now: now), let refreshed = leaderProvider(nil) else { return }
        leaders = refreshed
    }

    func freshSnapshot(timeout: TimeInterval) -> Snapshot? {
        leaderProvider(timeout).map { Snapshot(leaders: $0, leaderProbe: leaderProbe) }
    }

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
