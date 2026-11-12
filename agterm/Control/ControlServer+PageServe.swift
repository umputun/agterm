import Foundation
import UniformTypeIdentifiers
import os
import agtermCore

private let pageLogger = Logger(subsystem: "com.umputun.agterm", category: "PageServe")

/// The channels themselves are agtermCore's `PageServeHost`, shared with agterm-server; this Mac adds the walk over
/// its open stores, UTType lookup and the page registry's dispatch.
extension ControlServer: PageServeHost {
    static let pageServeLimits = PageServeStream.limits
    static let pageServeResourceLimit = PageServeStream.resourceLimit
    static let pageServeBridgeLimit = PageServeStream.bridgeLimit

    private var openStores: [AppStore] { library.openIDs().compactMap { library.store(for: $0) } }

    func claimPageServe(_ token: String) -> ControlResponse { claimPageStream(token) }

    func claimRemotePage(token: String) -> (page: UUID, served: PageServeClaim)? {
        for store in openStores {
            guard let claim = store.claimRemotePage(token: token) else { continue }
            return (claim.overlay.id, PageServeClaim(source: claim.overlay.source, links: claim.overlay.markdownLinks,
                                                     log: claim.overlay.textLog))
        }
        return nil
    }

    func dispatchPageBridge(_ request: ControlRequest) async -> ControlResponse? {
        guard let dispatch = HtmlOverlayRegistry.shared.dispatch else { return nil }
        return await dispatch(request)
    }

    nonisolated static func pageMimeType(_ path: String) -> String {
        UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// endRemotePage ends page `page` wherever its reservation sits, which also tells the presenter.
    func endRemotePage(_ page: UUID) {
        for store in openStores {
            for session in store.workspaces.flatMap(\.sessions) {
                guard let slot = session.remoteOverlays.slot(job: page.uuidString) else { continue }
                store.closeRemoteOverlay(session.id, pane: slot.pane)
                return
            }
        }
    }

    func isCurrentPageClaim(_ page: UUID, token: String) -> Bool {
        openStores.lazy.compactMap { $0.remotePageClaimToken(page) }.first == token
    }

    /// remotePagePlace finds where page `page` is reserved now, nil once it ended or its presenter changed: a swap
    /// moves the slot, and a new presenter generation means the page belongs to a stream that is gone.
    func remotePagePlace(_ page: UUID) -> (session: UUID, pane: OverlayPane?, window: UUID?)? {
        for store in openStores {
            for session in store.workspaces.flatMap(\.sessions) {
                guard let slot = session.remoteOverlays.slot(job: page.uuidString), slot.page != nil,
                      presentationHub.presenterGeneration(session: session.id) == slot.owner,
                      presentationHub.hasPresenter(session: session.id) else { continue }
                return (session.id, slot.pane, library.windowID(for: store))
            }
        }
        return nil
    }

    /// receiveRemotePageFrame hands what a presenter reported about a page to its store, logging why a page was
    /// refused, since the open was already answered ok and the reason surfaces nowhere else.
    func receiveRemotePageFrame(_ body: PresentationFrame.Body, in store: AppStore, forSession sessionID: UUID) {
        if case .pageRejected(let change) = body {
            pageLogger.notice("presenter refused page \(change.page, privacy: .public): \(change.reason ?? "no reason", privacy: .public)")
        }
        store.receiveRemotePageFrame(body, forSession: sessionID)
    }

    /// schedulePageClaimExpiry ends every channel page whose channel was not claimed in time, once `seconds` passed.
    func schedulePageClaimExpiry(after seconds: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.1) * 1_000_000_000))
            guard let self else { return }
            for store in openStores { store.expireRemotePageClaims() }
        }
    }
}
