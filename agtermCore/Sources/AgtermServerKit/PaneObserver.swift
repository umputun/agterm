import Foundation
import agtermCore

/// PaneObserver keeps the catalog in step with the daemons behind it, as a Mac's surfaces report their own exits:
/// every tick reads one `zmx list` and applies it.
@MainActor
final class PaneObserver {
    static let interval: Duration = .seconds(1)

    let store: AppStore
    let panes: ServerPanes
    let cwd: (Int32) -> String?
    /// onRespawn hears that a parent's pane runs a fresh shell under the same daemon name.
    var onRespawn: ((_ session: UUID, _ daemon: String) -> Void)?
    /// onApplied runs after each listing is settled, which is when pane lifecycle and cwd change.
    var onApplied: (() -> Void)?
    private var loop: Task<Void, Never>?

    init(store: AppStore, panes: ServerPanes, cwd: @escaping (Int32) -> String? = ProcCwd.foreground) {
        self.store = store
        self.panes = panes
        self.cwd = cwd
    }

    /// start ticks until `stop`.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// tick lists the daemons off the main actor, since that waits on zmx, and applies the listing; a listing that
    /// failed changes nothing.
    func tick() async {
        let runner = panes.runner
        let began = Date()
        guard let records = await Task.detached(operation: { try? runner.list() }).value else { return }
        apply(records, listedAt: began)
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// apply settles one complete listing taken at `listedAt`. First every listed pane is marked daemon-backed, which
    /// is how a restarted server adopts its survivors; then every missing pane leaves the set at once, and only
    /// then is each session settled, so a promotion never picks a pane that is gone too. A pane started after the
    /// listing began is skipped: it cannot be in it.
    func apply(_ records: [ZmxSessionRecord], listedAt: Date) {
        let records = panes.endUnownedScratches(records)
        let listed = Dictionary(records.map { ($0.name, $0) }) { first, _ in first }
        var missing: [(session: Session, identities: [UUID])] = []
        var leaders: [UUID: Int32] = [:]
        // a page row has no daemon, so its absence from a listing never ends it
        for session in store.workspaces.flatMap(\.sessions) where !session.ended && session.content == .terminal {
            var gone: [UUID] = []
            for (identity, role) in panesOf(session) {
                if let record = listed[ZmxSupport.daemonName(for: identity)] {
                    session.daemonBackedPanes.insert(identity)
                    leaders[identity] = record.leaderPID
                    updateCwd(of: session, role: role, leader: record.leaderPID)
                } else if !panes.started(identity, since: listedAt), !panes.restarting.contains(identity) {
                    gone.append(identity)
                }
            }
            if !gone.isEmpty { missing.append((session, gone)) }
        }
        panes.leaders = leaders
        for (session, gone) in missing { gone.forEach { session.daemonBackedPanes.remove($0) } }
        for (session, gone) in missing { settle(session, gone: gone) }
        settleScratches(listed, listedAt: listedAt)
        onApplied?()
    }

    /// settleScratches refreshes the directory of every session's listed scratch, an ended session's included, and
    /// clears one whose daemon a listing no longer holds: its shell exited or its daemon was lost.
    private func settleScratches(_ listed: [String: ZmxSessionRecord], listedAt: Date) {
        for session in store.workspaces.flatMap(\.sessions) {
            guard let scratch = session.scratchDaemon else { continue }
            if let record = listed[ZmxSupport.scratchDaemonName(for: scratch.identity)] {
                updateCwd(of: session, role: .scratch, leader: record.leaderPID)
                continue
            }
            guard !panes.started(scratch.identity, since: listedAt) else { continue }
            _ = consumeExitRecord(scratch.identity)
            panes.forgetScratch(scratch.identity)
            store.dropScratchDaemon(session.id)
        }
    }

    private func panesOf(_ session: Session) -> [(UUID, StatusPane)] {
        var result = [(session.paneIdentity, StatusPane.left)]
        if session.hasSplit, let split = session.splitPaneIdentity { result.append((split, .right)) }
        return result
    }

    /// settle ends the panes whose daemons are gone: a shell that exited closes its pane as the Mac's exit does,
    /// promoting a live split or respawning a parent; a lost daemon ends that pane alone, and a session left with no
    /// live pane after a loss stays as ended.
    private func settle(_ session: Session, gone: [UUID]) {
        let exited = gone.filter(consumeExitRecord)
        let primaryGone = gone.contains(session.paneIdentity)
        let live = panesOf(session).map(\.0).filter(session.daemonBackedPanes.contains)
        if live.isEmpty {
            guard exited.count == gone.count else {
                store.markSessionEnded(session.id)
                return
            }
            guard store.closePrimaryPane(session.id, alreadyFinalized: session.paneIdentity) == .respawned else { return }
            let workspace = store.sessionLocation(ofSession: session.id)?.workspace
            guard panes.start(.init(identity: session.paneIdentity, session: session, workspace: workspace, pane: .left,
                                    directory: session.effectiveCwd)) == nil else {
                store.markSessionEnded(session.id)
                return
            }
            onRespawn?(session.id, ZmxSupport.daemonName(for: session.paneIdentity))
            return
        }
        if primaryGone {
            _ = store.closePrimaryPane(session.id, alreadyFinalized: session.paneIdentity)
        } else if let split = session.splitPaneIdentity, gone.contains(split) {
            store.closeSplitPane(session.id, alreadyFinalized: split)
        }
    }

    /// settleExited runs the exit transition of a pane whose daemon a confirmed kill ended. zmx writes no exit record
    /// for a killed daemon, so one is written here and the pane settles as if its shell had exited.
    func settleExited(_ session: Session, identity: UUID) {
        FileManager.default.createFile(atPath: panes.exitRecord(identity), contents: nil)
        session.daemonBackedPanes.remove(identity)
        settle(session, gone: [identity])
        onApplied?()
    }

    /// consumeExitRecord reports whether `identity`'s shell exited, removing the record it read.
    private func consumeExitRecord(_ identity: UUID) -> Bool {
        let path = panes.exitRecord(identity)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        try? FileManager.default.removeItem(atPath: path)
        return true
    }

    private func updateCwd(of session: Session, role: StatusPane, leader: Int32?) {
        guard let leader, let directory = cwd(leader) else { return }
        switch role {
        case .left: if session.currentCwd != directory { session.currentCwd = directory }
        case .right: if session.splitCwd != directory { session.splitCwd = directory }
        case .scratch: if session.scratchCwd != directory { session.scratchCwd = directory }
        }
    }
}

/// ProcCwd reads a pane's working directory with no terminal to report it: the directory of the process in the
/// foreground of the shell's terminal, from `/proc`. Linux only; elsewhere there is none.
enum ProcCwd {
    static func foreground(leader: Int32) -> String? {
        #if os(Linux)
        let group = foregroundGroup(of: leader) ?? leader
        return link("/proc/\(group > 0 ? group : leader)/cwd") ?? link("/proc/\(leader)/cwd")
        #else
        return nil
        #endif
    }

    /// foregroundGroup is field 8 of `/proc/<pid>/stat`, the terminal's foreground process group; the fields are
    /// counted after the command name's closing parenthesis, since the name itself may hold spaces.
    static func foregroundGroup(of pid: Int32) -> Int32? {
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else { return nil }
        return parseForegroundGroup(stat)
    }

    static func parseForegroundGroup(_ stat: String) -> Int32? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        // after the name: state, ppid, pgrp, session, tty_nr, tpgid
        guard fields.count > 5, let group = Int32(fields[5]), group > 0 else { return nil }
        return group
    }

    private static func link(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// ProcForeground reads the argv of the program in the foreground of a pane's terminal from `/proc`, the shell
/// itself while it waits at a prompt. Linux only; elsewhere there is none.
enum ProcForeground {
    static func argv(leader: Int32) -> [String]? {
        #if os(Linux)
        let group = ProcCwd.foregroundGroup(of: leader) ?? leader
        guard let data = FileManager.default.contents(atPath: "/proc/\(group)/cmdline") else { return nil }
        return parseCmdline(data)
        #else
        return nil
        #endif
    }

    /// parseCmdline splits `/proc/<pid>/cmdline`, whose arguments each end in a NUL; nil for an empty one, which a
    /// kernel thread or a process already gone reports.
    static func parseCmdline(_ data: Data) -> [String]? {
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts.isEmpty ? nil : parts
    }
}
