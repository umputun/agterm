import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsFlagsTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession(workspace: String? = nil) throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: workspace, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    @Test(arguments: [("on", true, true), ("off", true, false), ("toggle", false, true), ("toggle", true, false)])
    func aFlagModeSetsTheSessionsFlag(_ mode: String, _ before: Bool, _ after: Bool) throws {
        let session = try newSession()
        harness.store.setFlag(before, forSession: session.id)

        #expect(harness.actions.setSessionFlag(session.id.uuidString, window: nil, mode: mode).ok)

        #expect(session.flagged == after)
    }

    @Test func clearUnflagsEverySessionAndAnUnknownModeIsRefused() throws {
        let first = try newSession()
        let second = try newSession()
        harness.store.setFlag(true, forSessions: [first.id, second.id])

        #expect(harness.actions.setSessionFlag(first.id.uuidString, window: nil, mode: "sideways")
            == ControlResponse(ok: false, error: "invalid flag mode: sideways"))
        #expect(harness.actions.setSessionFlag(nil, window: nil, mode: "clear").ok)

        #expect(!first.flagged && !second.flagged)
    }

    @Test func aWorkspaceFlagSetsEverySessionInIt() throws {
        let workspace = harness.store.workspaces[0].id
        let first = try newSession(workspace: workspace.uuidString)
        let second = try newSession(workspace: workspace.uuidString)

        #expect(harness.actions.setWorkspaceFlag(workspace.uuidString, window: nil, mode: .toggle).ok)

        #expect(first.flagged && second.flagged)
    }

    @Test func aRootWorkspaceFlagSetsItsSessionsAndTheirCompanions() throws {
        let top = try newSession(workspace: "root")
        let companion = try harness.store.addCompanion(to: top.id, options: CompanionOptions(cwd: "/c")).get()

        #expect(harness.actions.setWorkspaceFlag("root", window: nil, mode: .on).ok)

        #expect(top.flagged && companion.flagged)
    }

    @Test func aTintSetKeepsTheRowsPartsAndClearRemovesIt() throws {
        let session = try newSession()
        let workspace = harness.store.workspaces[0].id

        #expect(harness.actions.setSessionTint(session.id.uuidString, window: nil,
                                               update: .set(.named(.red), parts: [.name])).ok)
        #expect(harness.actions.setSessionTint(session.id.uuidString, window: nil, update: .set(.named(.blue), parts: nil)).ok)
        #expect(session.tint == SidebarTint(color: .blue, parts: [.name]))
        #expect(harness.actions.setWorkspaceTint(workspace.uuidString, window: nil, update: .set(.named(.green), parts: nil)).ok)
        #expect(harness.store.workspaces.first { $0.id == workspace }?.tint == SidebarTint(color: .green))

        #expect(harness.actions.setSessionTint(session.id.uuidString, window: nil, update: .clear).ok)
        #expect(session.tint == nil)
    }

    @Test func anUnknownTargetIsRefused() {
        #expect(!harness.actions.setSessionTint(UUID().uuidString, window: nil, update: .clear).ok)
        #expect(!harness.actions.setWorkspaceFlag(UUID().uuidString, window: nil, mode: .on).ok)
    }
}
