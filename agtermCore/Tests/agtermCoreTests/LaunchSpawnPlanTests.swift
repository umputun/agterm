import Foundation
import Testing
@testable import agtermCore

@MainActor
struct LaunchSpawnPlanTests {
    @Test func selectedPanesLeadAsTheBurstThenTheRestInModelOrder() throws {
        let first = restored()
        let second = restored(split: true)
        let third = restored()
        let other = restored(split: true)
        let secondSplit = try #require(second.splitPaneIdentity)
        let otherSplit = try #require(other.splitPaneIdentity)

        let plan = LaunchSpawnPlan.make(windows: [
            LaunchSpawnWindow(selectedSessionID: second.id, sessions: [first, second, third]),
            LaunchSpawnWindow(selectedSessionID: other.id, sessions: [other]),
        ])

        #expect(plan.order == [second.paneIdentity, secondSplit, other.paneIdentity, otherSplit,
                               first.paneIdentity, third.paneIdentity])
        #expect(plan.burst == [second.paneIdentity, secondSplit, other.paneIdentity, otherSplit])
    }

    @Test func hiddenSplitsAndUnrestoredSessionsAreNeverExpected() {
        let hidden = restored()
        hidden.splitPaneIdentity = UUID()
        hidden.hasSplit = true
        let fresh = Session(initialCwd: "/tmp")

        let plan = LaunchSpawnPlan.make(windows: [
            LaunchSpawnWindow(selectedSessionID: fresh.id, sessions: [hidden, fresh]),
        ])

        #expect(plan.order == [hidden.paneIdentity])
        #expect(plan.burst.isEmpty)
    }

    @Test func aLibraryPlanReadsEveryOpenWindowsStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.store(for: library.windows.first?.id))
        let session = try #require(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp"))
        session.wasRestored = true

        let plan = library.launchSpawnPlan()

        #expect(plan.order == [session.paneIdentity], "the bootstrap session was not restored")
        #expect(plan.burst == [session.paneIdentity])
    }

    private func restored(split: Bool = false) -> Session {
        let session = Session(initialCwd: "/tmp")
        session.wasRestored = true
        if split {
            session.hasSplit = true
            session.isSplit = true
            session.splitPaneIdentity = UUID()
        }
        return session
    }
}
