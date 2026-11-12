import Foundation
import agtermCore

/// Shows a remote window's page rows: each row claims a view of its server page through `page-attach` and keeps it
/// while the catalog lists the row. A view whose channel ends is claimed again, never the row closed: only the
/// catalog removes a row.
extension ControlServer {
    /// attachCatalogPage claims a view of server page row `rowID` and shows it in that row; a claim already running
    /// for the row is left to finish, and it claims for whichever instance of the row the window holds by then.
    func attachCatalogPage(_ rowID: UUID) {
        guard catalogPageClaims.insert(rowID).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            while await claimCatalogPage(rowID) == .retry {
                await catalogPagePause()
            }
            catalogPageClaims.remove(rowID)
        }
    }

    private enum CatalogPageAttempt { case done, retry }

    /// claimCatalogPage makes one attempt for the row instance the window holds now. It is done once the page shows,
    /// the server refused it (shown as the row's failed page), or the row or its window is gone; a window not connected,
    /// an unreachable server or a row replaced during the wait is retried.
    private func claimCatalogPage(_ rowID: UUID) async -> CatalogPageAttempt {
        guard let (store, row) = catalogPageRow(rowID), let host = row.remoteHost,
              let pool = catalogPool(forSession: rowID) else { return .done }
        guard store.catalogState == .connected else {
            store.showCatalogPageRefusal("waiting for \(host)", inRow: rowID)
            return .retry
        }
        let user = "page-attach:\(rowID)"
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: ["session", "overlay", "page-attach",
                                                                                   "--target", rowID.uuidString],
                                                           controlPath: pool.lease(user)) else {
            pool.release(user)
            store.showCatalogPageRefusal("\(host) cannot be addressed", inRow: rowID)
            return .done
        }
        let result = await remoteRunner.run(argv, deadline: Self.remoteCompanionDeadline)
        pool.release(user)
        // the ssh wait lets the catalog drop, detach or replace the row
        guard let (holder, current) = catalogPageRow(rowID) else { return .done }
        guard current === row else { return .retry }
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            holder.showCatalogPageRefusal("\(host) cannot be reached, retrying", inRow: rowID)
            return .retry
        }
        guard reply.ok, let page = reply.result?.companionPage else {
            holder.showCatalogPageRefusal(reply.error ?? "\(host) did not hand the page over", inRow: rowID)
            return .done
        }
        if let refusal = catalogPageRefusal(page, host: host) {
            holder.showCatalogPageRefusal(refusal, inRow: rowID)
            return .done
        }
        showCatalogPage(page, inRow: rowID, store: holder, host: host, pool: pool)
        return .done
    }

    private func catalogPageRow(_ rowID: UUID) -> (AppStore, Session)? {
        guard let store = library.store(forSession: rowID), let row = store.session(withID: rowID), row.content == .page,
              row.remotePresentation?.binding.catalogOwned == true else { return nil }
        return (store, row)
    }

    private func catalogPageRefusal(_ page: PresentationPage, host: String) -> String? {
        if case .url(let text) = page.source, HtmlSource.isLoopback(text) {
            return "a page on \(host)'s loopback cannot be shown on this Mac"
        }
        // the server's page names no browser profile; the one used is this Mac's
        if page.persistent, let failure = HtmlOverlayRegistry.shared.persistentStoreFailure() { return failure }
        return nil
    }

    private func showCatalogPage(_ page: PresentationPage, inRow rowID: UUID, store: AppStore, host: String,
                                 pool: SshConnectionPool) {
        if let failure = store.showCatalogPage(page, inRow: rowID) {
            store.showCatalogPageRefusal(failure, inRow: rowID)
            return
        }
        let user = "page:\(page.token)"
        guard let overlay = store.session(withID: rowID)?.htmlOverlay, let origin = overlay.replicaOf,
              let serve = try? RemoteSession.pageServeCommand(host: host, token: page.token, controlPath: pool.lease(user)) else {
            pool.release(user)
            store.showCatalogPageRefusal("the page cannot be reached on \(host)", inRow: rowID)
            return
        }
        let channel = RemotePageChannel()
        let local = overlay.id
        replicaPages[local] = ReplicaPageRecord(session: rowID, origin: origin, channel: channel, poolUser: user)
        _ = HtmlOverlayRegistry.shared.page(for: overlay, store: store, backgroundColor: page.backgroundColor,
                                            replica: Self.link(channel, ownPageCommandsLocal: true))
        channel.onClose = { [weak self] in
            guard let self, let holder = library.store(forSession: rowID),
                  holder.session(withID: rowID)?.htmlOverlay?.id == local else { return }
            holder.showCatalogPageRefusal("the page's connection to \(host) ended, reconnecting", inRow: rowID)
            attachCatalogPage(rowID)
        }
        channel.start(serve, launcher: pageLauncher)
    }
}
