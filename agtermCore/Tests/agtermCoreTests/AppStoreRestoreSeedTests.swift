import Foundation
import Testing
@testable import agtermCore

// The `launchRestore` seeding gate: which rebuild paths arm a persisted `session.restore` override for
// this launch by copying it into the transient pending slots the surface factories consume. Only an
// app-bootstrap restore may; everything else defaults to arming nothing. Split out of AppStoreTests to
// keep that file within the line budget.
@MainActor
struct AppStoreRestoreSeedTests {
    private func snapshot(restore: String?, splitRestore: String?, isSplit: Bool) -> Snapshot {
        let session = SessionSnapshot(id: UUID(), customName: nil, cwd: "/a", isSplit: isSplit,
                                      restoreCommand: restore, splitRestoreCommand: splitRestore)
        return Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [session])])
    }

    @Test func bootstrapRestoreSeedsBothPanesForAShownSplit() {
        let store = makeStore()
        store.restore(from: snapshot(restore: "claude --resume abc", splitRestore: "tail -f /var/log/x",
                                     isSplit: true),
                      launchRestore: true)
        let session = store.workspaces[0].sessions[0]
        #expect(session.pendingRestoreCommand == "claude --resume abc")
        #expect(session.pendingSplitRestoreCommand == "tail -f /var/log/x")
        // the persisted fields are populated too, and stay populated — the override is sticky.
        #expect(session.restoreCommand == "claude --resume abc")
        #expect(session.splitRestoreCommand == "tail -f /var/log/x")
    }

    @Test func bootstrapRestoreDropsAHiddenSplitsOverrideEntirely() {
        // a split hidden at quit is not rebuilt, so makeSplitSurface never runs and its pin describes a
        // pane that no longer exists. Nothing may be armed for it, and the PERSISTED pin is dropped too —
        // otherwise `tree` reports a value `session.restore --pane right` cannot clear (no split), and a
        // fresh ⌘D split shown at the next quit would inherit and run it.
        let store = makeStore()
        store.restore(from: snapshot(restore: "claude --resume abc", splitRestore: "tail -f /var/log/x",
                                     isSplit: false),
                      launchRestore: true)
        let session = store.workspaces[0].sessions[0]
        #expect(session.pendingRestoreCommand == "claude --resume abc")
        #expect(session.pendingSplitRestoreCommand == nil)
        #expect(session.splitRestoreCommand == nil)
        // the drop reaches persistence on the next save, so the orphan does not come back.
        #expect(store.snapshot().workspaces[0].sessions[0].splitRestoreCommand == nil)
    }

    @Test func rebuildDropsAHiddenSplitsOverrideOnEveryPath() {
        // the drop is a property of the rebuild, not of bootstrap: Reopen Closed Item and a mid-process
        // window reload rebuild the same split-less session and must not resurrect the orphan either.
        let store = makeStore()
        let snap = SessionSnapshot(id: UUID(), customName: nil, cwd: "/a", isSplit: false,
                                   restoreCommand: "claude --resume abc", splitRestoreCommand: "tail -f")
        #expect(store.session(from: snap).splitRestoreCommand == nil)
        #expect(store.session(from: snap, launchRestore: true).splitRestoreCommand == nil)
    }

    @Test func bootstrapRestoreSeedsTheEmptyPinnedToNothingValue() {
        // "" is a real override (a plain shell, suppressing the capture and initialCommand), so it must be
        // armed like any other value rather than dropped as "no override".
        let store = makeStore()
        store.restore(from: snapshot(restore: "", splitRestore: "", isSplit: true), launchRestore: true)
        let session = store.workspaces[0].sessions[0]
        #expect(session.pendingRestoreCommand == "")
        #expect(session.pendingSplitRestoreCommand == "")
    }

    @Test func nonBootstrapRestoreSeedsNeitherPane() {
        // reopening a closed window mid-process reloads its store through restore(from:) — arming there
        // would execute every sticky override with no app restart.
        let store = makeStore()
        store.restore(from: snapshot(restore: "claude --resume abc", splitRestore: "tail -f /var/log/x",
                                     isSplit: true))
        let session = store.workspaces[0].sessions[0]
        #expect(session.pendingRestoreCommand == nil)
        #expect(session.pendingSplitRestoreCommand == nil)
        // but the persisted values are still restored, so `tree` reads them back and the next launch fires.
        #expect(session.restoreCommand == "claude --resume abc")
        #expect(session.splitRestoreCommand == "tail -f /var/log/x")
    }

    @Test func sessionRebuildDefaultsToSeedingNeitherPane() {
        // the default on session(from:) is the safe direction, so a caller added later arms nothing.
        let store = makeStore()
        let snap = SessionSnapshot(id: UUID(), customName: nil, cwd: "/a", isSplit: true,
                                   restoreCommand: "claude --resume abc", splitRestoreCommand: "tail -f")
        let session = store.session(from: snap)
        #expect(session.pendingRestoreCommand == nil)
        #expect(session.pendingSplitRestoreCommand == nil)
        #expect(session.restoreCommand == "claude --resume abc")
        #expect(session.splitRestoreCommand == "tail -f")
    }

    @Test func bootstrapRestoreOfASessionWithoutOverridesArmsNothing() {
        let store = makeStore()
        store.restore(from: snapshot(restore: nil, splitRestore: nil, isSplit: true), launchRestore: true)
        let session = store.workspaces[0].sessions[0]
        #expect(session.pendingRestoreCommand == nil)
        #expect(session.pendingSplitRestoreCommand == nil)
        #expect(session.restoreCommand == nil)
    }

    @Test func freshSessionHasNoOverrideState() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(session.restoreCommand == nil)
        #expect(session.splitRestoreCommand == nil)
        #expect(session.pendingRestoreCommand == nil)
        #expect(session.pendingSplitRestoreCommand == nil)
    }
}
