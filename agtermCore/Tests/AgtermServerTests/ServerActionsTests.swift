import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsTests {
    private let harness: ServerHarness
    private var catalog: CatalogRoot { harness.catalog }

    init() throws { harness = try ServerHarness() }

    private func actions() -> ServerActions { harness.actions }

    @Test func versionAdvertisesAHeadlessServer() {
        let reply = actions().appIdentity()

        #expect(reply.result?.headless == true)
        #expect(reply.result?.app == AppIdentity(version: "1.2.3"))
    }

    @Test func theTreeIsTheCatalogsWorkspaces() throws {
        let reply = actions().controlTree(window: nil)

        let tree = try #require(reply.result?.tree)
        #expect(tree.workspaces.count == 1)
        #expect(tree.app == AppIdentity(version: "1.2.3"))
    }

    @Test func theWindowListIsTheCatalogRoot() {
        let reply = actions().windowList()

        #expect(reply.result?.windows == [ControlWindowNode(id: catalog.id.uuidString, name: "testbox", open: true, active: true)])
    }

    @Test func aWindowArgumentMustNameTheCatalog() {
        let actions = actions()

        #expect(actions.controlTree(window: catalog.id.uuidString.lowercased()).ok)
        #expect(actions.controlTree(window: "active").ok)
        #expect(!actions.controlTree(window: UUID().uuidString).ok)
    }

    @Test func anUnservedRequirementRefusesByName() async {
        let reply = await actions().windowNew(name: nil, minimized: false)

        #expect(reply == ControlResponse(ok: false, error: "windowNew is not available on agterm-server"))
    }
}
