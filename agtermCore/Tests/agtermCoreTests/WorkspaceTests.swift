import Foundation
import Testing
@testable import agtermCore

@MainActor
struct WorkspaceTests {
    @Test func unseenCountSumsItsSessions() {
        let a = Session(initialCwd: "/a")
        let b = Session(initialCwd: "/b")
        a.unseenCount = 2
        b.unseenCount = 3
        let workspace = Workspace(name: "work", sessions: [a, b])
        #expect(workspace.unseenCount == 5)
    }

    @Test func unseenCountIsZeroWhenNonePending() {
        let workspace = Workspace(name: "empty", sessions: [Session(initialCwd: "/a")])
        #expect(workspace.unseenCount == 0)
    }

    @Test func rootDefaultsNilAndIsSettable() {
        // the per-workspace start directory: absent by default, holds a path once set.
        var workspace = Workspace(name: "proj", sessions: [])
        #expect(workspace.root == nil)
        workspace.root = "/Users/me/proj"
        #expect(workspace.root == "/Users/me/proj")
    }

    @Test func snapshotRootRoundTripsAndLegacyDecodesWithoutRoot() throws {
        let snap = WorkspaceSnapshot(id: UUID(), name: "work", sessions: [], root: "/proj")
        let data = try JSONEncoder().encode(snap)
        #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: data) == snap)
        // a legacy snapshot with NO root key still decodes (root → nil) — Optional, no version bump.
        let legacy = Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"work","sessions":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacy)
        #expect(decoded.root == nil)
        #expect(decoded.name == "work")
    }
}
