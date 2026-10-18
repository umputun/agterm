import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStorePresentationTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        var sounds: [PresentationSound] { frames.compactMap { if case .sound(let sound) = $0.body { sound } else { nil } } }
    }

    static let glass = PresentationSound(name: "Glass")

    let store = makeStore()
    let hub = PresentationHub(staleTimeout: 30)
    let presenter = Sink()
    let mirror = Sink()

    private func origin(split: Bool = true, kinds: [String] = PresentationHub.supportedKinds,
                        presented: Bool = true) throws -> Session {
        store.presentationHub = hub
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        if split { store.toggleSplit(session.id) }
        setLead(.follower, pane: session.paneIdentity)
        if let pane = session.splitPaneIdentity { setLead(.follower, pane: pane) }
        guard presented else { return session }
        let id = try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: kinds, mode: .presenter),
                                   sink: presenter) { PresentationSnapshot(status: nil, hud: nil) }
        try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: kinds, mode: .mirror),
                          sink: mirror) { PresentationSnapshot(status: nil, hud: nil) }
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        return session
    }

    private func setLead(_ role: ZmxLeadRole, pane: UUID) {
        let attachment = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(attachment, pane: pane)
        if let notice = ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):\(role.rawValue):1") {
            _ = ZmxLeadBook.shared.apply(notice, pane: pane)
        }
    }

    @Test(arguments: [nil, .left, .right] as [StatusPane?], [ZmxLeadRole.unowned, .leader, .follower])
    func aStatusSoundFollowsOnlyTheLeadOfThePaneThatSetIt(pane: StatusPane?, role: ZmxLeadRole) throws {
        let session = try origin()
        let other = try #require(session.splitPaneIdentity)
        setLead(role, pane: pane == .right ? other : session.paneIdentity)
        setLead(.leader, pane: pane == .right ? session.paneIdentity : other)

        let handed = store.presentStatusSoundRemotely(Self.glass, in: session, pane: pane)

        #expect(handed == (role == .follower))
        #expect(presenter.sounds == (handed ? [Self.glass] : []))
        #expect(mirror.sounds.isEmpty)
    }

    @Test func aScratchStatusSoundStaysLocal() throws {
        let session = try origin()

        #expect(!store.presentStatusSoundRemotely(Self.glass, in: session, pane: .scratch))
        #expect(presenter.sounds.isEmpty)
    }

    @Test func aRightPaneSoundWithoutASplitFollowsTheMainPaneLikeItsStatus() throws {
        let session = try origin(split: false)

        #expect(store.presentStatusSoundRemotely(Self.glass, in: session, pane: .right))
        #expect(presenter.sounds == [Self.glass])
    }

    @Test func aSoundStaysLocalWithoutAPresenter() throws {
        let session = try origin(presented: false)

        #expect(!store.presentStatusSoundRemotely(Self.glass, in: session, pane: nil))
    }

    @Test func aPresenterTooOldForSoundLeavesItLocal() throws {
        let session = try origin(kinds: ["status", "hud", "notify"])

        #expect(!store.presentStatusSoundRemotely(PresentationSound(name: nil), in: session, pane: nil))
        #expect(presenter.sounds.isEmpty)
    }

    @Test func aReconnectSnapshotCarriesNoSound() throws {
        let session = try origin()
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: session.id)
        let late = Sink()

        try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: PresentationHub.supportedKinds,
                                                                         mode: .presenter),
                          sink: late) { store.presentationSnapshot(forSession: session.id) }

        #expect(late.sounds.isEmpty)
        #expect(late.frames.count == 2)
    }
}
