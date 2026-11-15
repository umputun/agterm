import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreLinkClickRequestTests {
    static let remoteLeft = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let remoteRight = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!

    let store = AppStore(persistence: PersistenceStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")))

    private func attached(mode: PresentationMode = .presenter, mapSplit: Bool = true) throws -> Session {
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", remoteHost: "buildbox"))
        store.toggleSplit(session.id)
        var daemons = [session.paneIdentity: ZmxSupport.daemonName(for: Self.remoteLeft)]
        if mapSplit, let local = session.splitPaneIdentity { daemons[local] = ZmxSupport.daemonName(for: Self.remoteRight) }
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: daemons, presentationVersion: 1),
                         forSession: session.id)
        store.setRemoteMode(mode, forSession: session.id)
        return session
    }

    private func click(_ session: Session, pane: UUID?) -> RemoteLinkClick {
        RemoteLinkClick(raw: "src/a.py:3", session: session.id, pane: pane, mode: .overlay75)
    }

    @Test func aClickInAnAttachedPaneTravelsWithTheOriginsPaneIdentity() throws {
        let session = try attached()

        let left = store.linkClickRequest(click(session, pane: session.paneIdentity), originSupportsClick: true, hidden: false)
        let right = store.linkClickRequest(click(session, pane: session.splitPaneIdentity), originSupportsClick: true,
                                           hidden: false)

        #expect(try left.get() == PresentationLinkClick(raw: "src/a.py:3", pane: Self.remoteLeft, mode: .overlay75))
        #expect(try right.get().pane == Self.remoteRight)
    }

    @Test func aClickInAScratchRunningOnTheOriginTravelsWithTheScratchIdentity() throws {
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: [session.paneIdentity: ZmxSupport.daemonName(for: Self.remoteLeft)],
                                       presentationVersion: 1, catalogOwned: true), forSession: session.id)
        store.setRemoteMode(.presenter, forSession: session.id)
        let scratch = UUID()
        session.scratchDaemon = Session.ScratchDaemon(identity: scratch, shown: true)

        let request = store.linkClickRequest(click(session, pane: scratch), originSupportsClick: true, hidden: false)

        #expect(try request.get() == PresentationLinkClick(raw: "src/a.py:3", pane: scratch, mode: .overlay75))
        #expect(store.linkClickRequest(click(session, pane: scratch), originSupportsClick: false, hidden: false) == .failure(.originTooOld))
    }

    @Test func eachReasonAClickCannotTravelIsNamed() throws {
        let mirror = try attached(mode: .mirror)
        #expect(store.linkClickRequest(click(mirror, pane: mirror.paneIdentity), originSupportsClick: true, hidden: false)
            == .failure(.notPresenter))

        let session = try attached(mapSplit: false)
        let request = { (pane: UUID?, supports: Bool, hidden: Bool) in
            self.store.linkClickRequest(self.click(session, pane: pane), originSupportsClick: supports, hidden: hidden)
        }
        #expect(request(session.paneIdentity, false, false) == .failure(.originTooOld))
        #expect(request(session.paneIdentity, true, true) == .failure(.hidden))
        #expect(request(session.splitPaneIdentity, true, false) == .failure(.paneNotAttached))
        #expect(request(nil, true, false) == .failure(.paneNotAttached))
    }

    @Test func aMirrorLeadingTheClickedPaneForwardsOnlyToAnOriginTakingLeads() throws {
        let mirror = try attached(mode: .mirror)
        lead(.leader, pane: mirror.paneIdentity)
        let left = click(mirror, pane: mirror.paneIdentity)

        #expect(try store.linkClickRequest(left, originSupportsClick: true, hidden: false, originTakesLeads: true).get().pane
            == Self.remoteLeft)
        #expect(store.linkClickRequest(left, originSupportsClick: true, hidden: false) == .failure(.notPresenter))
        #expect(store.linkClickRequest(click(mirror, pane: mirror.splitPaneIdentity), originSupportsClick: true, hidden: false,
                                       originTakesLeads: true) == .failure(.notPresenter))
    }

    @Test func theLeadSetNamesOnlyOriginPanesThisMacLeads() throws {
        let session = try attached(mode: .mirror, mapSplit: false)
        #expect(store.originLeads(of: session).isEmpty)

        lead(.leader, pane: session.paneIdentity)
        lead(.leader, pane: try #require(session.splitPaneIdentity))
        #expect(store.originLeads(of: session) == [Self.remoteLeft])

        lead(.follower, pane: session.paneIdentity)
        #expect(store.originLeads(of: session).isEmpty)
    }

    @Test func aMirrorSendsSeenToItsOriginOnlyWhileItLeadsAPane() throws {
        let mirror = try attached(mode: .mirror)
        var sent: [PresentationFrame.Body] = []
        store.onOriginFrame = { _, body in
            sent.append(body)
            return true
        }

        store.markSeen(mirror.id)
        #expect(sent.isEmpty)
        lead(.leader, pane: try #require(mirror.splitPaneIdentity))
        store.markSeen(mirror.id)

        #expect(sent == [.statusSeen(PresentationSeen(reason: .viewed))])
    }

    private func lead(_ role: ZmxLeadRole, pane: UUID) {
        let attachment = ZmxLeadAttachment(claim: true)
        ZmxLeadBook.shared.begin(attachment, pane: pane)
        if let notice = ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):\(role.rawValue):1") {
            _ = ZmxLeadBook.shared.apply(notice, pane: pane)
        }
    }

    @Test func aLocalSessionHasNothingToForward() throws {
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))

        #expect(store.linkClickRequest(click(session, pane: session.paneIdentity), originSupportsClick: true, hidden: false)
            == .failure(.notPresenter))
    }
}
