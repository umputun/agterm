import Foundation
import os
import agtermCore

private let replicaLogger = Logger(subsystem: "com.umputun.agterm", category: "RemotePage")

/// ReplicaPageRecord is a page this Mac shows for an origin: whose stream it answers on, the origin's id, the
/// channel a file page fetches through, and the last origin command it applied.
struct ReplicaPageRecord {
    let session: UUID
    let origin: UUID
    let channel: RemotePageChannel?
    var appliedSeq = 0
}

extension ControlServer {
    /// showReplicaPage presents `page` for session `id`'s origin; nil when shown, otherwise the refusal reason.
    func showReplicaPage(_ page: PresentationPage, forSession id: UUID) -> String? {
        guard let store = library.store(forSession: id), let session = store.session(withID: id) else { return "no such session" }
        var argv: [String]?
        switch page.source {
        case .file:
            guard let host = session.remoteHost, let command = try? RemoteSession.pageServeCommand(host: host, token: page.token) else {
                return "the origin cannot be reached for this page"
            }
            argv = command
        case .url:
            if page.persistent, let failure = HtmlOverlayRegistry.shared.persistentStoreFailure() { return failure }
        }
        if let reason = store.presentReplicaPage(page, forSession: id) { return reason }
        guard let slot = store.replicaPage(page.page, forSession: id), let origin = slot.page.replicaOf else {
            return "page not shown"
        }
        let local = slot.page.id
        let channel = argv.map { _ in RemotePageChannel() }
        replicaPages[local] = ReplicaPageRecord(session: id, origin: origin, channel: channel)
        _ = HtmlOverlayRegistry.shared.page(for: slot.page, store: store, backgroundColor: page.backgroundColor,
                                            replica: channel.map(Self.link))
        if let channel, let argv {
            channel.onClose = { [weak store] in store?.closeHtmlOverlay(local) }
            channel.start(argv, launcher: pageLauncher)
        }
        return nil
    }

    /// replicaPageReleased tells the origin a page shown here left its slot, whatever closed it, and stops its
    /// channel. Runs once per page, from the model's release signal.
    func replicaPageReleased(_ local: UUID, origin: UUID) {
        guard let record = replicaPages.removeValue(forKey: local) else { return }
        pendingReplicaStates.remove(local)
        remoteClients[record.session]?.answer(.pageClosed(PresentationPageChange(page: origin.uuidString)))
        record.channel?.onClose = nil
        record.channel?.close("page closed")
    }

    /// applyReplicaPageCommand runs one origin request on the page shown for it, then reports the page's state
    /// with that request's sequence number.
    func applyReplicaPageCommand(_ command: PresentationPageCommand, forSession id: UUID) {
        guard let store = library.store(forSession: id), let slot = store.replicaPage(command.page, forSession: id) else { return }
        let local = slot.page.id
        let registry = HtmlOverlayRegistry.shared
        var refusal: String?
        switch command.action {
        case .hide, .show: store.setReplicaPageHidden(command.page, forSession: id, hidden: command.action == .hide)
        case .reloadOriginal: refusal = registry.reload(local, target: .original, store: store)?.message
        case .reloadCurrent: refusal = registry.reload(local, target: .current, store: store)?.message
        case .back: refusal = registry.navigate(local, .back)
        case .forward: refusal = registry.navigate(local, .forward)
        case .browser: refusal = registry.navigate(local, .browser)
        case .resize: store.resizeReplicaPage(command.page, forSession: id, sizePercent: command.sizePercent)
        }
        if let refusal {
            replicaLogger.notice("origin request \(command.action.rawValue, privacy: .public) not applied: \(refusal, privacy: .public)")
        }
        guard var record = replicaPages[local] else { return }
        record.appliedSeq = max(record.appliedSeq, command.seq)
        replicaPages[local] = record
        replicaPageChanged(local)
    }

    /// replicaPageChanged queues a state report for page `local`; reports are sent once per main-queue turn,
    /// the latest state of each page only.
    func replicaPageChanged(_ local: UUID) {
        guard replicaPages[local] != nil else { return }
        pendingReplicaStates.insert(local)
        guard !replicaFlushScheduled else { return }
        replicaFlushScheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flushReplicaStates() } }
    }

    private func flushReplicaStates() {
        replicaFlushScheduled = false
        let pages = pendingReplicaStates
        pendingReplicaStates.removeAll()
        for local in pages {
            guard let record = replicaPages[local], let store = library.store(forSession: record.session),
                  let state = store.replicaPageState(local, appliedSeq: record.appliedSeq) else { continue }
            remoteClients[record.session]?.answer(.pageState(state))
        }
    }

    private static func link(_ channel: RemotePageChannel) -> HtmlReplicaLink {
        HtmlReplicaLink(
            fetch: { [weak channel] path, revision in
                guard let channel else { throw RemotePageChannel.Failure.closed }
                let asked = revision.value
                return try await channel.fetch(path, current: { revision.value == asked })
            },
            bridge: { [weak channel] request in
                guard let channel else { throw RemotePageChannel.Failure.closed }
                return try await channel.bridge(request)
            })
    }
}
