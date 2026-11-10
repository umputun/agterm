import Foundation
import os
import agtermCore

private let replicaLogger = Logger(subsystem: "com.umputun.agterm", category: "RemotePage")

/// ReplicaPageRecord is a page this Mac shows for an origin: whose stream it answers on, the origin's id, the
/// channel a page other than a URL page fetches through, and the last origin command it applied.
struct ReplicaPageRecord {
    let session: UUID
    let origin: UUID
    let channel: RemotePageChannel?
    var appliedSeq = 0
    /// poolUser is the ssh channel a catalog row's page holds for as long as it is shown.
    var poolUser: String?
    /// channelLost marks a page taken down because its channel ended rather than closed by anyone; the origin decides
    /// what that ends.
    var channelLost = false
    /// forward is the port forward a page on the origin's loopback is loaded through.
    var forward: PageForward?
}

extension ControlServer {
    /// showReplicaPage presents `page` for session `id`'s origin; nil when shown, otherwise the refusal reason.
    func showReplicaPage(_ page: PresentationPage, forSession id: UUID) -> String? {
        guard let store = library.store(forSession: id), let session = store.session(withID: id) else { return "no such session" }
        if case .forwarded(let address) = page.source { return showForwardedPage(page, address: address, in: store, session: session) }
        var page = page
        var argv: [String]?
        let pool = page.source.usesChannel ? catalogPool(forSession: id) : nil
        let poolUser = pool.map { _ in "page:\(page.token)" }
        let path = poolUser.flatMap { pool?.lease($0) }
        if page.source.usesChannel {
            guard let host = session.remoteHost,
                  let command = try? RemoteSession.pageServeCommand(host: host, token: page.token, controlPath: path) else {
                poolUser.map { pool?.release($0) }
                return "the origin cannot be reached for this page"
            }
            argv = command
        } else if page.persistent, let failure = HtmlOverlayRegistry.shared.persistentStoreFailure() {
            return failure
        }
        // an unsized picture is sized here, for this Mac's screen, as the origin sizes its own
        if case .image(_, let width, let height) = page.source, page.pane == nil, page.sizePercent == nil, page.points.isEmpty {
            let points = imagePoints(in: store, sessionID: id, pixels: ImagePixels(width: width, height: height))
            (page.sizePercent, page.width, page.height) = (ImagePage.basePercent, points.width, points.height)
        }
        if let reason = store.presentReplicaPage(page, forSession: id) {
            poolUser.map { pool?.release($0) }
            return reason
        }
        guard let slot = store.replicaPage(page.page, forSession: id), let origin = slot.page.replicaOf else {
            poolUser.map { pool?.release($0) }
            return "page not shown"
        }
        let local = slot.page.id
        let channel = argv.map { _ in RemotePageChannel() }
        replicaPages[local] = ReplicaPageRecord(session: id, origin: origin, channel: channel, poolUser: poolUser)
        _ = HtmlOverlayRegistry.shared.page(for: slot.page, store: store, backgroundColor: page.backgroundColor,
                                            replica: channel.map { Self.link($0) })
        if let channel, let argv {
            channel.onClose = { [weak self, weak store] in
                self?.replicaPages[local]?.channelLost = true
                store?.closeHtmlOverlay(local)
            }
            if let pool, let path {
                let launcher = pageLauncher
                Task { @MainActor [weak self] in
                    let ready = await pool.ready(path)
                    guard self?.replicaPages[local]?.channel === channel else { return }
                    guard ready else { return channel.close("no connection to \(pool.host)") }
                    channel.start(argv, launcher: launcher)
                }
            } else {
                channel.start(argv, launcher: pageLauncher)
            }
        }
        return nil
    }

    /// showForwardedPage shows a page on a headless origin's loopback at a free local port, then opens the forward
    /// that port reaches the origin through: a page the store refuses never starts one.
    private func showForwardedPage(_ page: PresentationPage, address: String, in store: AppStore, session: Session) -> String? {
        guard let host = session.remoteHost, let forwarded = ForwardedPage(address) else { return "invalid url" }
        guard let port = RemotePortForward.freePort(host: forwarded.host), let local = forwarded.url(localPort: port) else {
            return "no free local port for the page's forward"
        }
        var shown = page
        shown.source = .url(local.absoluteString)
        if let reason = store.presentReplicaPage(shown, forSession: session.id) { return reason }
        guard let slot = store.replicaPage(page.page, forSession: session.id), let origin = slot.page.replicaOf else {
            return "page not shown"
        }
        let pageID = slot.page.id
        replicaPages[pageID] = ReplicaPageRecord(session: session.id, origin: origin, channel: nil)
        _ = HtmlOverlayRegistry.shared.page(for: slot.page, store: store, backgroundColor: page.backgroundColor, replica: nil)
        let spec = forwarded.spec(localPort: port)
        let onEvent: @MainActor (PortForwardEvent) -> Void = { [weak self, weak store] event in
            guard let store, self?.replicaPages[pageID]?.forward != nil else { return }
            switch event {
            case .ready:
                if let place = store.htmlOverlaySlot(pageID) { _ = store.reloadHtmlOverlay(place.session.id, pane: place.pane) }
            case .failed(let reason): store.failHtmlOverlay(pageID, error: reason)
            }
        }
        let forward: PageForward
        if let pool = catalogPool(forSession: session.id) {
            let runner = remoteRunner
            forward = PooledForward(pool: pool, user: "forward:\(page.token)", spec: spec,
                                    runner: { await runner.run($0, deadline: 15) }, onEvent: onEvent)
        } else if let argv = try? RemoteSession.forwardCommand(host: host, spec: spec) {
            forward = RemotePortForward(argv: argv, host: forwarded.host, port: port, launcher: forwardLauncher, onEvent: onEvent)
        } else {
            store.failHtmlOverlay(pageID, error: "the port forward to \(host) cannot be started")
            return nil
        }
        replicaPages[pageID]?.forward = forward
        forward.start()
        return nil
    }

    /// replicaPageReleased tells the origin a page shown here left its slot, whatever closed it, and stops its
    /// channel. Runs once per page, from the model's release signal.
    func replicaPageReleased(_ local: UUID, origin: UUID) {
        guard let record = replicaPages.removeValue(forKey: local) else { return }
        record.forward?.stop()
        record.poolUser.map { catalogPool(forSession: record.session)?.release($0) }
        pendingReplicaStates.remove(local)
        remoteClients[record.session]?.answer(.pageClosed(PresentationPageChange(
            page: origin.uuidString, reason: record.channelLost ? PresentationPageChange.channelLost : nil)))
        record.channel?.onClose = nil
        record.channel?.close("page closed")
    }

    /// closeOriginPage takes down the page the origin closed; one it withdrew after a lost channel is reported back as
    /// that loss, since the origin still holds it.
    func closeOriginPage(_ change: PresentationPageChange, forSession id: UUID) {
        if change.reason == PresentationPageChange.channelLost,
           let local = replicaPages.first(where: { $0.value.session == id && $0.value.origin.uuidString == change.page })?.key {
            replicaPages[local]?.channelLost = true
        }
        library.store(forSession: id)?.closeReplicaPage(change.page, forSession: id)
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
        case .resize: store.resizeReplicaPage(command.page, forSession: id, sizePercent: command.sizePercent,
                                              points: command.points, merge: command.merge == true)
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

    static func link(_ channel: RemotePageChannel, ownPageCommandsLocal: Bool = false) -> HtmlReplicaLink {
        HtmlReplicaLink(
            ownPageCommandsLocal: ownPageCommandsLocal,
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
