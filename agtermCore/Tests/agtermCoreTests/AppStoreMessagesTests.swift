import Foundation
import Testing
@testable import agtermCore

private final class DraftCollector {
    var items: [ControlEventDraft] = []
}

@MainActor
struct AppStoreMessagesTests {
    private struct Fixture {
        let store: AppStore
        let work: Workspace
        let session: Session
    }

    private func fixture(split: Bool = false, scratch: Bool = false) throws -> Fixture {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addWorkspace(name: "other")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/w"))
        session.surface = SpySurface(paneToken: session.paneIdentity.uuidString)
        if split {
            store.setSplitVisibility(session.id, shown: true)
            let splitID = try #require(session.splitPaneIdentity)
            session.splitSurface = SpySurface(paneToken: splitID.uuidString)
        }
        if scratch { session.scratchSurface = SpySurface(paneToken: UUID().uuidString) }
        return Fixture(store: store, work: work, session: session)
    }

    private func panes(of session: Session) -> [UUID] {
        [session.paneIdentity] + [session.splitPaneIdentity].compactMap { $0 }
            + [session.scratchSurface?.paneToken].compactMap { $0.flatMap(UUID.init(uuidString:)) }
    }

    private func deliver(to panes: [UUID]) throws {
        _ = try MessageBus.shared.send("hi", from: nil, to: panes.map { MessageRecipient(pane: $0, address: "S:\($0)") }, now: 1)
    }

    private func pending(_ panes: [UUID]) -> [Int] { panes.map { MessageBus.shared.pending(for: $0) } }

    @Test func hardCloseDisposesEveryPaneOfTheSession() throws {
        let f = try fixture(split: true, scratch: true)
        let panes = panes(of: f.session)
        try deliver(to: panes)

        f.store.closeSession(f.session.id)

        #expect(panes.count == 3)
        #expect(pending(panes) == [0, 0, 0])
    }

    // mail sent before a soft close survived an undo with no bus operation between them
    @Test func softCloseDisposesAndUndoRestoresAnEmptyMailbox() throws {
        let f = try fixture(split: true)
        let panes = panes(of: f.session)
        try deliver(to: panes)

        #expect(f.store.softCloseSession(f.session.id))
        #expect(f.store.undoPendingClose())

        #expect(pending(panes) == [0, 0])
    }

    @Test func companionsLoseTheirMailWithTheirParent() throws {
        let g = try CompanionGroup()
        let companionPanes = [g.first.paneIdentity, g.second.paneIdentity]
        try deliver(to: companionPanes + [g.after.paneIdentity])

        g.store.closeSession(g.parent.id)

        #expect(pending(companionPanes) == [0, 0])
        #expect(MessageBus.shared.pending(for: g.after.paneIdentity) == 1)
        MessageBus.shared.dispose(pane: g.after.paneIdentity)
    }

    @Test(arguments: [false, true])
    func workspaceDeleteDisposesItsSessions(soft: Bool) throws {
        let f = try fixture(split: true)
        let panes = panes(of: f.session)
        try deliver(to: panes)

        if soft { #expect(f.store.softRemoveWorkspace(f.work.id)) } else { f.store.removeWorkspace(f.work.id) }

        #expect(pending(panes) == [0, 0])
    }

    @Test func splitCloseDisposesOnlyTheSplit() throws {
        let f = try fixture(split: true)
        let (main, split) = (f.session.paneIdentity, try #require(f.session.splitPaneIdentity))
        try deliver(to: [main, split])

        f.store.closeSplit(f.session.id)

        #expect(pending([main, split]) == [1, 0])
        MessageBus.shared.dispose(pane: main)
    }

    @Test func closingThePrimaryKeepsThePromotedSurvivorsMail() throws {
        let f = try fixture(split: true)
        let (main, split) = (f.session.paneIdentity, try #require(f.session.splitPaneIdentity))
        try deliver(to: [main, split])

        #expect(f.store.closePrimaryPane(f.session.id) == .promoted)

        #expect(f.session.paneIdentity == split)
        #expect(pending([main, split]) == [0, 1])
        MessageBus.shared.dispose(pane: split)
    }

    @Test func hidingASplitKeepsItsMailbox() throws {
        let f = try fixture(split: true)
        let split = try #require(f.session.splitPaneIdentity)
        try deliver(to: [split])

        f.store.setSplitVisibility(f.session.id, shown: false)

        #expect(MessageBus.shared.pending(for: split) == 1)
        MessageBus.shared.dispose(pane: split)
    }

    @Test func scratchCloseDisposesTheScratchOnly() throws {
        let f = try fixture(scratch: true)
        let scratch = try #require(f.session.scratchSurface.flatMap { UUID(uuidString: $0.paneToken) })
        try deliver(to: [f.session.paneIdentity, scratch])

        #expect(f.store.closeScratch(f.session.id))

        #expect(pending([f.session.paneIdentity, scratch]) == [1, 0])
        MessageBus.shared.dispose(pane: f.session.paneIdentity)
    }

    @Test func aRespawnedParentStartsWithAnEmptyMailbox() throws {
        let g = try CompanionGroup()
        g.parent.surface = SpySurface(paneToken: g.parent.paneIdentity.uuidString)
        try deliver(to: [g.parent.paneIdentity])

        #expect(g.store.closePrimaryPane(g.parent.id) == .respawned)

        #expect(MessageBus.shared.pending(for: g.parent.paneIdentity) == 0)
    }

    @Test func aRoleOrAPaneIDResolvesToTheLivePane() throws {
        let f = try fixture(split: true, scratch: true)
        let split = try #require(f.session.splitPaneIdentity)
        let scratch = try #require(f.session.scratchSurface.flatMap { UUID(uuidString: $0.paneToken) })
        let canonical = { MessageAddress.canonical(session: f.session.id, pane: $0) }

        #expect(f.store.messageRecipient(session: f.session.id, pane: .role(.left))
            == MessageRecipient(pane: f.session.paneIdentity, address: canonical(f.session.paneIdentity)))
        #expect(f.store.messageRecipient(session: f.session.id, pane: .role(.right))?.pane == split)
        #expect(f.store.messageRecipient(session: f.session.id, pane: .role(.scratch))?.pane == scratch)
        #expect(f.store.messageRecipient(session: f.session.id, pane: .id(split)) == MessageRecipient(pane: split, address: canonical(split)))
    }

    @Test func aPaneThatIsNotLiveInThatSessionDoesNotResolve() throws {
        let f = try fixture()
        let other = try #require(f.store.addSession(toWorkspace: f.work.id, cwd: "/o"))
        other.surface = SpySurface(paneToken: other.paneIdentity.uuidString)

        f.store.setSplitVisibility(f.session.id, shown: true)
        let hiddenSinceLaunch = try #require(f.session.splitPaneIdentity)
        #expect(f.store.messageRecipient(session: f.session.id, pane: .id(hiddenSinceLaunch)) == nil)
        #expect(f.store.messageRecipient(session: f.session.id, pane: .role(.right)) == nil)
        #expect(f.store.messageRecipient(session: f.session.id, pane: .id(other.paneIdentity)) == nil)
        #expect(f.store.messageRecipient(session: f.session.id, pane: .role(.scratch)) == nil)

        (f.session.surface as? SpySurface)?.isRealized = false
        #expect(f.store.messageRecipient(session: f.session.id, pane: .role(.left)) == nil)
    }

    @Test func aRemoteSessionHasNoMailbox() throws {
        let f = try fixture()
        let remote = try #require(f.store.addSession(toWorkspace: f.work.id, cwd: "/r", remoteHost: "buildbox"))
        remote.surface = SpySurface(paneToken: remote.paneIdentity.uuidString)

        #expect(f.store.messageRecipient(session: remote.id, pane: .role(.left)) == nil)
        #expect(f.store.messageRecipients().map(\.pane) == [f.session.paneIdentity])
    }

    @Test func broadcastListsEveryLivePaneOrOneWorkspacesPanes() throws {
        let f = try fixture(split: true, scratch: true)
        let elsewhere = try #require(f.store.addSession(toWorkspace: f.store.workspaces[1].id, cwd: "/e"))
        elsewhere.surface = SpySurface(paneToken: elsewhere.paneIdentity.uuidString)

        #expect(Set(f.store.messageRecipients().map(\.pane)) == Set(panes(of: f.session) + [elsewhere.paneIdentity]))
        #expect(f.store.messageRecipients(workspace: f.store.workspaces[1].id).map(\.pane) == [elsewhere.paneIdentity])
    }

    @Test func aQueuedMessageEmitsItsEventFromTheStoreHoldingThePane() throws {
        let drafts = DraftCollector()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: dir), controlEventSink: { drafts.items.append($0) })
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/w"))
        session.surface = SpySurface(paneToken: session.paneIdentity.uuidString)
        let recipient = try #require(store.messageRecipient(session: session.id, pane: .role(.left)))
        let id = UUID()
        drafts.items.removeAll()

        #expect(store.emitMessageQueued(id, from: "S:Q", to: recipient))
        #expect(!store.emitMessageQueued(id, from: nil, to: MessageRecipient(pane: UUID(), address: "x")))

        #expect(drafts.items == [ControlEventDraft(kind: .message, workspace: work.id.uuidString, session: session.id.uuidString,
                                                   payload: ControlEventPayload(name: session.displayName, paneID: session.paneIdentity.uuidString,
                                                                                from: "S:Q", messageID: id.uuidString))])
    }

    @Test func theTreeReportsAPanesPendingCountAndOmitsZero() throws {
        let f = try fixture(split: true)
        let split = try #require(f.session.splitPaneIdentity)
        try deliver(to: [f.session.paneIdentity, f.session.paneIdentity])

        let tree = f.store.controlTree(paneForeground: { _ in nil })
        let surfaces = try #require(tree.workspaces.flatMap(\.sessions).first { $0.id == f.session.id.uuidString }?.surfaces)

        #expect(surfaces.first { $0.kind == "left" }?.pendingMessages == 2)
        #expect(surfaces.first { $0.kind == "right" }?.pendingMessages == nil)
        MessageBus.shared.dispose(pane: f.session.paneIdentity)
        MessageBus.shared.dispose(pane: split)
    }
}
