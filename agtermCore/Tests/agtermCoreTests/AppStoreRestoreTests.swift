import Foundation
import Testing
@testable import agtermCore

/// `AppStore.setRestoreCommand` — the store half of the control channel's `session.restore`. The contract
/// under test: per-pane tri-state writes to the PERSISTED field only, an eager save so a hook's write
/// survives a SIGKILL, and no re-save when nothing changed. Split out of AppStoreTests to keep that file
/// within the line budget.
@MainActor
final class AppStoreRestoreTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("workspaces.json") }

    private func makePersistedStore() -> AppStore {
        AppStore(persistence: PersistenceStore(directory: directory))
    }

    /// A store whose every save fails, the `mutationSurvivesSaveFailure` idiom: the persistence directory
    /// is under a path that can never be one, so `createDirectory` throws. The failure rides the existing
    /// `PersistenceStore(directory:)` injection point — no production seam exists only for this test.
    private func makeUnwritableStore() -> AppStore {
        AppStore(persistence: PersistenceStore(directory: URL(fileURLWithPath: "/dev/null/agterm-cannot-write")))
    }

    @Test func setRestoreCommandSetsEachPaneIndependently() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        store.setRestoreCommand("claude --resume abc", pane: .left, forSession: session.id)
        #expect(session.restoreCommand == "claude --resume abc")
        #expect(session.splitRestoreCommand == nil)

        store.setRestoreCommand("tail -f /var/log/x", pane: .right, forSession: session.id)
        #expect(session.restoreCommand == "claude --resume abc")
        #expect(session.splitRestoreCommand == "tail -f /var/log/x")
    }

    @Test func setRestoreCommandClearsWithNil() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.restoreCommand = "claude --resume abc"
        session.splitRestoreCommand = "tail -f /var/log/x"

        store.setRestoreCommand(nil, pane: .left, forSession: session.id)
        #expect(session.restoreCommand == nil)
        #expect(session.splitRestoreCommand == "tail -f /var/log/x") // clearing one pane leaves the other

        store.setRestoreCommand(nil, pane: .right, forSession: session.id)
        #expect(session.splitRestoreCommand == nil)
    }

    @Test func setRestoreCommandStoresTheEmptyPinnedToNothingValue() {
        // "" is a real override (a plain shell, suppressing the capture and initialCommand) and must not
        // collapse to nil, which would mean "no override" and let the auto-capture restore instead.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        store.setRestoreCommand("", pane: .left, forSession: session.id)
        store.setRestoreCommand("", pane: .right, forSession: session.id)
        #expect(session.restoreCommand == "")
        #expect(session.splitRestoreCommand == "")
    }

    @Test func setRestoreCommandNeverPopulatesThePendingSlots() {
        // the whole safety property: a write during this run must not execute during this run. Only an
        // app-bootstrap restore arms the pending slots the surface factories consume.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        store.setRestoreCommand("claude --resume abc", pane: .left, forSession: session.id)
        store.setRestoreCommand("tail -f /var/log/x", pane: .right, forSession: session.id)

        #expect(session.pendingRestoreCommand == nil)
        #expect(session.pendingSplitRestoreCommand == nil)
        // and the factory-facing read stays empty, so nothing can fire this launch
        #expect(session.takePendingRestoreOverride(pane: .left) == nil)
        #expect(session.takePendingRestoreOverride(pane: .right) == nil)
    }

    @Test func setRestoreCommandDoesNotDisarmAnAlreadyArmedPayload() {
        // a rewrite mid-launch (a hook firing on every session start) must not cancel the override the
        // bootstrap already armed, nor swap in the new value — the pending payload is frozen at bootstrap.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.restoreCommand = "claude --resume old"
        session.pendingRestoreCommand = "claude --resume old"

        store.setRestoreCommand("claude --resume new", pane: .left, forSession: session.id)

        #expect(session.restoreCommand == "claude --resume new")
        #expect(session.pendingRestoreCommand == "claude --resume old")
    }

    @Test func setRestoreCommandIgnoresAnUnknownSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        store.setRestoreCommand("claude --resume abc", pane: .left, forSession: UUID())
        #expect(session.restoreCommand == nil)
    }

    @Test func setRestoreCommandPersistsImmediately() throws {
        // the eager save is a stated requirement: a hook's write has to survive a SIGKILL, which never
        // runs the quit-time flush. The reported outcome is the write, not the memory mutation.
        let store = makePersistedStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))

        #expect(store.setRestoreCommand("claude --resume abc", pane: .left, forSession: session.id))

        let reloaded = PersistenceStore(directory: directory).load()
        #expect(reloaded.workspaces[0].sessions.first { $0.id == session.id }?.restoreCommand == "claude --resume abc")
    }

    @Test func setRestoreCommandRollsBackAndReportsAFailedWrite() throws {
        // clearing is the dangerous case: acking a clear whose write never landed would leave the OLD
        // shell line re-typed on every launch while the user believes it is gone. So the failure is
        // reported AND the in-memory value goes back to what is still on disk.
        let store = makeUnwritableStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        session.restoreCommand = "claude --resume abc"

        #expect(!store.setRestoreCommand(nil, pane: .left, forSession: session.id))
        #expect(session.restoreCommand == "claude --resume abc")

        // a replacement that fails leaves the old command armed too, not the half-applied new one
        #expect(!store.setRestoreCommand("claude --resume def", pane: .left, forSession: session.id))
        #expect(session.restoreCommand == "claude --resume abc")
    }

    @Test func setRestoreCommandRetriesTheSameRequestAfterAFailedWrite() throws {
        // the rollback is what keeps the retry possible: without it memory would already hold the
        // requested value and the unchanged-value guard would swallow the repeat as a no-op success.
        // A blocking FILE rather than the /dev/null idiom above, because this case needs the disk to
        // RECOVER between the two calls — deleting the blocker makes the same path writable.
        let blocker = directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let stateDir = blocker.appendingPathComponent("state")
        let store = AppStore(persistence: PersistenceStore(directory: stateDir))
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        session.restoreCommand = "claude --resume abc"
        #expect(!store.setRestoreCommand(nil, pane: .left, forSession: session.id))

        try FileManager.default.removeItem(at: blocker) // the disk recovers

        #expect(store.setRestoreCommand(nil, pane: .left, forSession: session.id))
        #expect(session.restoreCommand == nil)
        let reloaded = PersistenceStore(directory: stateDir).load()
        let persisted = try #require(reloaded.workspaces.first?.sessions.first { $0.id == session.id })
        #expect(persisted.restoreCommand == nil)
    }

    @Test func setRestoreCommandSkipsTheSaveWhenUnchanged() throws {
        // idempotent like setFlag: re-pinning the same value writes nothing. Proven by deleting the
        // persisted file and asserting the repeat call does not recreate it.
        let store = makePersistedStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.setRestoreCommand("claude --resume abc", pane: .left, forSession: session.id)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        try FileManager.default.removeItem(at: fileURL)

        store.setRestoreCommand("claude --resume abc", pane: .left, forSession: session.id)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path)) // unchanged → no save

        store.setRestoreCommand("claude --resume def", pane: .left, forSession: session.id)
        #expect(FileManager.default.fileExists(atPath: fileURL.path)) // a real change saves again
    }

    @Test func setRestoreCommandSkipsTheSaveWhenClearingAnAlreadyClearPane() throws {
        let store = makePersistedStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.setRestoreCommand("claude --resume abc", pane: .left, forSession: session.id)
        try FileManager.default.removeItem(at: fileURL)

        store.setRestoreCommand(nil, pane: .right, forSession: session.id) // never pinned
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(session.splitRestoreCommand == nil)
    }

    @Test func setRestoreCommandIgnoresTheScratchPane() {
        // the scratch terminal is never restored; the command layer rejects it, and the store is a no-op.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        store.setRestoreCommand("claude --resume abc", pane: .scratch, forSession: session.id)
        #expect(session.restoreCommand == nil)
        #expect(session.splitRestoreCommand == nil)
    }

    @Test func softClosedSessionUndoneWithinGraceHasNothingPending() throws {
        // undo reinserts the SAME object, so a payload armed at bootstrap and never consumed would
        // otherwise survive the round trip and fire when the restored session's surface is built.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        session.restoreCommand = "claude --resume abc"
        session.splitRestoreCommand = "tail -f /var/log/x"
        session.pendingRestoreCommand = "claude --resume abc"
        session.pendingSplitRestoreCommand = "tail -f /var/log/x"

        #expect(store.softCloseSession(session.id, grace: 60))
        let closeID = try #require(store.pendingCloseSummary?.id)
        #expect(store.undoPendingClose(closeID))

        let restored = try #require(store.session(withID: session.id))
        #expect(restored === session) // the same live object came back
        #expect(restored.pendingRestoreCommand == nil)
        #expect(restored.pendingSplitRestoreCommand == nil)
        // the persisted pin is untouched, so the next launch still fires it
        #expect(restored.restoreCommand == "claude --resume abc")
        #expect(restored.splitRestoreCommand == "tail -f /var/log/x")
    }

    @Test func softClosedSessionGroupUndoneWithinGraceHasNothingPending() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        for session in [first, second] {
            session.restoreCommand = "claude --resume abc"
            session.pendingRestoreCommand = "claude --resume abc"
        }

        #expect(store.softCloseSessions([first.id, second.id], grace: 60))
        let closeID = try #require(store.pendingCloseSummary?.id)
        #expect(store.undoPendingClose(closeID))

        #expect(first.pendingRestoreCommand == nil)
        #expect(second.pendingRestoreCommand == nil)
        #expect(first.restoreCommand == "claude --resume abc")
    }

    @Test func softRemovedWorkspaceUndoneWithinGraceHasNothingPending() throws {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let session = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        session.restoreCommand = "claude --resume abc"
        session.pendingRestoreCommand = "claude --resume abc"

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))
        let closeID = try #require(store.pendingCloseSummary?.id)
        #expect(store.undoPendingClose(closeID))

        #expect(session.pendingRestoreCommand == nil)
        #expect(session.restoreCommand == "claude --resume abc")
    }
}
