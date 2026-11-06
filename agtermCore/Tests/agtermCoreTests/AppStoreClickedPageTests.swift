import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreClickedPageTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}
    }

    enum Occupant: CaseIterable {
        case shownClickedPage, hiddenPlainPage, hiddenProgram
    }

    let store: AppStore
    let session: Session

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        store = AppStore(persistence: PersistenceStore(directory: dir))
        let workspace = store.addWorkspace(name: "work")
        session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
    }

    @Test func aHiddenClickedPageIsClosedAndItsSlotFreed() throws {
        let page = try openPage(clicked: true)
        #expect(store.setOverlaysHidden(session.id, pane: nil, hidden: true) == nil)

        #expect(store.releaseHiddenClickedPage(session.id))

        #expect(!session.overlayActive)
        #expect(!session.overlayHidden)
        #expect(session.htmlOverlay == nil)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .dismissed)
    }

    @Test(arguments: Occupant.allCases)
    func anyOtherOccupantIsLeftInPlace(_ occupant: Occupant) throws {
        switch occupant {
        case .shownClickedPage:
            _ = try openPage(clicked: true)
        case .hiddenPlainPage:
            _ = try openPage(clicked: false)
            #expect(store.setOverlaysHidden(session.id, pane: nil, hidden: true) == nil)
        case .hiddenProgram:
            #expect(store.openOverlay(session.id, command: "less"))
            #expect(store.setOverlaysHidden(session.id, pane: nil, hidden: true) == nil)
        }
        let hidden = session.overlayHidden

        #expect(!store.releaseHiddenClickedPage(session.id))

        #expect(session.overlayActive)
        #expect(session.overlayHidden == hidden)
    }

    @Test func aHiddenClickedPageStaysWhenTheSlotWouldGoToThePresenter() throws {
        _ = try openPage(clicked: true)
        #expect(store.setOverlaysHidden(session.id, pane: nil, hidden: true) == nil)
        try follow(session)
        defer { ZmxLeadBook.shared.forget(pane: session.paneIdentity) }

        #expect(!store.releaseHiddenClickedPage(session.id))

        #expect(session.overlayActive)
        #expect(session.overlayHidden)
    }

    @Test func anUnknownSessionReleasesNothing() {
        #expect(!store.releaseHiddenClickedPage(UUID()))
    }

    private func openPage(clicked: Bool) throws -> HtmlOverlay {
        let page = HtmlOverlay(source: .url(try #require(URL(string: "https://example.com/pr/1"))), navigation: true,
                               javascript: true, persistent: true, browse: true, clicked: clicked)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        return page
    }

    private func follow(_ session: Session) throws {
        let hub = PresentationHub(staleTimeout: 30)
        let presenter = Sink()
        store.presentationHub = hub
        let attachment = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(attachment, pane: session.paneIdentity)
        let notice = try #require(ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):\(ZmxLeadRole.follower.rawValue):1"))
        _ = ZmxLeadBook.shared.apply(notice, pane: session.paneIdentity)
        let hello = PresentationHello(version: 1, kinds: PresentationHub.supportedKinds, mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: presenter) { PresentationSnapshot(status: nil, hud: nil) }
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        #expect(store.pageBelongsRemote(session, pane: nil))
    }
}
