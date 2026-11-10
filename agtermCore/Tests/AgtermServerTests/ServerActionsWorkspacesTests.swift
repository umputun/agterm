import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsWorkspacesTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    @Test func aNewWorkspaceIsAddedWithItsName() throws {
        let reply = harness.actions.createWorkspace(window: nil, name: " projects ", collapsed: true)

        let id = try #require(reply.result?.id.flatMap(UUID.init(uuidString:)))
        let workspace = try #require(harness.store.workspaces.first { $0.id == id })
        #expect(workspace.name == "projects")
        #expect(!workspace.isExpanded)
    }

    @Test func renameAndMoveActOnTheTarget() throws {
        let first = harness.store.workspaces[0].id
        let second = try #require(harness.actions.createWorkspace(window: nil, name: "b", collapsed: false).result?.id)

        #expect(harness.actions.renameWorkspace(second, window: nil, name: "bee").ok)
        #expect(harness.actions.moveWorkspace(second, window: nil, direction: .top).ok)

        #expect(harness.store.workspaces.map(\.name).first == "bee")
        #expect(harness.store.workspaces.map(\.id).last == first)
    }

    @Test func theLastWorkspaceCannotBeDeleted() {
        let only = harness.store.workspaces[0].id.uuidString

        #expect(harness.actions.deleteWorkspace(only, window: nil) == ControlResponse(ok: false, error: "cannot delete last workspace"))
    }

    @Test func deletingAWorkspaceEndsItsSessionsDaemons() throws {
        let workspace = try #require(harness.actions.createWorkspace(window: nil, name: "doomed", collapsed: false).result?.id)
        let reply = harness.actions.createSession(ControlSessionCreateOptions(window: nil, cwd: nil, workspace: workspace,
                                                                              workspaceName: nil, createWorkspace: nil, command: nil,
                                                                              wait: nil, name: nil, after: nil, before: nil,
                                                                              noSelect: false))
        let session = try harness.session(reply)

        #expect(harness.actions.deleteWorkspace(workspace, window: nil).ok)

        #expect(harness.runner.kills == [ZmxSupport.daemonName(for: session.paneIdentity)])
    }

    @Test func aWorkspaceNameAddressesTheDestination() throws {
        let reply = harness.actions.createSession(ControlSessionCreateOptions(window: nil, cwd: nil, workspace: nil,
                                                                              workspaceName: "agents", createWorkspace: true,
                                                                              command: nil, wait: nil, name: nil, after: nil,
                                                                              before: nil, noSelect: false))

        let session = try harness.session(reply)
        let workspace = try #require(harness.store.workspace(named: "agents"))
        #expect(workspace.sessions.map(\.id) == [session.id])
    }
}
