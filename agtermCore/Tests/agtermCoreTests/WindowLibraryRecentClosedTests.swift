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
