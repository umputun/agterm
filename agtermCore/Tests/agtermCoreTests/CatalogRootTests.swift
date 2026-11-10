import Foundation
import Testing
@testable import agtermCore

@MainActor
struct CatalogRootTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agterm-catalog-\(UUID().uuidString)")
    }

    @Test func theFirstLoadWritesAnIdThatLaterLoadsKeep() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try CatalogRoot.load(directory: dir, name: "buildbox")
        let second = try CatalogRoot.load(directory: dir, name: "buildbox")

        #expect(first.id == second.id)
        #expect(first.name == "buildbox")
    }

    @Test func aMalformedIdIsAnErrorAndLeftAlone() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(CatalogRoot.filename)
        try Data("not-a-uuid\n".utf8).write(to: file)

        #expect(throws: CatalogRoot.Failure.malformed(file.path)) { try CatalogRoot.load(directory: dir, name: "x") }
        #expect(try String(contentsOf: file, encoding: .utf8) == "not-a-uuid\n")
    }

    @Test func theProjectionCarriesTheCatalogAsItsWindow() {
        let root = CatalogRoot(id: UUID(), name: "buildbox")
        let projection = root.projection(of: makeStore().controlTree())

        #expect(projection.id == root.id.uuidString)
        #expect(projection.name == "buildbox")
    }

    @Test func seedingAddsOneWorkspaceOnlyToAnEmptyStore() {
        let store = makeStore()

        CatalogRoot.seedWorkspace(in: store)
        CatalogRoot.seedWorkspace(in: store)

        #expect(store.workspaces.count == 1)
    }

    @Test func seedingKeepsARenamedWorkspace() {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "projects")

        CatalogRoot.seedWorkspace(in: store)

        #expect(store.workspaces.map(\.id) == [workspace.id])
        #expect(store.workspaces.first?.name == "projects")
    }

    @Test(arguments: [Command.windowNew, .windowClose, .sidebar, .fontInc, .quick, .dashboard, .surfaceZoom, .themeSet])
    func aMacWindowCommandIsRefusedByName(_ command: Command) throws {
        let message = try #require(HeadlessCommandPolicy.physicalWindowRefusal(command))
        #expect(message.hasPrefix(command.rawValue))
    }

    @Test(arguments: [Command.windowList, .tree, .version, .zmxTree, .zmxPresent, .pickResult, .pickCancel,
                      .sessionNew, .zmxPrune])
    func logicalReadsAndSessionCommandsAreNotOnTheList(_ command: Command) {
        #expect(HeadlessCommandPolicy.physicalWindowRefusal(command) == nil)
    }
}
