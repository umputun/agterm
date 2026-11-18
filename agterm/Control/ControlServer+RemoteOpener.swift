import Foundation
import os
import agtermCore

private let openerLogger = Logger(subsystem: "com.umputun.agterm", category: "RemoteOpener")

extension ControlServer {
    /// receiveLinkSnapshot copies the file an origin offered for a click this Mac booked, then runs the click's rule
    /// on the copy. The offer is checked before anything is fetched, and the bytes against the offered size as they
    /// arrive; an offer for no booked click, another stream or another name is dropped.
    func receiveLinkSnapshot(_ snapshot: PresentationLinkSnapshot, forSession id: UUID) {
        guard let connection = remoteConnectionIDs[id],
              let (_, rule) = remoteOpeners.accept(snapshot, connection: connection, session: id) else { return }
        let click = snapshot.click
        guard let host = library.store(forSession: id)?.session(withID: id)?.remoteHost else { return failOpener(click, session: id) }
        let pool = catalogPool(forSession: id)
        let user = "opener:\(click)"
        let path = pool.flatMap { $0.lease(user) }
        guard let argv = try? RemoteSession.pageServeCommand(host: host, token: snapshot.token, controlPath: path) else {
            pool?.release(user)
            return failOpener(click, session: id)
        }
        let channel = RemotePageChannel()
        remoteOpeners.begin(click, channel: channel) { pool?.release(user) }
        let launcher = pageLauncher
        if let pool, let path {
            Task { @MainActor [weak self] in
                let ready = await pool.ready(path)
                guard let self, remoteOpeners.transfers(click, on: channel) else { return }
                guard ready else { return failOpener(click, session: id) }
                channel.start(argv, launcher: launcher)
            }
        } else {
            channel.start(argv, launcher: launcher)
        }
        Task { @MainActor [weak self] in
            await self?.copySnapshot(snapshot, rule: rule, channel: channel, session: id, host: host)
        }
    }

    private func copySnapshot(_ snapshot: PresentationLinkSnapshot, rule: FileOpener, channel: RemotePageChannel,
                              session id: UUID, host: String) async {
        let click = snapshot.click
        let openers = remoteOpeners
        var data = Data()
        do {
            let resource = try await channel.fetch(snapshot.name) { openers.transfers(click, on: channel) }
            for try await chunk in resource.chunks {
                data.append(chunk)
                guard data.count <= snapshot.size else { throw OpenerStaging.Failure.sizeMismatch }
            }
            guard data.count == snapshot.size else { throw OpenerStaging.Failure.sizeMismatch }
        } catch {
            openerLogger.notice("snapshot of \(snapshot.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return failOpener(click, session: id)
        }
        guard openers.transfers(click, on: channel) else { return }
        openers.endTransfer(click)
        let staging = openers.staging
        let bytes = data
        let staged = await Task.detached(priority: .userInitiated) {
            Result { try staging.stage(name: snapshot.name, data: bytes, size: snapshot.size) }
        }.value
        guard case .success(let path) = staged else { return failOpener(click, session: id) }
        let surface = openers.surface(for: click)
        guard openers.finish(click), let surface else { return staging.remove(path) }
        if openers.launch(rule, URL(fileURLWithPath: path), surface, host) != nil { staging.remove(path) }
    }

    /// failOpener reports a click whose snapshot could not be copied, once, by whichever path retires it first.
    private func failOpener(_ click: UUID, session id: UUID) {
        guard remoteOpeners.finish(click) else { return }
        refuseRemoteLinkClick(.snapshotFailed, session: id)
    }

    /// tickRemoteOpeners fails the snapshots whose transfer outlived the read deadline.
    func tickRemoteOpeners() {
        for entry in remoteOpeners.overdue() { refuseRemoteLinkClick(.snapshotFailed, session: entry.session) }
    }

    /// renewOpenerConnection ends the clicks booked on `id`'s current stream, so a later stream's offers never match them,
    /// and reports each snapshot it cut off: the row stays, and nothing else answers that click.
    func renewOpenerConnection(_ id: UUID) {
        if let connection = remoteConnectionIDs[id] {
            for entry in remoteOpeners.teardown(connection: connection) {
                refuseRemoteLinkClick(.snapshotFailed, session: entry.session)
            }
        }
        remoteConnectionIDs[id] = UUID()
    }

    func endOpenerConnection(_ id: UUID) {
        guard let connection = remoteConnectionIDs.removeValue(forKey: id) else { return }
        remoteOpeners.teardown(connection: connection)
    }
}
