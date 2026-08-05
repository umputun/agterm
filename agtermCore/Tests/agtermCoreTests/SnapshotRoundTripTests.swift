import Foundation
import Testing
@testable import agtermCore

// SessionSnapshot / Snapshot serialization + restore round-trips, forward-compat legacy decodes, and
// restore-time clamping.
@MainActor
struct SnapshotRoundTripTests {
    @Test func splitCwdRoundTripsThroughSnapshot() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.currentCwd = "/a/primary"
        session.splitCwd = "/var/log"
        let snap = store.snapshot()
        let snapped = snap.workspaces[0].sessions[0]
        #expect(snapped.cwd == "/a/primary")
        #expect(snapped.splitCwd == "/var/log")
        let restored = makeStore()
        restored.restore(from: snap)
        let r = restored.workspaces[0].sessions[0]
        #expect(r.initialCwd == "/a/primary")
        #expect(r.initialSplitCwd == "/var/log")
        #expect(r.isSplit == true)
    }

    @Test func foregroundCommandRoundTripsThroughSnapshot() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.foregroundCommand = ["ssh", "gate", "-p", "22"]
        session.splitForegroundCommand = ["tail", "-f", "/var/log/x"]
        let snap = store.snapshot()
        let snapped = snap.workspaces[0].sessions[0]
        #expect(snapped.foregroundCommand == ["ssh", "gate", "-p", "22"])
        #expect(snapped.splitForegroundCommand == ["tail", "-f", "/var/log/x"])
        // the executable half of the round trip is quit → next-launch bootstrap; a non-launch rebuild
        // deliberately drops the captured commands (see AppStoreRestoreSeedTests).
        let restored = makeStore()
        restored.restore(from: snap, launchRestore: true)
        let r = restored.workspaces[0].sessions[0]
        #expect(r.foregroundCommand == ["ssh", "gate", "-p", "22"])
        #expect(r.splitForegroundCommand == ["tail", "-f", "/var/log/x"])
    }

    @Test func legacySnapshotWithoutForegroundCommandDecodesNil() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","cwd":"/tmp"}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.foregroundCommand == nil)
        #expect(snap.splitForegroundCommand == nil)
        #expect(snap.initialCommand == nil)
        #expect(snap.cwd == "/tmp")
    }

    @Test func initialCommandRoundTripsThroughSnapshot() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.initialCommand = "ssh user@host -t 'ssh inner'"
        #expect(session.wasRestored == false)
        let snap = store.snapshot()
        #expect(snap.workspaces[0].sessions[0].initialCommand == "ssh user@host -t 'ssh inner'")
        let restored = makeStore()
        restored.restore(from: snap)
        let r = restored.workspaces[0].sessions[0]
        #expect(r.initialCommand == "ssh user@host -t 'ssh inner'")
        #expect(r.wasRestored == true) // the surface factory gates the re-run on this
    }

    @Test func commandWaitRoundTripsThroughSnapshot() {
        // a restored session that re-runs its command must hold again, like the original (issue #254).
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a", command: "make test", wait: true)!
        #expect(session.commandWait == true)
        let snap = store.snapshot()
        #expect(snap.workspaces[0].sessions[0].commandWait == true)
        let restored = makeStore()
        restored.restore(from: snap)
        #expect(restored.workspaces[0].sessions[0].commandWait == true)
    }

    @Test func commandWaitFalseRoundTripsAsNilAndRestoresFalse() {
        // false is omitted on write, so restore maps the resulting nil back through `?? false`; a `?? true`
        // mutant would restore true and fail here.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a", command: "make test")!
        #expect(session.commandWait == false)
        let snap = store.snapshot()
        #expect(snap.workspaces[0].sessions[0].commandWait == nil)
        let restored = makeStore()
        restored.restore(from: snap)
        #expect(restored.workspaces[0].sessions[0].commandWait == false)
    }

    @Test func legacySnapshotWithoutCommandWaitDecodesNil() throws {
        // the missing key must decode as nil rather than failing the whole load, like every post-v1 field.
        let json = #"{"id":"\#(UUID().uuidString)","customName":null,"cwd":"/a","initialCommand":"make test"}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.commandWait == nil)
    }

    @Test func sidebarWidthAndVisibilityRoundTripThroughSnapshot() {
        let store = makeStore()
        _ = store.addWorkspace(name: "work")
        store.sidebarWidth = 312
        store.sidebarVisible = false
        let snap = store.snapshot()
        #expect(snap.sidebarWidth == 312)
        #expect(snap.sidebarVisible == false)
        let restored = makeStore()
        restored.restore(from: snap)
        #expect(restored.sidebarWidth == 312)
        #expect(restored.sidebarVisible == false)
    }

    @Test func sidebarDefaultsWhenSnapshotOmitsThem() {
        let store = makeStore()
        store.sidebarWidth = 400
        store.sidebarVisible = false
        store.restore(from: Snapshot(workspaces: []))
        #expect(store.sidebarWidth == 220)
        #expect(store.sidebarVisible == true)
    }

    @Test func restoreClampsOutOfRangeSidebarWidth() {
        let store = makeStore()
        store.restore(from: Snapshot(workspaces: [], sidebarWidth: 2000))
        #expect(store.sidebarWidth == AppStore.sidebarWidthMax)
        store.restore(from: Snapshot(workspaces: [], sidebarWidth: 10))
        #expect(store.sidebarWidth == AppStore.sidebarWidthMin)
    }

    @Test func restoreClampsOutOfRangeSplitRatio() {
        // an out-of-range fraction would reach NSSplitView.setPosition unclamped.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.splitRatio = 5.0
        let restored = makeStore()
        restored.restore(from: store.snapshot())
        #expect(restored.workspaces[0].sessions[0].splitRatio == AppStore.splitRatioMax)
    }

    @Test func splitRatioRoundTripsThroughSnapshot() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.splitRatio = 0.63
        #expect(store.snapshot().workspaces[0].sessions[0].splitRatio == 0.63)
        let restored = makeStore()
        restored.restore(from: store.snapshot())
        #expect(restored.workspaces[0].sessions[0].splitRatio == 0.63)
    }

    @Test func restoreCommandRoundTripsThroughSnapshot() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true // a split pin only survives a rebuild that rebuilds the split
        session.restoreCommand = "claude --resume abc"
        session.splitRestoreCommand = "tail -f /var/log/x"
        let snap = store.snapshot()
        let snapped = snap.workspaces[0].sessions[0]
        #expect(snapped.restoreCommand == "claude --resume abc")
        #expect(snapped.splitRestoreCommand == "tail -f /var/log/x")
        let restored = makeStore()
        restored.restore(from: snap)
        let r = restored.workspaces[0].sessions[0]
        #expect(r.restoreCommand == "claude --resume abc")
        #expect(r.splitRestoreCommand == "tail -f /var/log/x")
    }

    @Test func emptyRestoreCommandRoundTripsAsEmptyNotNil() throws {
        // "" is the tri-state's "pinned to nothing"; collapsing it to nil turns the opt-out back into
        // auto-capture.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true // a split pin only survives a rebuild that rebuilds the split
        session.restoreCommand = ""
        session.splitRestoreCommand = ""
        let data = try JSONEncoder().encode(store.snapshot())
        let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        #expect(decoded.workspaces[0].sessions[0].restoreCommand == "")
        #expect(decoded.workspaces[0].sessions[0].splitRestoreCommand == "")
        let restored = makeStore()
        restored.restore(from: decoded)
        #expect(restored.workspaces[0].sessions[0].restoreCommand == "")
        #expect(restored.workspaces[0].sessions[0].splitRestoreCommand == "")
    }

    @Test func legacySnapshotWithoutRestoreCommandDecodesNil() throws {
        // a throw here would fail the whole load and wipe the saved tree.
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp","foregroundCommand":["claude"]}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.restoreCommand == nil)
        #expect(snap.splitRestoreCommand == nil)
        #expect(snap.foregroundCommand == ["claude"])
    }

    @Test func focusSetRoundTripsThroughSnapshot() throws {
        let store = makeStore()
        let one = store.addWorkspace(name: "one")
        _ = store.addWorkspace(name: "two")
        let three = store.addWorkspace(name: "three")
        store.setFocusMembership(three.id, member: true) // marked out of tree order
        store.setFocusMembership(one.id, member: true)
        store.setFocusEnabled(true) // marking only marks; applying the set is its own step
        let snap = store.snapshot()
        #expect(snap.focusedWorkspaceIDs == [one.id, three.id]) // tree order, never the Set's hash order
        #expect(snap.focusEnabled == true)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snap))
        let restored = makeStore()
        restored.restore(from: decoded)
        #expect(restored.focusedWorkspaceIDs == [one.id, three.id] && restored.focusEnabled)
        #expect(restored.visibleWorkspaces.map(\.id) == [one.id, three.id])
    }

    @Test func disabledFilterRoundTripsKeepingItsMarkedSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addWorkspace(name: "personal")
        store.setFocusMembership(work.id, member: true)
        store.setFocusEnabled(true)
        store.setFocusEnabled(false)
        let snap = store.snapshot()
        #expect(snap.focusedWorkspaceIDs == [work.id] && snap.focusEnabled == nil) // off omits the key
        let restored = makeStore()
        restored.restore(from: snap)
        #expect(restored.focusedWorkspaceIDs == [work.id] && !restored.focusEnabled)
    }

    @Test func unmarkedStoreOmitsBothFocusKeys() throws {
        // an unfiltered tree must serialize byte-identically to a legacy snapshot.
        let store = makeStore()
        _ = store.addWorkspace(name: "work")
        let snap = store.snapshot()
        #expect(snap.focusedWorkspaceIDs == nil && snap.focusEnabled == nil)
        let json = try String(decoding: JSONEncoder().encode(snap), as: UTF8.self)
        // the prefix match also covers the legacy `focusedWorkspaceID` key.
        #expect(!json.contains("focusedWorkspace") && !json.contains("focusEnabled"))
    }

    @Test func legacySnapshotWithSingleFocusedWorkspaceDecodesAsAnEnabledSet() throws {
        // in the pre-set format the key's mere presence meant the filter was on.
        let ws = UUID()
        let json = #"{"version":1,"workspaces":[],"focusedWorkspaceID":"\#(ws.uuidString)"}"#
        let snap = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        #expect(snap.focusedWorkspaceIDs == [ws])
        #expect(snap.focusEnabled == true)
    }

    @Test func reEncodingAMigratedSnapshotDropsTheLegacyFocusKey() throws {
        // a legacy file riding a load -> mutate -> save path (e.g. `WindowLibrary.clearClosedWindowFontSizes`)
        // must be rewritten with the SET keys alone.
        let ws = UUID()
        let json = #"{"version":1,"workspaces":[],"focusedWorkspaceID":"\#(ws.uuidString)"}"#
        let decoded = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))

        let reEncoded = try String(decoding: JSONEncoder().encode(decoded), as: UTF8.self)

        #expect(!reEncoded.contains("\"focusedWorkspaceID\""))
        #expect(reEncoded.contains("\"focusedWorkspaceIDs\"") && reEncoded.contains("\"focusEnabled\""))
        let again = try JSONDecoder().decode(Snapshot.self, from: Data(reEncoded.utf8))
        #expect(again.focusedWorkspaceIDs == [ws] && again.focusEnabled == true)
    }

    @Test func snapshotWithBothFocusKeysPrefersTheSet() throws {
        // both keys means a downgrade-then-upgrade round trip; the legacy key holds at most one member,
        // so taking it would silently narrow a multi-workspace filter.
        let a = UUID(), b = UUID(), stale = UUID()
        let json = #"""
        {"version":1,"workspaces":[],"focusedWorkspaceID":"\#(stale.uuidString)",
         "focusedWorkspaceIDs":["\#(a.uuidString)","\#(b.uuidString)"],"focusEnabled":false}
        """#
        let snap = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        #expect(snap.focusedWorkspaceIDs == [a, b])
        #expect(snap.focusEnabled == false) // the explicit flag wins, not the legacy key's implied `true`
    }

    @Test func snapshotWithoutAnyFocusKeyDecodesToNilWithoutThrowing() throws {
        // a throw here would wipe the saved tree over a per-window view filter.
        let json = #"{"version":1,"workspaces":[]}"#
        let snap = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        #expect(snap.focusedWorkspaceIDs == nil && snap.focusEnabled == nil)
        let store = makeStore()
        store.restore(from: snap)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func hudStateNeverReachesTheSnapshot() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.overlayActive = true
        session.overlaySizePercent = 30
        session.hudSpec = HudSpec(message: "gathering options", detail: "scanning /a", spinner: .bar)
        session.hudFile = "/tmp/agterm-hud-test.txt"

        let snap = store.snapshot()
        let json = String(decoding: try JSONEncoder().encode(snap), as: UTF8.self)
        #expect(!json.contains("hud"))
        #expect(!json.contains("gathering options"))

        let restored = makeStore()
        restored.restore(from: snap)
        let r = restored.workspaces[0].sessions[0]
        #expect(r.hudSpec == nil)
        #expect(r.hudFile == nil)
        #expect(r.hudActive == false)
        #expect(r.overlayActive == false)
    }

    @Test func sessionSnapshotDecodesWithoutSplitRatio() throws {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"cwd\":\"/a\"}"
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.splitRatio == nil)
        #expect(snap.isSplit == nil)
        #expect(snap.fontSize == nil)
    }
}
