import Foundation
import Testing
@testable import agtermCore

@MainActor
final class AppStoreEventTests {
    private let directory: URL
    private let run = UUID(uuidString: "CBB5E3D0-7A9B-4C96-9EA2-18B14380DDB1")!

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func everyWindowStoreFeedsOneAppRunRingWithStampedIdentity() throws {
        let ring = ControlEventRing(runID: run, now: { Date(timeIntervalSince1970: 50) })
        let library = WindowLibrary(directory: directory, controlEventRing: ring)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))
        let firstWindow = try #require(library.windows.first)
        let firstStore = try #require(library.store(for: firstWindow.id))
        let firstWorkspace = try #require(firstStore.workspaces.first)
        let firstSession = try #require(firstWorkspace.sessions.first)

        firstStore.emitControlEvent(.status, workspace: firstWorkspace.id, session: firstSession.id,
                                    payload: ControlEventPayload(name: firstSession.displayName, status: "active"))

        let secondWindow = library.newWindow(name: "second")
        let secondStore = try #require(library.store(for: secondWindow.id))
        let secondWorkspace = try #require(secondStore.workspaces.first)
        let secondSession = try #require(secondWorkspace.sessions.first)
        secondStore.emitControlEvent(.notify, workspace: secondWorkspace.id, session: secondSession.id,
                                     payload: ControlEventPayload(name: secondSession.displayName,
                                                                  title: "done", body: "ok"))

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.status, .notify], limit: 100
        )))

        #expect(batch.run == run)
        #expect(batch.items.map(\.window) == [firstWindow.id.uuidString, secondWindow.id.uuidString])
        #expect(batch.items.map(\.workspace) == [firstWorkspace.id.uuidString, secondWorkspace.id.uuidString])
        #expect(batch.items.map(\.session) == [firstSession.id.uuidString, secondSession.id.uuidString])
    }

    @Test func runtimeCloseAndReopenKeepsCursorContinuity() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let firstWindow = try #require(library.windows.first)
        let firstStore = try #require(library.store(for: firstWindow.id))
        let firstWorkspace = try #require(firstStore.workspaces.first)
        let firstSession = try #require(firstWorkspace.sessions.first)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        firstStore.emitControlEvent(.status, workspace: firstWorkspace.id, session: firstSession.id)
        firstStore.save()
        _ = library.newWindow(name: "keep-open")
        library.closeWindow(firstWindow.id)
        let reopened = try #require(library.loadStore(for: firstWindow.id))
        let reopenedWorkspace = try #require(reopened.workspaces.first)
        let reopenedSession = try #require(reopenedWorkspace.sessions.first)
        reopened.emitControlEvent(.sessionCreated, workspace: reopenedWorkspace.id, session: reopenedSession.id)

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: nil, limit: 100
        )))

        #expect(batch.run == anchor.run)
        #expect(batch.items.map(\.seq) == [1, 2, 3, 4, 5])
        #expect(batch.items.map(\.kind) == [
            .status, .sessionCreated, .sessionClosed, .sessionCreated, .sessionCreated,
        ])
    }

    @Test func cursorFailureResponseCarriesCurrentAnchor() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let response = library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: UUID(), after: 0), kinds: nil, limit: 100
        ))

        #expect(response.ok == false)
        #expect(response.error == ControlEventReadError.runChanged.rawValue)
        let anchor = try #require(response.result?.events)
        #expect(anchor.run == run)
        #expect(anchor.items.isEmpty)
    }

    @Test func normalizedStatusChangesEmitCompletePayloadsAndIdleEdge() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)
        let session = try #require(workspace.sessions.first)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.setAgentIndicator(AgentIndicator(status: .active, statusPane: .right), forSession: session.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked, blink: true, color: "#aabbcc",
                                               statusPane: .scratch), forSession: session.id)
        store.setAgentIndicator(AgentIndicator(status: .completed), forSession: session.id)
        store.setAgentIndicator(AgentIndicator(), forSession: session.id)

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.status], limit: 100
        )))
        #expect(batch.items.map { $0.payload.status } == ["active", "blocked", "completed", "idle"])
        #expect(batch.items[0].payload.pane == "left")
        #expect(batch.items[1].payload.pane == "scratch")
        #expect(batch.items[1].payload.blink == true)
        #expect(batch.items[1].payload.color == "#aabbcc")
        #expect(batch.items.allSatisfy { $0.payload.name == session.displayName })
    }

    @Test func sameNormalizedStatusAndUnknownSessionDoNotEmit() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))
        let indicator = AgentIndicator(status: .blocked, blink: true, statusPane: .right)

        store.setAgentIndicator(indicator, forSession: session.id)
        store.setAgentIndicator(indicator, forSession: session.id)
        store.setAgentIndicator(indicator, forSession: UUID())

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.status], limit: 100
        )))
        #expect(batch.items.count == 1)
        #expect(session.statusChangedAt != nil)
    }

    @Test func autoResetVisitRoutesThroughStatusSetterAndEmitsIdle() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: session.id)
        store.selectSession(session.id)

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.status], limit: 100
        )))
        #expect(batch.items.map { $0.payload.status } == ["completed", "idle"])
    }

    @Test func notificationRecordingRequiresSessionResolutionAndUsesEffectiveTitle() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        #expect(store.recordNotificationEvent(forSession: UUID(), title: "missing", body: "no") == nil)
        let effectiveTitle = store.recordNotificationEvent(forSession: session.id, title: "", body: "tests passed")

        #expect(effectiveTitle == session.displayName)
        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.notify], limit: 100
        )))
        #expect(batch.items.count == 1)
        #expect(batch.items[0].payload.name == session.displayName)
        #expect(batch.items[0].payload.title == session.displayName)
        #expect(batch.items[0].payload.body == "tests passed")
    }

    @Test func addSoftCloseUndoAndGraceFinalizationEmitVisibleMembershipEdgesOnly() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "api"))

        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(store.undoPendingClose())
        #expect(store.softCloseSession(session.id, grace: 60))
        store.finalizeAllPendingCloses()

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next),
            kinds: [.sessionCreated, .sessionClosed], limit: 100
        )))
        #expect(batch.items.map(\.kind) == [.sessionCreated, .sessionClosed, .sessionCreated, .sessionClosed])
        #expect(batch.items.allSatisfy { $0.session == session.id.uuidString && $0.payload.name == "api" })
    }

    @Test func duplicateSessionEmitsOneCreatedEdge() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let source = try #require(store.activeSession)
        let workspace = try #require(store.workspace(forSession: source.id))
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        let duplicate = try #require(store.duplicateSession(source.id))

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.sessionCreated], limit: 100
        )))
        #expect(batch.items.map(\.session) == [duplicate.id.uuidString])
        #expect(batch.items.map(\.workspace) == [workspace.id.uuidString])
    }

    @Test func foldingPendingWorkspaceCloseDoesNotRepeatAlreadyHiddenSessionEdges() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let first = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/one", name: "one"))
        let second = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/two", name: "two"))
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        #expect(store.softCloseSession(first.id, grace: 60))
        let sessionClose = try #require(store.pendingCloseSummary?.id)
        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        #expect(store.undoPendingClose(sessionClose))
        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next),
            kinds: [.sessionCreated, .sessionClosed], limit: 100
        )))
        #expect(batch.items.map(\.kind) == [.sessionClosed, .sessionClosed, .sessionCreated, .sessionClosed])
        #expect(batch.items.map(\.session) == [
            first.id.uuidString, second.id.uuidString, first.id.uuidString, first.id.uuidString,
        ])
    }

    @Test func workspaceRemovalEmitsClosedSessionsInTreeOrder() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let workspace = store.addWorkspace(name: "batch")
        let first = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/one", name: "one"))
        let second = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/two", name: "two"))
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.removeWorkspace(workspace.id)

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.sessionClosed], limit: 100
        )))
        #expect(batch.items.map(\.session) == [first.id.uuidString, second.id.uuidString])
        #expect(batch.items.map { $0.payload.name } == ["one", "two"])
    }

    @Test func runtimeWindowCloseAndReopenEmitBalancedSessionEdges() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let window = library.newWindow(name: "runtime")
        let store = try #require(library.store(for: window.id))
        store.save()
        let session = try #require(store.activeSession)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        library.closeWindow(window.id)
        _ = try #require(library.loadStore(for: window.id))

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next),
            kinds: [.sessionCreated, .sessionClosed], limit: 100
        )))
        #expect(batch.items.map(\.kind) == [.sessionClosed, .sessionCreated])
        #expect(batch.items.map(\.session) == [session.id.uuidString, session.id.uuidString])
    }

    @Test func deletingClosedWindowStillEmitsStructuralInvalidation() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let window = library.newWindow(name: "closed")
        let store = try #require(library.store(for: window.id))
        store.save()
        library.flushTreeEvents()
        library.closeWindow(window.id)
        library.flushTreeEvents()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        library.removeWindow(window.id)
        library.flushTreeEvents()

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.treeChanged], limit: 100
        )))
        #expect(batch.items.map(\.window) == [window.id.uuidString])
    }

    @Test func deletingOpenWindowEmitsClosedEdgeAndStructuralInvalidation() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let window = library.newWindow(name: "open")
        let store = try #require(library.store(for: window.id))
        let session = try #require(store.activeSession)
        library.flushTreeEvents()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        library.removeWindow(window.id)
        library.flushTreeEvents()

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: nil, limit: 100
        )))
        #expect(batch.items.map(\.kind) == [.sessionClosed, .treeChanged])
        #expect(batch.items[0].session == session.id.uuidString)
        #expect(batch.items.allSatisfy { $0.window == window.id.uuidString })
    }

    @Test func treeChangesCoalescePerWindowAndStayIndependent() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let firstWindow = try #require(library.windows.first)
        let firstStore = try #require(library.store(for: firstWindow.id))
        let secondWindow = library.newWindow(name: "second")
        let secondStore = try #require(library.store(for: secondWindow.id))
        library.flushTreeEvents()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        let workspace = firstStore.addWorkspace(name: "one")
        firstStore.renameWorkspace(workspace.id, to: "renamed")
        _ = secondStore.addSession(toWorkspace: secondStore.workspaces[0].id, cwd: "/tmp")

        let beforeFlush = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.treeChanged], limit: 100
        )))
        #expect(beforeFlush.items.isEmpty)
        library.flushTreeEvents()
        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.treeChanged], limit: 100
        )))
        #expect(Set(batch.items.compactMap(\.window)) == Set([firstWindow.id.uuidString, secondWindow.id.uuidString]))
        #expect(batch.items.count == 2)
    }

    @Test func statusAndSelectionDoNotScheduleStructuralInvalidation() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        library.flushTreeEvents()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)
        store.selectSession(session.id)
        library.flushTreeEvents()

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.treeChanged], limit: 100
        )))
        #expect(batch.items.isEmpty)
    }

    @Test func openRecentRecreationEmitsCreatedAfterHardClose() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "recent"))
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.closeSession(session.id)
        let recent = try #require(library.recentClosedItems.first { $0.session?.snapshot.id == session.id })
        #expect(library.reopenRecentClosed(recent.id, into: store))

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next),
            kinds: [.sessionCreated, .sessionClosed], limit: 100
        )))
        #expect(batch.items.map(\.kind) == [.sessionClosed, .sessionCreated])
    }

    private func eventBatch(_ response: ControlResponse) throws -> ControlEventBatch {
        #expect(response.ok)
        return try #require(response.result?.events)
    }
}
