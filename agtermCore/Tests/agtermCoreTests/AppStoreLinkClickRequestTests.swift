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

    @Test func aLocalSessionHasNothingToForward() throws {
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))

        #expect(store.linkClickRequest(click(session, pane: session.paneIdentity), originSupportsClick: true, hidden: false)
            == .failure(.notPresenter))
    }
}
