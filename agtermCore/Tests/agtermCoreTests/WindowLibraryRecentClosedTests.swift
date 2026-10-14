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
}
