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
        #expect(batch.items.map(\.seq) == [1, 2, 3, 4, 5, 6])
        #expect(batch.items.map(\.kind) == [
            .status, .sessionCreated, .sessionSelected, .sessionClosed, .sessionCreated, .sessionCreated,
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
                                               shape: .triangle, statusPane: .scratch), forSession: session.id)
        store.setAgentIndicator(AgentIndicator(status: .completed), forSession: session.id)
        store.setAgentIndicator(AgentIndicator(), forSession: session.id)

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.status], limit: 100
        )))
        #expect(batch.items.map { $0.payload.status } == ["active", "blocked", "completed", "idle"])
        #expect(batch.items[0].payload.pane == "left")
        #expect(batch.items[0].payload.shape == nil)
        #expect(batch.items[1].payload.pane == "scratch")
        #expect(batch.items[1].payload.blink == true)
        #expect(batch.items[1].payload.color == "#aabbcc")
        #expect(batch.items[1].payload.shape == "triangle")
        #expect(batch.items.allSatisfy { $0.payload.name == session.displayName })
    }

    @Test func shapeOnlyStatusChangeEmitsAnEventCarryingTheShape() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: session.id)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        // only the shape differs, so the `previous != indicator` guard still admits it and an event fires
        store.setAgentIndicator(AgentIndicator(status: .blocked, shape: .star), forSession: session.id)
        // the negative leg: an identical re-assert must stay silent, which breaks the moment `shape`
        // stops participating in `AgentIndicator` equality
        store.setAgentIndicator(AgentIndicator(status: .blocked, shape: .star), forSession: session.id)

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.status], limit: 100
        )))
        #expect(batch.items.count == 1)
        #expect(batch.items.first?.payload.status == "blocked")
        #expect(batch.items.first?.payload.shape == "star")
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

    @MainActor
    private final class NotifySink: PresentationSink {
        var notifies: [PresentationNotify] = []
        func offer(_ frame: PresentationFrame) -> Bool {
            if case .notify(let notify) = frame.body { notifies.append(notify) }
            return true
        }
        func close(_ reason: PresentationHub.CloseReason) {}
    }

    @Test func onlyAControlNotificationReachesAViewerAndThePublicEventIsTheSameForEveryOrigin() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        let hub = PresentationHub(staleTimeout: 30)
        store.presentationHub = hub
        let sink = NotifySink()
        try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: ["notify"], mode: .mirror),
                          sink: sink) { store.presentationSnapshot(forSession: session.id) }
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        for origin in [NotificationOrigin.terminal, .control, .mirrored] {
            store.recordNotificationEvent(forSession: session.id, title: "build", body: "done", origin: origin)
        }

        #expect(sink.notifies == [PresentationNotify(title: "build", body: "done", pane: nil, source: "control")])
        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.notify], limit: 100
        )))
        #expect(batch.items.count == 3)
        #expect(Set(batch.items.map { $0.payload.title }) == ["build"])
        #expect(Set(batch.items.map { $0.payload.body }) == ["done"])
    }

    @Test func aControlNotificationWithNoTitleTravelsWithTheEffectiveOne() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo", name: "api"))
        let hub = PresentationHub(staleTimeout: 30)
        store.presentationHub = hub
        let sink = NotifySink()
        try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: ["notify"], mode: .mirror),
                          sink: sink) { store.presentationSnapshot(forSession: session.id) }

        store.recordNotificationEvent(forSession: session.id, title: "", body: "done", origin: .control)

        #expect(sink.notifies.map(\.title) == ["api"])
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

    @Test func settingSessionContextEmitsTreeChangedOnlyWhenItActuallyChanges() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let window = library.newWindow(name: "open")
        let store = try #require(library.store(for: window.id))
        let session = try #require(store.activeSession)
        library.flushTreeEvents()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        #expect(store.setContext("PR #517", forSession: session.id) == true)
        library.flushTreeEvents()
        let afterSet = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.treeChanged], limit: 100
        )))
        #expect(afterSet.items.count == 1)

        #expect(store.setContext("PR #517", forSession: session.id) == false)
        library.flushTreeEvents()
        let afterResetToSameValue = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: afterSet.run, after: afterSet.next), kinds: [.treeChanged], limit: 100
        )))
        #expect(afterResetToSameValue.items.isEmpty)

        #expect(store.setContext(nil, forSession: session.id) == true)
        library.flushTreeEvents()
        let afterClear = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: afterSet.run, after: afterResetToSameValue.next), kinds: [.treeChanged],
            limit: 100
        )))
        #expect(afterClear.items.count == 1)

        #expect(store.setContext(nil, forSession: session.id) == false)
        library.flushTreeEvents()
        let afterSecondClear = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: afterClear.run, after: afterClear.next), kinds: [.treeChanged], limit: 100
        )))
        #expect(afterSecondClear.items.isEmpty)
        #expect(session.context == nil)
    }

    @Test func settingSessionContextWritesItToTheSavedSnapshot() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let window = library.newWindow(name: "open")
        let store = try #require(library.store(for: window.id))
        let session = try #require(store.activeSession)

        store.setContext("PR #517", forSession: session.id)

        let reloaded = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let reloadedStore = try #require(reloaded.store(for: window.id))
        let restored = try #require(reloadedStore.session(withID: session.id))
        #expect(restored.context == "PR #517")
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

    @Test func observerSeesEverySequencedEventIncludingDebouncedTreeChanges() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        library.flushTreeEvents()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))
        var observed: [ControlEvent] = []
        library.onControlEvent = { observed.append($0) }

        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)
        _ = store.addWorkspace(name: "one")
        #expect(observed.map(\.kind) == [.status])
        library.flushTreeEvents()

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: nil, limit: 100
        )))
        #expect(observed == batch.items)
        #expect(observed.map(\.kind) == [.status, .treeChanged])
    }

    @Test func statusEventsCarryThePreviousStatus() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: session.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked, shape: .star), forSession: session.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked, shape: .star), forSession: session.id)
        store.setAgentIndicator(AgentIndicator(), forSession: session.id)

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.status], limit: 100
        )))
        #expect(batch.items.map { $0.payload.status } == ["active", "blocked", "blocked", "idle"])
        #expect(batch.items.map { $0.payload.previous } == ["idle", "active", "blocked", "blocked"])
    }

    @Test func splitEventsFollowRealVisibilityTransitionsOnly() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)
        let session = try #require(store.activeSession)
        session.surface = SpySurface()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.setSplitVisibility(session.id, shown: true)
        session.splitSurface = SpySurface()
        store.setSplitVisibility(session.id, shown: true)
        store.toggleSplit(session.id, axis: .topBottom)
        store.setSplitVisibility(session.id, shown: false)
        store.closeSplit(session.id)
        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        store.closeSplitPane(session.id)
        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        store.closePrimaryPane(session.id)

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.paneSplit], limit: 100
        )))
        #expect(batch.items.map { $0.payload.status } == ["shown", "hidden", "shown", "hidden", "shown", "hidden"])
        #expect(batch.items.allSatisfy { $0.session == session.id.uuidString })
        #expect(batch.items.allSatisfy { $0.workspace == workspace.id.uuidString })
        #expect(batch.items.allSatisfy { $0.payload.name == session.displayName })
    }

    @Test func scratchTeardownAndReshowCanSuppressTheirVisibilityEvents() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        store.toggleScratch(session.id)
        session.scratchSurface = SpySurface()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        #expect(store.closeScratch(session.id, emitVisibility: false))
        store.toggleScratch(session.id, emitVisibility: false)
        #expect(session.scratchActive)

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.paneScratch], limit: 100
        )))
        #expect(batch.items.isEmpty)
    }

    @Test func promotingTheSurvivorOfAHiddenSplitEmitsNoSplitEvent() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        session.surface = SpySurface()
        store.setSplitVisibility(session.id, shown: true)
        let survivor = SpySurface()
        session.splitSurface = survivor
        store.setSplitVisibility(session.id, shown: false)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.closePrimaryPane(session.id)

        #expect(session.surface === survivor)
        #expect(session.splitSurface == nil)
        #expect(!session.hasSplit)
        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.paneSplit], limit: 100
        )))
        #expect(batch.items.isEmpty)
    }

    @Test func scratchEventsFollowRealVisibilityTransitionsOnly() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        #expect(!store.closeScratch(session.id))
        store.toggleScratch(session.id)
        session.scratchSurface = SpySurface()
        store.toggleScratch(session.id)
        #expect(store.closeScratch(session.id))
        store.toggleScratch(session.id)
        session.scratchSurface = SpySurface()
        #expect(store.closeScratch(session.id))

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.paneScratch], limit: 100
        )))
        #expect(batch.items.map { $0.payload.status } == ["shown", "hidden", "shown", "hidden"])
        #expect(batch.items.allSatisfy { $0.session == session.id.uuidString })
    }

    @Test func remoteRowEdgesRideCreatedAndClosedForRemoteSessionsOnly() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))
        let local = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "local"))
        let remote = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "far",
                                                   remoteHost: "buildbox"))

        #expect(store.softCloseSession(remote.id, grace: 60))
        #expect(store.undoPendingClose())
        #expect(store.softCloseSession(remote.id, grace: 60))
        store.finalizeAllPendingCloses()
        store.closeSession(local.id)

        let all = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: nil, limit: 100
        )))
        let remoteEdges = all.items.filter { $0.kind == .remoteOpened || $0.kind == .remoteClosed }
        #expect(remoteEdges.map(\.kind) == [.remoteOpened, .remoteClosed, .remoteOpened, .remoteClosed])
        #expect(remoteEdges.allSatisfy { $0.session == remote.id.uuidString && $0.workspace == workspace.id.uuidString })
        #expect(remoteEdges.allSatisfy { $0.payload.name == "far" && $0.payload.host == "buildbox" })
        for edge in remoteEdges {
            let sessionEdge = try #require(all.items.first { $0.seq == edge.seq - 1 })
            #expect(sessionEdge.kind == (edge.kind == .remoteOpened ? .sessionCreated : .sessionClosed))
            #expect(sessionEdge.session == remote.id.uuidString)
        }
        #expect(all.items.filter { $0.session == local.id.uuidString }.allSatisfy { $0.payload.host == nil })
    }

    @Test func remoteWorkspaceUndoThroughRecentClosedReopensTheRow() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        _ = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/tmp", name: "local"))
        let remote = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/tmp", name: "far",
                                                   remoteHost: "buildbox"))
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        let recent = try #require(library.recentClosedItems.first { $0.workspace?.snapshot.id == doomed.id })
        #expect(library.reopenRecentClosed(recent.id, into: store))
        #expect(store.session(withID: remote.id)?.remoteHost == "buildbox")

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next),
            kinds: [.remoteOpened, .remoteClosed], limit: 100
        )))
        #expect(batch.items.map(\.kind) == [.remoteClosed, .remoteOpened])
        #expect(batch.items.allSatisfy { $0.session == remote.id.uuidString && $0.payload.host == "buildbox" })
    }

    @Test func closingARemoteSplitAloneEmitsNoRemoteEdge() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)
        let remote = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "far",
                                                   remoteHost: "buildbox"))
        remote.surface = SpySurface()
        store.setSplitVisibility(remote.id, shown: true)
        remote.splitSurface = SpySurface()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.setSplitVisibility(remote.id, shown: false)
        store.closeSplit(remote.id)

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next),
            kinds: [.remoteOpened, .remoteClosed], limit: 100
        )))
        #expect(batch.items.isEmpty)
        #expect(store.session(withID: remote.id) != nil)
    }

    private func selections(_ library: WindowLibrary, after anchor: ControlEventBatch) throws -> [ControlEvent] {
        try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next),
            kinds: [.sessionCreated, .sessionClosed, .sessionSelected], limit: 100
        ))).items
    }

    @Test func selectingAnotherSessionEmitsItWithTheOneThatLostTheSelection() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)
        let first = try #require(store.activeSession)
        let second = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "api", select: false))
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.selectSession(second.id)
        store.selectSession(second.id)
        store.selectSession(nil)

        let events = try selections(library, after: anchor)
        #expect(events.map(\.kind) == [.sessionSelected, .sessionSelected])
        #expect(events[0].session == second.id.uuidString)
        #expect(events[0].workspace == workspace.id.uuidString)
        #expect(events[0].payload == ControlEventPayload(name: "api", previous: first.id.uuidString))
        #expect(events[1].session == nil)
        #expect(events[1].payload == ControlEventPayload(previous: second.id.uuidString))
    }

    @Test func aSelectedAddIsCreatedBeforeItIsSelectedAndABackgroundAddSelectsNothing() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)
        let first = try #require(store.activeSession)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        let added = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        _ = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", select: false))

        let events = try selections(library, after: anchor)
        #expect(events.map(\.kind) == [.sessionCreated, .sessionSelected, .sessionCreated])
        #expect(events[1].session == added.id.uuidString)
        #expect(events[1].payload.previous == first.id.uuidString)
    }

    @Test func closingTheSelectedSessionEmitsTheReselection() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)
        let first = try #require(store.activeSession)
        let added = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.closeSession(added.id)

        let events = try selections(library, after: anchor)
        #expect(events.map(\.kind) == [.sessionClosed, .sessionSelected])
        #expect(events[1].session == first.id.uuidString)
        #expect(events[1].payload.previous == added.id.uuidString)
    }

    @Test func reloadingAStoreFromItsSnapshotSelectsNothing() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)
        _ = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let snapshot = store.snapshot()
        store.selectSession(workspace.sessions.first?.id)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.restore(from: snapshot)

        #expect(try selections(library, after: anchor).filter { $0.kind == .sessionSelected }.isEmpty)
        #expect(store.selectedSessionID == snapshot.selectedSessionID)
    }

    // restore's closing repair of a hidden selection went through selectSession after the suppression ended
    @Test func reloadingAFlaggedViewRepairsAHiddenSelectionWithoutSelecting() throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)
        let flagged = try #require(store.activeSession)
        let plain = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", select: false))
        store.setFlag(true, forSession: flagged.id)
        store.setSidebarMode(.flagged)
        store.selectSession(plain.id)
        let snapshot = store.snapshot()
        #expect(snapshot.selectedSessionID == plain.id)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.restore(from: snapshot)

        #expect(store.selectedSessionID == flagged.id)
        #expect(try selections(library, after: anchor).filter { $0.kind == .sessionSelected }.isEmpty)
    }

    @Test func aProgramOverlayInvalidatesTheTreeOnOpenAndCloseOnly() throws {
        let (library, store, session) = try launched()

        #expect(try treeChanges(library) { store.openOverlay(session.id, command: "top") } == 1)
        #expect(try treeChanges(library) { store.openOverlay(session.id, command: "refused") } == 0)
        #expect(try treeChanges(library) { store.closeOverlay(session.id) } == 1)
        #expect(try treeChanges(library) { store.closeOverlay(session.id) } == 0)
    }

    @Test func aPaneOverlayInvalidatesTheTreeOnOpenAndCloseOnly() throws {
        let (library, store, session) = try launched()

        #expect(try treeChanges(library) { _ = store.openPaneOverlay(session.id, pane: .left, command: "top") } == 1)
        #expect(try treeChanges(library) { _ = store.openPaneOverlay(session.id, pane: .left, command: "refused") } == 0)
        #expect(try treeChanges(library) { store.closePaneOverlay(session.id, pane: .left) } == 1)
        #expect(try treeChanges(library) { store.closePaneOverlay(session.id, pane: .left) } == 0)
    }

    @Test(arguments: [nil, OverlayPane.left] as [OverlayPane?])
    func anHtmlPageInvalidatesTheTreeOnOpenAndClose(pane: OverlayPane?) throws {
        let (library, store, session) = try launched()
        let page = HtmlOverlay(source: .file(path: "/tmp/a/page.html", grantRoot: nil))

        #expect(try treeChanges(library) {
            _ = store.openHtmlOverlay(session.id, pane: pane, overlay: page, sizePercent: nil)
        } == 1)
        #expect(try treeChanges(library) {
            if let pane { store.closePaneOverlay(session.id, pane: pane) } else { store.closeOverlay(session.id) }
        } == 1)
    }

    @Test func aHudInvalidatesTheTreeOnOpenAndCloseButNotOnUpdate() throws {
        let (library, store, session) = try launched()
        let size = HudPanelSize(widthPercent: 30, heightPercent: 9)

        #expect(try treeChanges(library) {
            store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/h", size: size)
        } == 1)
        #expect(try treeChanges(library) { store.updateHud(session.id, spec: HudSpec(message: "two"), size: size) } == 0)
        #expect(try treeChanges(library) { store.closeHud(session.id) } == 1)
    }

    @Test func appLaunchedIsAppendedOncePerRunAndReachesTheHookSink() throws {
        let (library, _, _) = try launched()
        var delivered: [ControlEventKind] = []
        library.onControlEvent = { delivered.append($0.kind) }
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        library.emitAppLaunched()
        library.emitAppLaunched()

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.appLaunched], limit: 100
        )))
        let event = try #require(batch.items.first)
        #expect(batch.items.count == 1)
        #expect(event.window == nil)
        #expect(event.session == nil)
        #expect(delivered == [.appLaunched])
    }

    @Test func appLaunchedReachesTheRingWithNoObserver() throws {
        let (library, _, _) = try launched()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        library.emitAppLaunched()

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.appLaunched], limit: 100
        )))
        #expect(batch.items.count == 1)
    }

    @Test(arguments: [true, false])
    func closingASplitInvalidatesTheTreeOnlyForAPageItTakesDown(withPage: Bool) throws {
        let (library, store, session) = try launched()
        store.toggleSplit(session.id)
        if withPage { try openPage(on: .right, of: session, in: store) }

        #expect(try treeChanges(library) { store.closeSplit(session.id) } == (withPage ? 1 : 0))
        #expect(session.paneOverlay(.right) == nil)
    }

    @Test(arguments: [true, false])
    func promotingTheSplitInvalidatesTheTreeOnlyForAPageThatChangesPane(withPage: Bool) throws {
        let (library, store, session) = try launched()
        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        if withPage { try openPage(on: .right, of: session, in: store) }

        #expect(try treeChanges(library) { store.closePrimaryPane(session.id) } == (withPage ? 1 : 0))
        #expect((session.paneOverlay(.left) != nil) == withPage)
    }

    @Test(arguments: [true, false])
    func swappingPanesInvalidatesTheTreeOnlyForAPageThatChangesPane(withPage: Bool) throws {
        let (library, store, session) = try launched()
        session.surface = SpySurface()
        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        if withPage { try openPage(on: .left, of: session, in: store) }

        #expect(try treeChanges(library) { store.swapPanes(session.id) } == (withPage ? 1 : 0))
        #expect((session.paneOverlay(.right) != nil) == withPage)
    }

    @Test func aLaunchThatWasNotReadyNeverEmitsAppLaunchedLater() throws {
        let (library, _, _) = try launched()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        library.emitAppLaunched(ready: false)
        library.emitAppLaunched()

        let batch = try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.appLaunched], limit: 100
        )))
        #expect(batch.items.isEmpty)
    }

    @Test func paneSelectionMovesEmitEachSettledPaneWithItsToken() async throws {
        let (library, store, session) = try splitSession()
        let workspace = try #require(store.workspace(forSession: session.id))
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        session.splitFocused = false
        await settlePaneFocus(store)
        session.splitFocused = true
        await settlePaneFocus(store)

        let events = try paneFocusEvents(library, after: anchor)
        #expect(events.map(\.payload.pane) == ["left", "right"])
        #expect(events.map(\.payload.paneID) == ["primary-token", "split-token"])
        #expect(events.allSatisfy { $0.session == session.id.uuidString })
        #expect(events.allSatisfy { $0.workspace == workspace.id.uuidString })
        #expect(events.allSatisfy { $0.payload.name == session.displayName })
        #expect(events.allSatisfy { $0.payload.previous == nil })
    }

    @Test func openingANewSplitEmitsTheNewPane() async throws {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        session.surface = SpySurface(paneToken: "primary-token")
        await settlePaneFocus(store)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.setSplitVisibility(session.id, shown: true)
        await settlePaneFocus(store)

        let events = try paneFocusEvents(library, after: anchor)
        #expect(events.map(\.payload.pane) == ["right"])
        #expect(events.map(\.payload.paneID) == [nil])
    }

    @Test func aBurstReturningToTheSettledPaneEmitsNothing() async throws {
        let (library, store, session) = try splitSession()
        await settlePaneFocus(store)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        session.splitFocused = false
        DispatchQueue.main.async { MainActor.assumeIsolated { session.splitFocused = true } }
        await drainMainQueue()
        await settlePaneFocus(store)

        #expect(try paneFocusEvents(library, after: anchor).isEmpty)
        #expect(session.focusedPane == .right)
    }

    @Test func swapsAndSameValueWritesEmitNothing() async throws {
        let (library, store, session) = try splitSession()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        #expect(store.swapPanes(session.id) == nil)
        await settlePaneFocus(store)
        session.splitFocused = session.splitFocused
        await settlePaneFocus(store)
        store.setSplitVisibility(session.id, shown: false)
        store.setSplitVisibility(session.id, shown: true)
        await settlePaneFocus(store)

        #expect(try paneFocusEvents(library, after: anchor).isEmpty)
    }

    @Test func closingTheSelectedSplitEmitsThePrimary() async throws {
        let (library, store, session) = try splitSession()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.closeSplit(session.id)
        await settlePaneFocus(store)

        let events = try paneFocusEvents(library, after: anchor)
        #expect(events.map(\.payload.pane) == ["left"])
        #expect(events.map(\.payload.paneID) == ["primary-token"])
    }

    @Test func promotingTheSelectedSurvivorEmitsNothing() async throws {
        let (library, store, session) = try splitSession()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.closePrimaryPane(session.id)
        await settlePaneFocus(store)

        #expect(try paneFocusEvents(library, after: anchor).isEmpty)
    }

    @Test func promotingAfterThePrimaryExitsEmitsTheSurvivor() async throws {
        let (library, store, session) = try splitSession()
        session.splitFocused = false
        await settlePaneFocus(store)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.closePrimaryPane(session.id)
        await settlePaneFocus(store)

        let events = try paneFocusEvents(library, after: anchor)
        #expect(events.map(\.payload.pane) == ["left"])
        #expect(events.map(\.payload.paneID) == ["split-token"])
    }

    @Test func aReloadIsNotASelectionButALaterFlipIs() async throws {
        let (library, store, session) = try splitSession()
        session.splitFocused = false
        let leftSelected = store.snapshot()
        session.splitFocused = true
        await settlePaneFocus(store)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        store.restore(from: leftSelected)
        await settlePaneFocus(store)
        let restored = try #require(store.session(withID: session.id))
        #expect(restored.focusedPane == .left)
        restored.splitFocused = true
        await settlePaneFocus(store)

        let events = try paneFocusEvents(library, after: anchor)
        #expect(events.map(\.payload.pane) == ["right"])
        #expect(events.map(\.session) == [session.id.uuidString])
    }

    @Test func aSessionNewToTheStoreOnlyJoinsTheBaseline() async throws {
        let (library, store, _) = try splitSession()
        let workspace = try #require(store.workspaces.first)
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))

        let added = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        await settlePaneFocus(store)

        #expect(try paneFocusEvents(library, after: anchor).isEmpty)
        #expect(store.paneFocusBaseline[added.id] == added.paneIdentity)
    }

    /// A shown split with the right pane selected and both surfaces carrying tokens, its selection settled.
    private func splitSession() throws -> (WindowLibrary, AppStore, Session) {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.activeSession)
        session.surface = SpySurface(paneToken: "primary-token")
        store.setSplitVisibility(session.id, shown: true)
        session.splitSurface = SpySurface(paneToken: "split-token")
        store.emitPaneFocusChanges()
        return (library, store, session)
    }

    /// Runs the observer's queued hop, which arms the debounce, then fires the debounce.
    private func settlePaneFocus(_ store: AppStore) async {
        await drainMainQueue()
        store.paneFocusDebouncer.flush()
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func paneFocusEvents(_ library: WindowLibrary, after anchor: ControlEventBatch) throws -> [ControlEvent] {
        try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.paneFocused], limit: 100
        ))).items
    }

    private func openPage(on pane: OverlayPane, of session: Session, in store: AppStore) throws {
        let page = HtmlOverlay(source: .file(path: "/tmp/a/page.html", grantRoot: nil))
        try #require(store.openHtmlOverlay(session.id, pane: pane, overlay: page, sizePercent: nil) == nil)
    }

    private func launched() throws -> (WindowLibrary, AppStore, Session) {
        let library = WindowLibrary(directory: directory, controlEventRing: ControlEventRing(runID: run))
        let store = try #require(library.activeStore)
        let session = try #require(store.workspaces.first?.sessions.first)
        return (library, store, session)
    }

    private func treeChanges(_ library: WindowLibrary, during action: () -> Void) throws -> Int {
        library.flushTreeEvents()
        let anchor = try eventBatch(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100)))
        action()
        library.flushTreeEvents()
        return try eventBatch(library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.treeChanged], limit: 100
        ))).items.count
    }

    private func eventBatch(_ response: ControlResponse) throws -> ControlEventBatch {
        #expect(response.ok)
        return try #require(response.result?.events)
    }
}
