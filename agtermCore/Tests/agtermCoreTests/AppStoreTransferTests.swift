import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreTransferTests {
    @Test func detachReturnsInstanceWithSurfaceIntact() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let surface = SpySurface()
        session.surface = surface
        let detached = store.detachSession(session.id)
        #expect(detached === session)
        #expect(detached?.surface === surface)
        #expect(surface.teardownCount == 0)
        #expect(store.workspaces[0].sessions.isEmpty)
        #expect(store.session(withID: session.id) == nil)
    }

    @Test func detachOfSelectedSessionReselects() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let stay = store.addSession(toWorkspace: work.id, cwd: "/stay")!
        let leaving = store.addSession(toWorkspace: work.id, cwd: "/leaving")!
        #expect(store.selectedSessionID == leaving.id)
        store.detachSession(leaving.id)
        #expect(store.selectedSessionID == stay.id)
        #expect(store.sidebarSelectionIDs == [stay.id])
    }

    @Test func detachOfUnselectedSessionKeepsSelection() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let leaving = store.addSession(toWorkspace: work.id, cwd: "/leaving")!
        let selected = store.addSession(toWorkspace: work.id, cwd: "/selected")!
        store.detachSession(leaving.id)
        #expect(store.selectedSessionID == selected.id)
    }

    @Test func detachPrunesRecency() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let first = store.addSession(toWorkspace: work.id, cwd: "/first")!
        let second = store.addSession(toWorkspace: work.id, cwd: "/second")!
        store.detachSession(first.id)
        #expect(!store.sessionRecency.items.contains(first.id))
        #expect(store.sessionRecency.items.contains(second.id))
    }

    @Test func detachOfLastSessionEmptiesStore() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let only = store.addSession(toWorkspace: work.id, cwd: "/only")!
        store.detachSession(only.id)
        #expect(store.selectedSessionID == nil)
        #expect(store.sidebarSelectionIDs.isEmpty)
        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].sessions.isEmpty)
    }

    @Test func detachReselectsAcrossWorkspacesWhenOwnEmpties() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let other = store.addSession(toWorkspace: work.id, cwd: "/other")!
        let only = store.addSession(toWorkspace: personal.id, cwd: "/only")!
        store.detachSession(only.id)
        #expect(store.selectedSessionID == other.id)
        #expect(store.workspaces[1].sessions.isEmpty)
    }

    @Test func detachUnknownSessionReturnsNil() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: work.id, cwd: "/a")!
        #expect(store.detachSession(UUID()) == nil)
        #expect(store.workspaces[0].sessions.map(\.id) == [session.id])
    }

    @Test func detachEmitsTreeChanged() {
        let events = EventCollector()
        let store = makeStore(sink: events)
        let work = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: work.id, cwd: "/a")!
        events.kinds.removeAll()
        store.detachSession(session.id)
        #expect(events.kinds == [.treeChanged])
    }

    @Test func adoptLandsInCurrentWorkspaceByDefault() {
        let source = makeStore()
        let sourceWork = source.addWorkspace(name: "work")
        let session = source.addSession(toWorkspace: sourceWork.id, cwd: "/a")!
        let detached = source.detachSession(session.id)!

        let destination = makeStore()
        _ = destination.addWorkspace(name: "first")
        let second = destination.addWorkspace(name: "second")
        #expect(destination.adoptSession(detached))
        #expect(destination.workspaces[1].id == second.id)
        #expect(destination.workspaces[1].sessions.map(\.id) == [session.id])
        #expect(destination.session(withID: session.id) === session)
    }

    @Test func adoptHonorsExplicitWorkspaceAndIndex() {
        let source = makeStore()
        let sourceWork = source.addWorkspace(name: "work")
        let moving = source.detachSession(source.addSession(toWorkspace: sourceWork.id, cwd: "/moving")!.id)!

        let destination = makeStore()
        let first = destination.addWorkspace(name: "first")
        _ = destination.addWorkspace(name: "second")
        let existing = destination.addSession(toWorkspace: first.id, cwd: "/existing")!
        #expect(destination.adoptSession(moving, toWorkspace: first.id, at: 0))
        #expect(destination.workspaces[0].sessions.map(\.id) == [moving.id, existing.id])
    }

    @Test func adoptClampsOutOfRangeIndex() {
        let source = makeStore()
        let sourceWork = source.addWorkspace(name: "work")
        let moving = source.detachSession(source.addSession(toWorkspace: sourceWork.id, cwd: "/moving")!.id)!

        let destination = makeStore()
        let work = destination.addWorkspace(name: "work")
        let existing = destination.addSession(toWorkspace: work.id, cwd: "/existing")!
        #expect(destination.adoptSession(moving, toWorkspace: work.id, at: 99))
        #expect(destination.workspaces[0].sessions.map(\.id) == [existing.id, moving.id])
    }

    @Test func adoptWithSelectMakesItActive() {
        let source = makeStore()
        let sourceWork = source.addWorkspace(name: "work")
        let moving = source.detachSession(source.addSession(toWorkspace: sourceWork.id, cwd: "/moving")!.id)!

        let destination = makeStore()
        let work = destination.addWorkspace(name: "work")
        _ = destination.addSession(toWorkspace: work.id, cwd: "/existing")!
        #expect(destination.adoptSession(moving, toWorkspace: work.id, select: true))
        #expect(destination.selectedSessionID == moving.id)
        #expect(destination.sidebarSelectionIDs == [moving.id])
        #expect(destination.sessionRecency.items.first == moving.id)
    }

    @Test func adoptWithSelectClearsUnseenAndAutoResetIndicator() {
        let source = makeStore()
        let sourceWork = source.addWorkspace(name: "work")
        let session = source.addSession(toWorkspace: sourceWork.id, cwd: "/moving")!
        session.unseenCount = 3
        source.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: session.id)
        let moving = source.detachSession(session.id)!

        let destination = makeStore()
        let work = destination.addWorkspace(name: "work")
        #expect(destination.adoptSession(moving, toWorkspace: work.id, select: true))
        #expect(moving.unseenCount == 0)
        #expect(moving.agentIndicator.status == .idle)
    }

    @Test func adoptWithoutSelectKeepsUnseenBadge() {
        let source = makeStore()
        let sourceWork = source.addWorkspace(name: "work")
        let session = source.addSession(toWorkspace: sourceWork.id, cwd: "/moving")!
        session.unseenCount = 3
        let moving = source.detachSession(session.id)!

        let destination = makeStore()
        let work = destination.addWorkspace(name: "work")
        #expect(destination.adoptSession(moving, toWorkspace: work.id, select: false))
        #expect(moving.unseenCount == 3)
    }

    @Test func adoptWithoutSelectLeavesSelectionAlone() {
        let source = makeStore()
        let sourceWork = source.addWorkspace(name: "work")
        let moving = source.detachSession(source.addSession(toWorkspace: sourceWork.id, cwd: "/moving")!.id)!

        let destination = makeStore()
        let work = destination.addWorkspace(name: "work")
        let existing = destination.addSession(toWorkspace: work.id, cwd: "/existing")!
        #expect(destination.adoptSession(moving, toWorkspace: work.id, select: false))
        #expect(destination.selectedSessionID == existing.id)
        #expect(!destination.sessionRecency.items.contains(moving.id))
    }

    @Test func adoptRejectsUnknownWorkspace() {
        let source = makeStore()
        let sourceWork = source.addWorkspace(name: "work")
        let moving = source.detachSession(source.addSession(toWorkspace: sourceWork.id, cwd: "/moving")!.id)!

        let destination = makeStore()
        _ = destination.addWorkspace(name: "work")
        #expect(!destination.adoptSession(moving, toWorkspace: UUID()))
        #expect(destination.workspaces[0].sessions.isEmpty)
    }

    @Test func adoptRejectsEmptyStoreWithNoWorkspace() {
        let source = makeStore()
        let sourceWork = source.addWorkspace(name: "work")
        let moving = source.detachSession(source.addSession(toWorkspace: sourceWork.id, cwd: "/moving")!.id)!
        #expect(!makeStore().adoptSession(moving))
    }

    @Test func adoptRejectsDuplicateID() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: work.id, cwd: "/a")!
        #expect(!store.adoptSession(session, toWorkspace: work.id))
        #expect(store.workspaces[0].sessions.map(\.id) == [session.id])
    }

    @Test func adoptEmitsTreeChanged() {
        let source = makeStore()
        let sourceWork = source.addWorkspace(name: "work")
        let moving = source.detachSession(source.addSession(toWorkspace: sourceWork.id, cwd: "/moving")!.id)!

        let events = EventCollector()
        let destination = makeStore(sink: events)
        let work = destination.addWorkspace(name: "work")
        events.kinds.removeAll()
        #expect(destination.adoptSession(moving, toWorkspace: work.id))
        #expect(events.kinds == [.treeChanged])
    }
}

@MainActor
private final class EventCollector {
    var kinds: [ControlEventKind] = []
}

@MainActor private func makeStore(sink: EventCollector) -> AppStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
    return AppStore(persistence: PersistenceStore(directory: dir),
                    controlEventSink: { [sink] draft in sink.kinds.append(draft.kind) })
}
