import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsMovesTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession(workspace: String? = nil) throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: workspace, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    private func order(_ workspace: UUID) -> [UUID] {
        harness.store.workspaces.first { $0.id == workspace }?.sessions.map(\.id) ?? []
    }

    @Test func aSessionMovesToTheTopOfItsWorkspace() throws {
        let first = try newSession(), second = try newSession()
        let workspace = harness.store.workspaces[0].id

        #expect(harness.actions.moveSession(second.id.uuidString, window: nil, move: .reorder(.top)).ok)

        #expect(order(workspace) == [second.id, first.id])
    }

    @Test func aSessionMovesToAnotherWorkspace() throws {
        let session = try newSession()
        let target = try #require(harness.actions.createWorkspace(window: nil, name: "b", collapsed: false).result?.id)

        let reply = harness.actions.moveSession(session.id.uuidString, window: nil, move: .workspace(target))

        #expect(reply == ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString)))
        #expect(order(try #require(UUID(uuidString: target))) == [session.id])
    }

    @Test func aSessionMovesAfterAnAnchorInTheAnchorsWorkspace() throws {
        let moved = try newSession()
        let target = try #require(harness.actions.createWorkspace(window: nil, name: "b", collapsed: false).result?.id)
        let first = try newSession(workspace: target), last = try newSession(workspace: target)

        #expect(harness.actions.moveSession(moved.id.uuidString, window: nil, move: .place(anchor: first.id.uuidString, after: true)).ok)

        #expect(order(try #require(UUID(uuidString: target))) == [first.id, moved.id, last.id])
    }

    @Test func severalSessionsMoveTogether() throws {
        let first = try newSession(), second = try newSession()
        let target = try #require(harness.actions.createWorkspace(window: nil, name: "b", collapsed: false).result?.id)

        let reply = harness.actions.moveSessions([first.id.uuidString, second.id.uuidString], window: nil, move: .workspace(target))

        #expect(reply == ControlResponse(ok: true, result: ControlResult(affected: 2)))
        #expect(order(try #require(UUID(uuidString: target))) == [first.id, second.id])
    }

    @Test func aBatchCannotReorder() throws {
        let first = try newSession(), second = try newSession()

        let reply = harness.actions.moveSessions([first.id.uuidString, second.id.uuidString], window: nil, move: .reorder(.top))

        #expect(reply == ControlResponse(ok: false, error: "session.move --target can be repeated only with a workspace or --after/--before"))
    }

    @Test func aCompanionCannotLeaveItsGroup() async throws {
        let parent = try newSession()
        let companion = try harness.session(await harness.actions.createCompanion(parent.id.uuidString, options: CompanionOptions(),
                                                                                  window: nil))
        let target = try #require(harness.actions.createWorkspace(window: nil, name: "b", collapsed: false).result?.id)

        let reply = harness.actions.moveSession(companion.id.uuidString, window: nil, move: .workspace(target))

        #expect(reply == ControlResponse(ok: false, error: ServerActions.companionMoveError))
        #expect(harness.store.session(withID: companion.id)?.parentID == parent.id)
    }
}
