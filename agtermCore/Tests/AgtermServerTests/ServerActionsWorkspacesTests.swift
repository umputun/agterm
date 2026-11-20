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
        #expect(harness.store.namedWorkspaces.map(\.id).last == first)
    }

    @Test func theLastNamedWorkspaceIsDeletedLeavingTheRoot() throws {
        let only = try #require(harness.store.namedWorkspaces.first).id

        #expect(harness.actions.deleteWorkspace(only.uuidString, window: nil).ok)

        #expect(harness.store.namedWorkspaces.isEmpty)
        #expect(harness.store.rootWorkspace != nil)
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

    private func rootTargets() throws -> [String] {
        let root = try #require(harness.store.rootWorkspace)
        let session = try #require(harness.store.addSession(toWorkspace: root.id, cwd: "/top"))
        _ = harness.store.selectSession(session.id)
        return [root.id.uuidString, String(root.id.uuidString.prefix(8)), "active", "root"]
    }

    @Test func workspaceOnlyCommandsRefuseTheRootByIdPrefixAndActive() throws {
        let refusal = ControlResponse(ok: false, error: "top-level sessions are not a workspace")
        _ = harness.actions.createWorkspace(window: nil, name: "second", collapsed: false)
        for target in try rootTargets() {
            #expect(harness.actions.renameWorkspace(target, window: nil, name: "x") == refusal, "\(target)")
            #expect(harness.actions.deleteWorkspace(target, window: nil) == refusal, "\(target)")
            #expect(harness.actions.moveWorkspace(target, window: nil, direction: .top) == refusal, "\(target)")
            #expect(harness.actions.setWorkspaceTint(target, window: nil, update: .set(.red, parts: nil)) == refusal, "\(target)")
        }
        #expect(harness.store.rootWorkspace?.name.isEmpty == true)
        #expect(harness.store.workspaces.last?.isRoot == true)
    }

    @Test func aSessionIsCreatedInAndMovedIntoTheRootByItsId() throws {
        let root = try #require(harness.store.rootWorkspace).id
        let created = harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: root.uuidString, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: true))
        let id = try #require(created.result?.id.flatMap(UUID.init(uuidString:)))
        #expect(harness.store.workspace(forSession: id)?.id == root)

        let named = try #require(harness.store.namedWorkspaces.first).id
        let other = try #require(harness.store.addSession(toWorkspace: named, cwd: "/n"))
        #expect(harness.actions.moveSession(other.id.uuidString, window: nil, move: .workspace(root.uuidString)).ok)
        #expect(harness.store.workspace(forSession: other.id)?.id == root)
    }

}
