import Foundation
import Testing
@testable import agtermCore

@MainActor
final class WindowLibraryRecentClosedTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func anAttachedUndoWhoseReplyArrivesLateStillUndoesInTheOrderTheTerminatesWereAskedFor() throws {
        let library = WindowLibrary(directory: directory)
        let window = try #require(library.activeWindowID)
        let asked = Date()
        let first = AttachedUndo(host: "buildbox", undoID: "a", sessions: ["s1"], initiated: asked)
        let second = AttachedUndo(host: "buildbox", undoID: "b", sessions: ["s2"], initiated: asked.addingTimeInterval(1))
        let third = AttachedUndo(host: "buildbox", undoID: "c", sessions: ["s3"], initiated: asked.addingTimeInterval(2))

        library.noteAttachedUndo(second, window: window, grace: 60)
        library.noteAttachedUndo(third, window: window, grace: 60)
        library.noteAttachedUndo(first, window: window, grace: 60)

        #expect(library.attachedUndos[window]?.last == third)
        #expect(library.takeAttachedUndo(window: window) == third)
        #expect(library.takeAttachedUndo(window: window) == second)
        #expect(library.takeAttachedUndo(window: window) == first)
        #expect(library.attachedUndos[window] == nil)
    }

    @Test func aReopenReportsItsWindowAndConsumesTheEntry() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let windowID = try #require(library.activeWindowID)
        let workspace = store.addWorkspace(name: "project")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))
        store.closeSession(session.id)
        let recent = try #require(library.recentClosedItems.first)

        let outcome = library.reopenRecentClosedOutcome(recent.id)

        #expect(outcome == RecentClosedReopen(window: windowID, complete: true))
        #expect(store.session(withID: session.id) != nil)
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func reopeningAFinalizedWorkspaceCloseLeavesItsAttachedRowsInRecentClosed() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        _ = store.addWorkspace(name: "other")
        let workspace = store.addWorkspace(name: "work")
        let local = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/a"))
        _ = try addAttachedRow(to: store, workspace: workspace.id, origin: "o1")
        #expect(store.softRemoveWorkspace(workspace.id, grace: 3600))
        store.finalizeAllPendingCloses()
        let recent = try #require(library.recentClosedItems.first { $0.kind == .workspace })

        let outcome = library.reopenRecentClosedOutcome(recent.id)

        #expect(outcome?.complete == true)
        #expect(store.session(withID: local.id) != nil)
        #expect(library.recentClosedItems.allSatisfy { $0.id != recent.id })
        #expect(library.recentClosedStore.loadRemote().map(\.originSessionID) == ["o1"])
    }

    @Test func aReopenReportsTheWindowHoldingTheWorkspaceNotTheRequestedOne() throws {
        let library = WindowLibrary(directory: directory)
        let source = try #require(library.activeStore)
        let sourceID = try #require(library.activeWindowID)
        let workspace = source.addWorkspace(name: "project")
        let session = try #require(source.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))
        let destination = try #require(library.store(for: library.newWindow().id))
        source.closeSession(session.id)
        let recent = try #require(library.recentClosedItems.first)

        let outcome = library.reopenRecentClosedOutcome(recent.id, into: destination)

        #expect(outcome == RecentClosedReopen(window: sourceID, complete: true))
        #expect(source.session(withID: session.id) != nil)
        #expect(destination.session(withID: session.id) == nil)
    }

    @Test func aTopLevelSessionFromAClosedWindowReopensAmongTheRequestedWindowsTopLevelSessions() throws {
        let library = WindowLibrary(directory: directory)
        let source = try #require(library.activeStore)
        let sourceID = try #require(library.activeWindowID)
        let sourceRoot = try #require(source.rootWorkspace)
        let top = try #require(source.addSession(toWorkspace: sourceRoot.id, cwd: "/a"))
        let destination = try #require(library.store(for: library.newWindow().id))
        let named = destination.namedWorkspaces.map(\.name)
        source.closeSession(top.id)
        let recent = try #require(library.recentClosedItems.first)
        library.closeWindow(sourceID)

        let outcome = library.reopenRecentClosedOutcome(recent.id, into: destination)

        #expect(outcome?.complete == true)
        #expect(destination.workspace(forSession: top.id)?.id == destination.rootWorkspace?.id)
        #expect(destination.namedWorkspaces.map(\.name) == named)
    }

    @Test func anEntryWhoseRemovalCannotBeWrittenReportsIncomplete() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))
        store.closeSession(session.id)
        let recent = try #require(library.recentClosedItems.first)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let outcome = library.reopenRecentClosedOutcome(recent.id)

        #expect(outcome?.complete == false)
        #expect(store.session(withID: session.id) != nil)
        #expect(library.recentClosedItems.map(\.id) == [recent.id])
    }

    @Test func anUnknownEntryReopensNothing() {
        let library = WindowLibrary(directory: directory)

        #expect(library.reopenRecentClosedOutcome(UUID()) == nil)
    }

    @Test func reopeningAClosedParentBringsItsCompanionsBack() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/project"))
        let companion = try store.addCompanion(to: parent.id).get()
        store.closeSession(parent.id)
        let recent = try #require(library.recentClosedItems.first)

        #expect(library.reopenRecentClosedOutcome(recent.id)?.complete == true)

        let sessions = try #require(store.workspaces.first { $0.id == workspace.id }).sessions
        #expect(sessions.map(\.id) == [parent.id, companion.id])
        #expect(sessions[1].parentID == parent.id)
    }

    @Test func aLoneCompanionReopensUnderItsLiveParentWhereverItMoved() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let other = store.addWorkspace(name: "other")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/project"))
        let companion = try store.addCompanion(to: parent.id).get()
        store.closeSession(companion.id)
        store.moveSession(parent.id, toWorkspace: other.id)
        let recent = try #require(library.recentClosedItems.first)

        #expect(library.reopenRecentClosedOutcome(recent.id)?.complete == true)

        #expect(store.workspaces.first { $0.id == other.id }?.sessions.map(\.id) == [parent.id, companion.id])
        #expect(store.workspaces.first { $0.id == workspace.id }?.sessions.isEmpty == true)
    }

    @Test func aLoneCompanionOfAClosedParentReopensTheParentFirst() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/project"))
        let companion = try store.addCompanion(to: parent.id).get()
        store.closeSession(companion.id)
        store.closeSession(parent.id)
        let companionEntry = try #require(library.recentClosedItems.first { $0.session?.snapshot.id == companion.id })

        #expect(library.reopenRecentClosedOutcome(companionEntry.id)?.complete == true)

        #expect(store.workspaces.first { $0.id == workspace.id }?.sessions.map(\.id) == [parent.id, companion.id])
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func aLoneCompanionOfAParentInARemovedWorkspaceReopensThatWorkspaceFirst() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        _ = store.addWorkspace(name: "keep")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/project"))
        let companion = try store.addCompanion(to: parent.id).get()
        store.closeSession(companion.id)
        store.removeWorkspace(workspace.id)
        let companionEntry = try #require(library.recentClosedItems.first { $0.session?.snapshot.id == companion.id })

        #expect(library.reopenRecentClosedOutcome(companionEntry.id)?.complete == true)

        #expect(store.workspaces.first { $0.id == workspace.id }?.sessions.map(\.id) == [parent.id, companion.id])
        #expect(store.session(withID: companion.id)?.parentID == parent.id)
    }

    @Test func aClosedGroupWhoseRootRecordIsUnreadableReopensTheRootAsAPageWithItsCompanions() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let root = try addPageRow(to: store, workspace: workspace.id, overlay: HtmlOverlay(source: .file(path: "/tmp/root.html", grantRoot: nil)))
        let terminal = try store.addCompanion(to: root.id).get()
        let url = try #require(URL(string: "https://example.com"))
        let nested = try store.addPageCompanion(to: root.id, overlay: HtmlOverlay(source: .url(url))).get()
        store.closeSession(root.id)
        try breakRecentPage(of: root.id, in: library)
        let entry = try #require(library.recentClosedItems.first)

        #expect(library.reopenRecentClosedOutcome(entry.id)?.complete == true)

        #expect(store.workspaces.first { $0.id == workspace.id }?.sessions.map(\.id) == [root.id, terminal.id, nested.id])
        let reopened = try #require(store.session(withID: root.id))
        #expect(reopened.content == .page)
        #expect(reopened.htmlOverlay?.source == .unreadable(reason: PageSnapshot.unreadableReason))
        #expect(reopened.htmlOverlay?.loadState == .failed)
        #expect(store.session(withID: terminal.id)?.paneIdentity == terminal.paneIdentity)
        #expect(store.session(withID: nested.id)?.htmlOverlay?.source == .url(url))
        #expect(PaneIdentityInventory.identities(in: store.workspaces.flatMap(\.sessions)).contains(terminal.paneIdentity))
        #expect(store.snapshot().workspaces.first { $0.id == workspace.id }?.sessions.first?.paneIdentity == nil)
    }

    @Test func aLoneCompanionWhoseParentRecordIsUnreadableReopensTheParentFirst() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let parent = try addPageRow(to: store, workspace: workspace.id, overlay: HtmlOverlay(source: .file(path: "/tmp/root.html", grantRoot: nil)))
        let companion = try store.addCompanion(to: parent.id).get()
        store.closeSession(companion.id)
        store.closeSession(parent.id)
        try breakRecentPage(of: parent.id, in: library)
        let companionEntry = try #require(library.recentClosedItems.first { $0.session?.snapshot.id == companion.id })

        #expect(library.reopenRecentClosedOutcome(companionEntry.id)?.complete == true)

        #expect(store.workspaces.first { $0.id == workspace.id }?.sessions.map(\.id) == [parent.id, companion.id])
        #expect(store.session(withID: parent.id)?.content == .page)
        #expect(store.session(withID: parent.id)?.htmlOverlay?.source == .unreadable(reason: PageSnapshot.unreadableReason))
        #expect(store.session(withID: companion.id)?.parentID == parent.id)
        #expect(library.recentClosedItems.isEmpty)
    }

    private func breakRecentPage(of id: UUID, in library: WindowLibrary) throws {
        let file = directory.appendingPathComponent("recent-closed.json")
        var broken = 0
        func rewrite(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if object["id"] as? String == id.uuidString, object["page"] != nil {
                    object["page"] = ["url": "ftp://example.com"]
                    broken += 1
                }
                return object.mapValues(rewrite)
            }
            if let array = value as? [Any] { return array.map(rewrite) }
            return value
        }
        let json = rewrite(try JSONSerialization.jsonObject(with: Data(contentsOf: file)))
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        #expect(broken == 1)
        library.refreshRecentClosedItems()
    }

    @Test func onlyACompanionWithNoParentAnywhereLacksItsParent() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        _ = store.addWorkspace(name: "keep")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/project"))
        let companion = try store.addCompanion(to: parent.id).get()
        store.closeSession(companion.id)
        let entry = try #require(library.recentClosedItems.first { $0.session?.snapshot.id == companion.id })
        #expect(!library.recentClosedItemLacksParent(entry.id), "the parent is open")

        store.removeWorkspace(workspace.id)
        #expect(!library.recentClosedItemLacksParent(entry.id), "the parent sits in the removed workspace's entry")

        let archive = try #require(library.recentClosedItems.first { $0.kind == .workspace })
        library.recentClosedStore.remove(archive.id)
        library.refreshRecentClosedItems()
        #expect(library.recentClosedItemLacksParent(entry.id))
    }

    @Test func aLoneCompanionWithNoParentAnywhereStaysUnavailable() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/project"))
        let companion = try store.addCompanion(to: parent.id).get()
        store.closeSession(companion.id)
        store.closeSession(parent.id)
        let parentEntry = try #require(library.recentClosedItems.first { $0.session?.snapshot.id == parent.id })
        library.recentClosedStore.remove(parentEntry.id)
        library.refreshRecentClosedItems()
        let companionEntry = try #require(library.recentClosedItems.first)

        #expect(library.reopenRecentClosedOutcome(companionEntry.id) == nil)
        #expect(store.session(withID: companion.id) == nil)
        #expect(library.recentClosedItems.map(\.id) == [companionEntry.id])
    }

    @Test func aCompanionClosedBeforeItsParentConvertedReopensUnderTheFreshParent() throws {
        let c = try ConvertedAfterClose(directory: directory)
        let (library, store, workspace, task, closed) = (c.library, c.store, c.workspace, c.task, c.closed)
        let fresh = try #require(store.parent(of: task))
        let entry = try #require(library.recentClosedItems.first { $0.session?.snapshot.id == closed.id })

        #expect(library.reopenRecentClosedOutcome(entry.id)?.complete == true)

        let reopened = try #require(store.session(withID: closed.id))
        #expect(reopened.parentID == fresh.id)
        #expect(Set(store.companions(of: fresh.id).map(\.id)) == [task.id, closed.id])
        #expect(store.workspaces.first { $0.id == workspace.id }?.sessions.first?.id == fresh.id)
    }

    @Test func aCompanionOfAClosedConvertedSessionReopensUnderTheFreshParent() throws {
        let c = try ConvertedAfterClose(directory: directory)
        let (library, store, task, closed) = (c.library, c.store, c.task, c.closed)
        let fresh = try #require(store.parent(of: task))
        store.closeSession(task.id)
        let entry = try #require(library.recentClosedItems.first { $0.session?.snapshot.id == closed.id })

        #expect(library.reopenRecentClosedOutcome(entry.id)?.complete == true)

        #expect(store.session(withID: task.id)?.parentID == fresh.id)
        #expect(store.session(withID: closed.id)?.parentID == fresh.id)
        #expect(Set(store.companions(of: fresh.id).map(\.id)) == [task.id, closed.id])
    }

    @Test func aCompanionOfAConvertedSessionInAClosedGroupReopensThatGroupFirst() throws {
        let c = try ConvertedAfterClose(directory: directory)
        let (library, store, task, closed) = (c.library, c.store, c.task, c.closed)
        let fresh = try #require(store.parent(of: task))
        store.closeSession(fresh.id)
        let entry = try #require(library.recentClosedItems.first { $0.session?.snapshot.id == closed.id })
        #expect(!library.recentClosedItemLacksParent(entry.id))

        #expect(library.reopenRecentClosedOutcome(entry.id)?.complete == true)

        #expect(store.session(withID: task.id)?.parentID == fresh.id)
        #expect(store.session(withID: closed.id)?.parentID == fresh.id)
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func aCompanionOfAConvertedSessionInARemovedWorkspaceReopensThatWorkspaceFirst() throws {
        let c = try ConvertedAfterClose(directory: directory)
        let (library, store, workspace, task, closed) = (c.library, c.store, c.workspace, c.task, c.closed)
        let fresh = try #require(store.parent(of: task))
        _ = store.addWorkspace(name: "keep")
        store.removeWorkspace(workspace.id)
        let entry = try #require(library.recentClosedItems.first { $0.session?.snapshot.id == closed.id })
        #expect(!library.recentClosedItemLacksParent(entry.id))

        #expect(library.reopenRecentClosedOutcome(entry.id)?.complete == true)

        #expect(store.session(withID: task.id)?.parentID == fresh.id)
        #expect(store.session(withID: closed.id)?.parentID == fresh.id)
    }

    @Test(arguments: [false, true])
    func aLoneCompanionOfAClosedPageParentReopensThePageFirst(pageCompanion: Bool) throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let root = try addPageRow(to: store, workspace: workspace.id, overlay: HtmlOverlay(source: .file(path: "/tmp/root.html", grantRoot: nil)))
        let companion = pageCompanion
            ? try store.addPageCompanion(to: root.id, overlay: HtmlOverlay(source: .file(path: "/tmp/n.html", grantRoot: nil))).get()
            : try store.addCompanion(to: root.id).get()
        store.closeSession(companion.id)
        store.closeSession(root.id)
        let companionEntry = try #require(library.recentClosedItems.first { $0.session?.snapshot.id == companion.id })

        #expect(library.reopenRecentClosedOutcome(companionEntry.id)?.complete == true)

        #expect(store.workspaces.first { $0.id == workspace.id }?.sessions.map(\.id) == [root.id, companion.id])
        #expect(store.session(withID: root.id)?.htmlOverlay?.source == .file(path: "/tmp/root.html", grantRoot: nil))
        #expect(store.session(withID: companion.id)?.content == (pageCompanion ? .page : .terminal))
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func aClosedWindowReopensItsPageRows() throws {
        let library = WindowLibrary(directory: directory)
        let windowID = library.newWindow().id
        let store = try #require(library.store(for: windowID))
        let workspace = try #require(store.workspaces.first)
        let root = try addPageRow(to: store, workspace: workspace.id, overlay: HtmlOverlay(source: .file(path: "/tmp/root.html", grantRoot: nil)))
        let terminal = try store.addCompanion(to: root.id).get()
        store.save()
        library.closeWindow(windowID)

        let reopened = try #require(library.loadStore(for: windowID))

        #expect(reopened.companions(of: root.id).map(\.id) == [terminal.id])
        #expect(reopened.session(withID: root.id)?.htmlOverlay?.source == .file(path: "/tmp/root.html", grantRoot: nil))
    }
}

@MainActor private struct ConvertedAfterClose {
    let library: WindowLibrary
    let store: AppStore
    let workspace: Workspace
    let task: Session
    let closed: Session

    init(directory: URL) throws {
        library = WindowLibrary(directory: directory)
        store = try #require(library.activeStore)
        workspace = store.addWorkspace(name: "project")
        task = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/project"))
        closed = try store.addCompanion(to: task.id).get()
        store.closeSession(closed.id)
        _ = try store.convertToCompanion(task.id).get()
    }
}

@MainActor
final class WindowLibraryRecentClosedWindowTests {
    private let directory: URL
    private let library: WindowLibrary
    private let first: AppStore
    private let firstID: UUID
    private let second: AppStore
    private let secondID: UUID

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = WindowLibrary(directory: directory)
        first = try #require(library.activeStore)
        firstID = try #require(library.activeWindowID)
        secondID = library.newWindow().id
        second = try #require(library.store(for: secondID))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func close(in store: AppStore, workspace name: String = "project") throws -> RecentClosedItem {
        let workspace = store.addWorkspace(name: name)
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))
        store.closeSession(session.id)
        return try #require(library.recentClosedItems.first)
    }

    private func moved(_ item: RecentClosedItem, to window: UUID?) -> RecentClosedItem {
        RecentClosedItem(id: item.id, kind: item.kind, title: item.title, subtitle: item.subtitle, closedAt: item.closedAt,
                         session: item.session, workspace: item.workspace, window: window)
    }

    @Test func aCloseRecordsTheWindowThatClosedIt() throws {
        #expect(try close(in: second).window == secondID)
        #expect(try close(in: first, workspace: "other").window == firstID)
    }

    @Test func aWindowListsOnlyItsOwnEntries() throws {
        let mine = try close(in: first)
        _ = try close(in: second, workspace: "other")
        library.recentClosedStore.recordRemote(RemoteRecentClosedItem(host: "box", originSessionID: "o1", name: "remote",
            placement: .init(workspaceID: UUID(), workspaceName: "w", workspaceIndex: 0, sessionIndex: 0, parentID: nil)))

        #expect(library.recentClosedItems(inWindow: firstID).map(\.id) == [mine.id])
    }

    @Test func anEntryWithoutAWindowIsInNoWindowList() throws {
        let item = try close(in: first)
        library.recentClosedStore.record(moved(item, to: nil))
        library.refreshRecentClosedItems()

        #expect(library.recentClosedItems(inWindow: firstID).isEmpty)
        #expect(library.recentClosedItems.map(\.id) == [item.id])
    }

    @Test func aWindowClearLeavesOtherWindowsEntries() throws {
        _ = try close(in: first)
        let other = try close(in: second, workspace: "other")

        library.clearRecentClosedItems(inWindow: firstID)

        #expect(library.recentClosedItems.map(\.id) == [other.id])
    }

    @Test func aWindowReopensItsEntryIntoItself() throws {
        let item = try close(in: first)

        let reopened = try library.reopenRecentClosed(item.id, inWindow: firstID).get()

        #expect(reopened == RecentClosedReopen(window: firstID, complete: true))
        #expect(library.recentClosedItems(inWindow: firstID).isEmpty)
    }

    @Test func anEntryWhoseWorkspaceLivesInAnotherWindowIsRefused() throws {
        let item = try close(in: second)
        library.recentClosedStore.record(moved(item, to: firstID))
        library.refreshRecentClosedItems()

        #expect(library.reopenRecentClosed(item.id, inWindow: firstID) == .failure(.elsewhere))
        #expect(RecentClosedWindowRefusal.elsewhere.message
            == "the entry's workspace or parent session is in another window; reopen it from that window")
        #expect(second.workspaces.first { $0.name == "project" }?.sessions.isEmpty == true)
    }

    @Test func aCompanionWhoseParentLivesInAnotherWindowIsRefused() throws {
        let workspace = second.addWorkspace(name: "project")
        let parent = try #require(second.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))
        let companion = try second.addCompanion(to: parent.id).get()
        second.closeSession(companion.id)
        let item = try #require(library.recentClosedItems.first)
        library.recentClosedStore.record(moved(item, to: firstID))
        library.refreshRecentClosedItems()

        #expect(library.reopenRecentClosed(item.id, inWindow: firstID) == .failure(.elsewhere))
    }

    @Test func anotherWindowsEntryIsNotFound() throws {
        let item = try close(in: second)

        #expect(library.reopenRecentClosed(item.id, inWindow: firstID) == .failure(.notFound))
    }

    private func writeIndex(_ index: WindowsIndex) throws {
        try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("windows.json"))
    }

    private func writeWindowFile(_ id: UUID, _ snapshot: Snapshot) throws {
        let store = PersistenceStore(directory: directory.appendingPathComponent("windows"), fileName: "\(id.uuidString).json")
        try store.save(snapshot)
    }

    @Test func closingSessionRecordsAndReopensRecentItem() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let originalWorkspace = store.addWorkspace(name: "project")
        let first = try! #require(store.addSession(toWorkspace: originalWorkspace.id, cwd: "/first", name: "first"))
        let session = try! #require(store.addSession(toWorkspace: originalWorkspace.id, cwd: "/project", name: "api"))
        let last = try! #require(store.addSession(toWorkspace: originalWorkspace.id, cwd: "/last", name: "last"))
        _ = store.addWorkspace(name: "other")

        store.closeSession(session.id)

        let recent = try! #require(library.recentClosedItems.first)
        #expect(recent.kind == .session)
        #expect(recent.title == "api")
        #expect(recent.subtitle == originalWorkspace.name)
        #expect(store.session(withID: session.id) == nil)

        #expect(library.reopenRecentClosed(recent.id))
        let restored = try! #require(store.session(withID: session.id))
        #expect(restored.initialCwd == "/project")
        #expect(restored.customName == "api")
        let restoredWorkspace = try! #require(store.workspaces.first { $0.id == originalWorkspace.id })
        #expect(restoredWorkspace.sessions.map(\.id) == [first.id, session.id, last.id])
        #expect(store.selectedSessionID == session.id)
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func reopeningRecentSessionRecreatesMissingOriginalWorkspace() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let originalWorkspace = store.addWorkspace(name: "project")
        let session = try! #require(store.addSession(toWorkspace: originalWorkspace.id, cwd: "/project", name: "api"))

        store.closeSession(session.id)
        let recent = try! #require(library.recentClosedItems.first)
        store.removeWorkspace(originalWorkspace.id)

        #expect(library.reopenRecentClosed(recent.id))
        let restoredWorkspace = try! #require(store.workspaces.first { $0.id == originalWorkspace.id })
        #expect(restoredWorkspace.name == "project")
        #expect(restoredWorkspace.sessions.map(\.id) == [session.id])
        #expect(store.selectedSessionID == session.id)
    }

    @Test func reopeningIntoAnotherWindowRestoresWhereTheSessionIsStillPendingItsClose() {
        let library = WindowLibrary(directory: directory)
        let source = try! #require(library.activeStore)
        let workspace = source.addWorkspace(name: "project")
        let session = try! #require(source.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))
        let destination = try! #require(library.store(for: library.newWindow().id))

        #expect(source.softCloseSession(session.id))
        let recent = try! #require(library.recentClosedItems.first)
        #expect(library.reopenRecentClosed(recent.id, into: destination))

        #expect(destination.session(withID: session.id) == nil)
        let restored = try! #require(source.session(withID: session.id))
        #expect(restored === session)
        #expect(library.allOpenSessions().filter { $0.id == session.id }.count == 1)
        #expect(library.store(forSession: session.id) === source)
    }

    /// A workspace entry whose members are spread over two windows, the shape an older build could save:
    /// A holds x, B holds y, z survives only in the snapshot. `shell` gives A the entry's own workspace id
    /// so the merge takes its existing-shell arm rather than rebuilding.
    private struct SplitWorkspaceSeed {
        let a: UUID, b: UUID
        let item: RecentClosedItem
        let x: UUID, y: UUID, z: UUID
    }

    private func seedSplitWorkspace(shell: Bool) throws -> SplitWorkspaceSeed {
        let windowA = UUID(), windowB = UUID(), workspaceID = UUID()
        let x = SessionSnapshot(id: UUID(), customName: "x", cwd: "/x")
        let y = SessionSnapshot(id: UUID(), customName: "y", cwd: "/y")
        let z = SessionSnapshot(id: UUID(), customName: "z", cwd: "/z")
        try writeWindowFile(windowA, Snapshot(workspaces: [
            WorkspaceSnapshot(id: shell ? workspaceID : UUID(), name: "A", sessions: [x]),
        ]))
        try writeWindowFile(windowB, Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "B", sessions: [y]),
        ]))
        try writeIndex(WindowsIndex(frontmost: windowA, windows: [
            WindowEntry(id: windowA, name: "a", isOpen: true),
            WindowEntry(id: windowB, name: "b", isOpen: true),
        ]))
        let item = RecentClosedItem(
            kind: .workspace, title: "original", subtitle: nil,
            workspace: RecentClosedWorkspace(
                snapshot: WorkspaceSnapshot(id: workspaceID, name: "original", sessions: [x, y, z]),
                selectedSessionID: z.id))
        RecentClosedStore(directory: directory).record(item)
        return SplitWorkspaceSeed(a: windowA, b: windowB, item: item, x: x.id, y: y.id, z: z.id)
    }

    @Test(arguments: [false, true], [false, true])
    func reopeningASplitWorkspaceRebuildsOnlyTheMemberNobodyHolds(shell: Bool, externalPending: Bool) throws {
        let seed = try seedSplitWorkspace(shell: shell)
        let library = WindowLibrary(directory: directory)
        let a = try! #require(library.store(for: seed.a))
        let b = try! #require(library.store(for: seed.b))
        let originalX = try! #require(a.session(withID: seed.x))
        let originalY = try! #require(b.session(withID: seed.y))
        if externalPending { #expect(b.softCloseSession(seed.y, grace: 60)) }

        #expect(library.reopenRecentClosedReportingWindow(seed.item.id, into: a) == seed.a)

        #expect(a.session(withID: seed.x) === originalX)
        #expect(a.session(withID: seed.y) == nil, "y belongs to the other window")
        #expect(a.session(withID: seed.z) != nil, "z exists only in the snapshot and must come back")
        #expect(library.recentClosedItems.contains { $0.id == seed.item.id } == false)
        if externalPending { #expect(b.undoPendingClose()) }
        #expect(b.session(withID: seed.y) === originalY)
        for id in [seed.x, seed.y, seed.z] {
            #expect(library.allOpenSessions().filter { $0.id == id }.count == 1, "\(id) must exist once")
        }
    }

    @Test func reopeningAWorkspacePendingItsCloseRestoresTheOriginalObjects() {
        let library = WindowLibrary(directory: directory)
        let source = try! #require(library.activeStore)
        let sourceWindow = try! #require(library.windowID(for: source))
        let workspace = source.addWorkspace(name: "project")
        let session = try! #require(source.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))
        let destination = try! #require(library.store(for: library.newWindow().id))

        #expect(source.softRemoveWorkspace(workspace.id, grace: 60))
        let recent = try! #require(library.recentClosedItems.first)
        #expect(recent.kind == .workspace)
        #expect(library.reopenRecentClosedReportingWindow(recent.id, into: destination) == sourceWindow)

        #expect(destination.workspaces.contains { $0.id == workspace.id } == false)
        #expect(source.session(withID: session.id) === session)
        #expect(source.pendingHoldsWorkspace(workspace.id) == false, "the pending close is consumed")
        #expect(library.allOpenSessions().filter { $0.id == session.id }.count == 1)
    }

    @Test func reopeningAnEmptyWorkspacePendingItsCloseStillFindsItsOwner() {
        let library = WindowLibrary(directory: directory)
        let source = try! #require(library.activeStore)
        let sourceWindow = try! #require(library.windowID(for: source))
        let workspace = source.addWorkspace(name: "empty")
        let destination = try! #require(library.store(for: library.newWindow().id))

        #expect(source.softRemoveWorkspace(workspace.id, grace: 60))
        let recent = try! #require(library.recentClosedItems.first)
        // an empty entry has no session ids, so only the workspace lookup can locate the owner.
        #expect(library.reopenRecentClosedReportingWindow(recent.id, into: destination) == sourceWindow)
        #expect(source.workspaces.contains { $0.id == workspace.id })
        #expect(destination.workspaces.contains { $0.id == workspace.id } == false)
    }

    // older versions could persist the same session in two windows.
    @Test func reopeningASessionPersistedInTwoWindowsDoesNotRebuildTheClosedCopy() throws {
        let sessionID = UUID(uuidString: "2E126225-06D9-4593-A3E5-E3D69BB195C6")!
        let workspaceID = UUID(uuidString: "0C33DDDD-0000-0000-0000-000000000033")!
        let windowA = UUID(uuidString: "0A11AAAA-0000-0000-0000-000000000011")!
        let windowB = UUID(uuidString: "0B22BBBB-0000-0000-0000-000000000022")!
        let shared = SessionSnapshot(id: sessionID, customName: "api", cwd: "/project")
        try writeWindowFile(windowA, Snapshot(workspaces: [
            WorkspaceSnapshot(id: workspaceID, name: "project", sessions: [shared]),
        ]))
        try writeWindowFile(windowB, Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "elsewhere", sessions: [shared]),
        ]))
        try writeIndex(WindowsIndex(frontmost: windowA, windows: [
            WindowEntry(id: windowA, name: "a", isOpen: true),
            WindowEntry(id: windowB, name: "b", isOpen: true),
        ]))

        let library = WindowLibrary(directory: directory)
        #expect(library.allOpenSessions().filter { $0.id == sessionID }.count == 2)
        let storeA = try! #require(library.store(for: windowA))
        let storeB = try! #require(library.store(for: windowB))

        #expect(storeA.softCloseSession(sessionID, grace: 60))
        #expect(library.openStores(holdingSession: sessionID).count == 2)
        #expect(storeA.undoPendingClose())

        storeA.closeSession(sessionID)
        #expect(library.allOpenSessions().filter { $0.id == sessionID }.count == 1)

        let recent = try! #require(library.recentClosedItems.first)
        #expect(library.reopenRecentClosedReportingWindow(recent.id) == windowB)
        #expect(library.allOpenSessions().filter { $0.id == sessionID }.count == 1)
        #expect(storeA.session(withID: sessionID) == nil)
        #expect(storeB.session(withID: sessionID) != nil)
    }

    @Test func reopeningFollowsTheWorkspaceOwnerRatherThanTheRequestedWindow() {
        let library = WindowLibrary(directory: directory)
        let source = try! #require(library.activeStore)
        let sourceWindow = try! #require(library.windowID(for: source))
        let workspace = source.addWorkspace(name: "project")
        let x = try! #require(source.addSession(toWorkspace: workspace.id, cwd: "/x", name: "x"))
        _ = try! #require(source.addSession(toWorkspace: workspace.id, cwd: "/y", name: "y"))
        let destination = try! #require(library.store(for: library.newWindow().id))

        source.closeSession(x.id)
        let recent = try! #require(library.recentClosedItems.first)
        #expect(library.reopenRecentClosedReportingWindow(recent.id, into: destination) == sourceWindow)

        #expect(destination.workspaces.contains { $0.id == workspace.id } == false)
        #expect(source.session(withID: x.id) != nil)
        #expect(library.allOpenSessions().filter { $0.id == x.id }.count == 1)
    }

    @Test func reopeningAWorkspaceNobodyHoldsStillGoesToTheRequestedWindow() {
        let library = WindowLibrary(directory: directory)
        let source = try! #require(library.activeStore)
        let workspace = source.addWorkspace(name: "project")
        let x = try! #require(source.addSession(toWorkspace: workspace.id, cwd: "/x", name: "x"))
        let y = try! #require(source.addSession(toWorkspace: workspace.id, cwd: "/y", name: "y"))
        let destination = try! #require(library.store(for: library.newWindow().id))
        let destinationWindow = try! #require(library.windowID(for: destination))

        source.removeWorkspace(workspace.id)
        let recent = try! #require(library.recentClosedItems.first)
        #expect(recent.kind == .workspace)
        #expect(library.reopenRecentClosedReportingWindow(recent.id, into: destination) == destinationWindow)

        let restored = try! #require(destination.workspaces.first { $0.id == workspace.id })
        #expect(restored.sessions.map(\.id) == [x.id, y.id])
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func reopeningIntoAnotherWindowRestoresWhereTheSessionIsStillLive() {
        let library = WindowLibrary(directory: directory)
        let source = try! #require(library.activeStore)
        let workspace = source.addWorkspace(name: "project")
        let session = try! #require(source.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))
        let destination = try! #require(library.store(for: library.newWindow().id))

        source.closeSession(session.id)
        let recent = try! #require(library.recentClosedItems.first)
        #expect(source.restoreRecentClosed(recent))
        #expect(library.reopenRecentClosed(recent.id, into: destination))

        #expect(destination.session(withID: session.id) == nil)
        #expect(library.allOpenSessions().filter { $0.id == session.id }.count == 1)
    }

    @Test func reopeningStaleRecentSessionSelectsExistingSessionInsteadOfDuplicatingID() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let session = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))

        store.closeSession(session.id)
        let recent = try! #require(library.recentClosedItems.first)
        #expect(store.restoreRecentClosed(recent))
        #expect(store.restoreRecentClosed(recent))

        let matching = store.workspaces.flatMap(\.sessions).filter { $0.id == session.id }
        #expect(matching.count == 1)
        #expect(store.selectedSessionID == session.id)
    }

    @Test func closingWorkspaceRecordsAndReopensRecentItem() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let session = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))

        store.removeWorkspace(workspace.id)

        let recent = try! #require(library.recentClosedItems.first)
        #expect(recent.kind == .workspace)
        #expect(recent.title == "project")
        #expect(recent.subtitle == "1 session")
        #expect(store.workspaces.contains { $0.id == workspace.id } == false)

        #expect(library.reopenRecentClosed(recent.id))
        let restoredWorkspace = try! #require(store.workspaces.first { $0.id == workspace.id })
        #expect(restoredWorkspace.name == "project")
        #expect(restoredWorkspace.sessions.map(\.id) == [session.id])
        #expect(store.selectedSessionID == session.id)
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func reopeningStaleRecentWorkspaceSelectsExistingWorkspaceInsteadOfDuplicatingIDs() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let session = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))

        store.removeWorkspace(workspace.id)
        let recent = try! #require(library.recentClosedItems.first)
        #expect(store.restoreRecentClosed(recent))
        #expect(store.restoreRecentClosed(recent))

        let matchingWorkspaces = store.workspaces.filter { $0.id == workspace.id }
        let matchingSessions = store.workspaces.flatMap(\.sessions).filter { $0.id == session.id }
        #expect(matchingWorkspaces.count == 1)
        #expect(matchingSessions.count == 1)
        #expect(store.selectedSessionID == session.id)
    }

    @Test func theStoreHoldingASessionIsFoundWhileItsCloseCanBeUndone() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let session = try #require(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp", name: "grace"))
        #expect(library.store(holdingSession: session.id) === store)

        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(library.store(forSession: session.id) == nil)
        #expect(library.store(holdingSession: session.id) === store)

        store.finalizeAllPendingCloses()
        #expect(library.store(holdingSession: session.id) == nil)
    }

    @Test func reopeningRecentDuringGraceRestoresPendingSessionWithoutRebuildingSnapshot() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.workspaces[0]
        let session = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/grace", name: "grace"))
        let surface = SpySurface()
        session.surface = surface

        #expect(store.softCloseSession(session.id, grace: 60))
        let recent = try! #require(library.recentClosedItems.first)
        #expect(library.reopenRecentClosed(recent.id))

        let restored = try! #require(store.session(withID: session.id))
        #expect(restored === session)
        #expect(surface.teardownCount == 0)
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func graceUndoRecordsRecentAndUndoRemovesIt() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.workspaces[0]
        let undone = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/undo", name: "undo"))
        #expect(store.softCloseSession(undone.id, grace: 60))
        #expect(library.recentClosedItems.map(\.title) == ["undo"])
        #expect(store.undoPendingClose())
        #expect(library.recentClosedItems.isEmpty)

        let finalized = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/final", name: "final"))
        #expect(store.softCloseSession(finalized.id, grace: 60))
        store.finalizeAllPendingCloses()

        let recent = try! #require(library.recentClosedItems.first)
        #expect(recent.kind == .session)
        #expect(recent.title == "final")
    }

    @Test func groupedGraceUndoRestoresAllSessionsAndRemovesRecentEntries() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.workspaces[0]
        let first = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/one", name: "one"))
        let second = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/two", name: "two"))

        #expect(store.softCloseSessions([first.id, second.id], grace: 60))
        #expect(Set(library.recentClosedItems.map(\.title)) == ["one", "two"])

        #expect(store.undoPendingClose())

        #expect(store.session(withID: first.id) === first)
        #expect(store.session(withID: second.id) === second)
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func reopeningGroupedGraceSessionSelectsTheChosenRecentItem() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.workspaces[0]
        let first = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/one", name: "one"))
        let second = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/two", name: "two"))
        store.selectSession(first.id)
        #expect(store.softCloseSessions([first.id, second.id], grace: 60))
        let chosen = try! #require(library.recentClosedItems.first { $0.session?.snapshot.id == second.id })

        #expect(library.reopenRecentClosed(chosen.id))

        #expect(store.session(withID: first.id) === first)
        #expect(store.session(withID: second.id) === second)
        #expect(store.selectedSessionID == second.id)
        #expect(library.recentClosedItems.isEmpty)
    }
}
