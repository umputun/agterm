import Foundation
import Testing
@testable import agtermCore

@MainActor
final class WindowLibraryRestartTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agts-restart-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test func restartCountsCountsLocalTerminalRows() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.store(for: library.windows[0].id))
        let workspace = try #require(store.workspaces.first)
        _ = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let counts = library.restartCounts()
        #expect(counts.localSessions == 2)
        #expect(!counts.remote)
    }

    @Test func restartCountsSkipsAPageRow() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.store(for: library.windows[0].id))
        let workspace = try #require(store.workspaces.first)
        _ = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/page", content: .page))
        #expect(library.restartCounts().localSessions == 1)
    }

    @Test func restartCountsKeepsAPageTerminalCompanion() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.store(for: library.windows[0].id))
        let workspace = try #require(store.workspaces.first)
        let shell = try #require(workspace.sessions.first)
        let page = try store.addPageSession(after: shell.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))).get()
        _ = try store.addCompanion(to: page.id).get()
        #expect(library.restartCounts().localSessions == 2)
    }

    @Test func restartCountsMarksAnAttachedRowRemote() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.store(for: library.windows[0].id))
        let workspace = try #require(store.workspaces.first)
        _ = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/a", remoteHost: "box", remoteSessionID: "o1"))
        let counts = library.restartCounts()
        #expect(counts.localSessions == 1)
        #expect(counts.remote)
    }

    @Test func restartCountsMarksARemoteWindowRemoteAndCountsNoneOfItsRows() throws {
        let library = WindowLibrary(directory: directory)
        _ = library.newRemoteWindow(host: "buildbox")
        let counts = library.restartCounts()
        #expect(counts.localSessions == 1)
        #expect(counts.remote)
    }
}
