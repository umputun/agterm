import Foundation
import Testing
@testable import agtermCore

// SessionSnapshot / Snapshot serialization + restore round-trips, forward-compat legacy decodes, and
// restore-time clamping. Split out of AppStoreTests to keep both files within the line budget.
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
        // restore into a fresh store: each pane keeps its own seed.
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
        let restored = makeStore()
        restored.restore(from: snap)
        let r = restored.workspaces[0].sessions[0]
        #expect(r.foregroundCommand == ["ssh", "gate", "-p", "22"])
        #expect(r.splitForegroundCommand == ["tail", "-f", "/var/log/x"])
    }

    @Test func legacySnapshotWithoutForegroundCommandDecodesNil() throws {
        // a snapshot written before this field existed must still decode (nil = plain shell on restore).
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","cwd":"/tmp"}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.foregroundCommand == nil)
        #expect(snap.splitForegroundCommand == nil)
        #expect(snap.initialCommand == nil)
        #expect(snap.cwd == "/tmp")
    }

    @Test func initialCommandRoundTripsThroughSnapshot() {
        // a command session (e.g. `--command ssh …`) persists its creation command so it re-runs on
        // restore instead of coming back a plain shell.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.initialCommand = "ssh user@host -t 'ssh inner'"
        #expect(session.wasRestored == false) // a fresh session is not marked restored
        let snap = store.snapshot()
        #expect(snap.workspaces[0].sessions[0].initialCommand == "ssh user@host -t 'ssh inner'")
        let restored = makeStore()
        restored.restore(from: snap)
        let r = restored.workspaces[0].sessions[0]
        #expect(r.initialCommand == "ssh user@host -t 'ssh inner'")
        #expect(r.wasRestored == true) // restore marks the session, so the surface factory can gate its re-run
    }

    @Test func commandWaitRoundTripsThroughSnapshot() {
        // a held --command session persists the flag so a restored session that re-runs its command holds
        // again, keeping the held/closed behavior consistent across restart (issue #254).
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
        // a command session created WITHOUT --wait writes commandWait as nil (false is omitted), and restore
        // maps that nil back to false via session(from:)'s `?? false` — not true. Exercises both the write
        // gate and the nil->false restore mapping (a `?? true` mutant would restore true and fail here).
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
        // a snapshot written before --wait existed has no commandWait key; it must decode as nil (not fail
        // the whole load), like every other post-v1 optional field; restore maps nil to false.
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
        // a snapshot written before these fields existed decodes them as nil; restore falls back to defaults.
        let store = makeStore()
        store.sidebarWidth = 400
        store.sidebarVisible = false
        store.restore(from: Snapshot(workspaces: []))
        #expect(store.sidebarWidth == 220)
        #expect(store.sidebarVisible == true)
    }

    @Test func restoreClampsOutOfRangeSidebarWidth() {
        // a corrupt or hand-edited snapshot must not drive an out-of-range frame width; restore clamps it.
        let store = makeStore()
        store.restore(from: Snapshot(workspaces: [], sidebarWidth: 2000))
        #expect(store.sidebarWidth == AppStore.sidebarWidthMax)
        store.restore(from: Snapshot(workspaces: [], sidebarWidth: 10))
        #expect(store.sidebarWidth == AppStore.sidebarWidthMin)
    }

    @Test func restoreClampsOutOfRangeSplitRatio() {
        // a corrupt snapshot ratio must not feed an out-of-range fraction into NSSplitView.setPosition.
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
        // "" is the "pinned to nothing" state of the tri-state and must survive JSON as an empty string —
        // collapsing it to nil would silently turn the opt-out back into auto-capture.
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
        // a snapshot written before the override existed must still decode (nil = no override, the
        // auto-capture behavior) rather than throwing and wiping the saved tree.
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp","foregroundCommand":["claude"]}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.restoreCommand == nil)
        #expect(snap.splitRestoreCommand == nil)
        #expect(snap.foregroundCommand == ["claude"])
    }

    @Test func sessionSnapshotDecodesWithoutSplitRatio() throws {
        // a SessionSnapshot persisted before splitRatio existed (the key absent) must decode to nil, not
        // fail the load — the forward-compat contract the optional field documents.
        let json = "{\"id\":\"\(UUID().uuidString)\",\"cwd\":\"/a\"}"
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.splitRatio == nil)
        #expect(snap.isSplit == nil)
        #expect(snap.fontSize == nil)
    }
}
