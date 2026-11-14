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

    @Test func theTreeReportsEachPanesForegroundProgramOrShell() throws {
        let session = try harness.session(actions().createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
        _ = actions().splitSession(session.id.uuidString, window: nil, mode: "on")
        let split = try #require(session.splitPaneIdentity)
        harness.panes.leaders = [session.paneIdentity: 100, split: 200]
        actions().foregroundArgv = { $0 == 100 ? ["-zsh"] : ["vim", "notes.md"] }

        let tree = try #require(actions().controlTree(window: nil).result?.tree)

        let node = try #require(tree.workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString })
        #expect(node.foreground == nil)
        #expect(node.foregroundShell == "zsh")
        #expect(node.splitForeground == ["vim", "notes.md"])
        #expect(node.splitForegroundShell == nil)
    }

    @Test func aPaneWithNoListedLeaderReportsNoForeground() throws {
        let session = try harness.session(actions().createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
        actions().foregroundArgv = { _ in ["vim"] }

        let tree = try #require(actions().controlTree(window: nil).result?.tree)

        let node = try #require(tree.workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString })
        #expect(node.foreground == nil)
        #expect(node.foregroundShell == nil)
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
