import Foundation
import Testing
@testable import agtermCore

// SessionSnapshot / Snapshot serialization + restore round-trips, forward-compat legacy decodes, and
// restore-time clamping.
@MainActor
struct SnapshotRoundTripTests {
    @Test func remoteSessionIsAbsentFromTheSnapshot() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let local = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: ws.id, cwd: "/b", remoteHost: "buildbox")!

        let snapshot = store.snapshot()

        let ids = snapshot.workspaces.flatMap(\.sessions).map(\.id)
        #expect(ids == [local.id])
    }

    @Test func aWorkspaceOfOnlyRemoteSessionsSnapshotsEmptyRatherThanVanishing() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "remote only")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/a", remoteHost: "buildbox")

        let snapshot = store.snapshot()

        let workspace = snapshot.workspaces.first { $0.id == ws.id }
        #expect(workspace != nil, "the workspace itself is local and must survive")
        #expect(workspace?.sessions.isEmpty == true)
    }

    @Test func aRestoredStoreCarriesNoRemoteMarker() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/a", remoteHost: "buildbox")
        let restored = makeStore()

        restored.restore(from: store.snapshot())

        #expect(restored.workspaces.flatMap(\.sessions).allSatisfy { $0.remoteHost == nil })
    }

    @Test func quittingOnARemoteSessionRestoresTheMostRecentLocalOne() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let second = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        let remote = store.addSession(toWorkspace: ws.id, cwd: "/c", remoteHost: "buildbox")!
        store.selectSession(first.id)
        store.selectSession(second.id)
        store.selectSession(remote.id)

        let snapshot = store.snapshot()

        #expect(snapshot.selectedSessionID == second.id, "an empty window beside live local rows is a poor restore")
        #expect(snapshot.sessionRecency?.contains(remote.id) != true, "a remote id must not survive to disk")
    }

    @Test func aStoreOfOnlyRemoteSessionsPersistsNoSelection() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let remote = store.addSession(toWorkspace: ws.id, cwd: "/a", remoteHost: "buildbox")!
        store.selectSession(remote.id)

        #expect(store.snapshot().selectedSessionID == nil)
    }

    @Test func paneIdentitiesRoundTrip() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.toggleSplit(session.id)
        let primary = session.paneIdentity
        let split = session.splitPaneIdentity
        let restored = makeStore()
        restored.restore(from: store.snapshot())
        #expect(restored.workspaces[0].sessions[0].paneIdentity == primary)
        #expect(restored.workspaces[0].sessions[0].splitPaneIdentity == split)
    }

    @Test func legacySnapshotMintsPaneIdentities() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","cwd":"/tmp","isSplit":true}"#
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.paneIdentity == nil)
        #expect(snapshot.splitPaneIdentity == nil)
        let store = makeStore()
        store.restore(from: Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [snapshot])]))
        let session = store.workspaces[0].sessions[0]
        #expect(session.splitPaneIdentity != nil)
    }

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
        // split, because the capture path only ever records a split argv for a SHOWN split and the launch
        // restore arms the split slot on the same condition
        session.isSplit = true
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
        #expect(r.pendingForegroundCommand == ["ssh", "gate", "-p", "22"])
        #expect(r.pendingSplitForegroundCommand == ["tail", "-f", "/var/log/x"])
        // re-snapshotting the restored store must not write the argv back — that is what makes the
        // launch-time strip durable against any save before the surfaces consume it.
        #expect(restored.snapshot().workspaces[0].sessions[0].foregroundCommand == nil)
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

    @Test func splitCreationIdentityRoundTripsForShownAndHiddenSplits() {
        let shownStore = makeStore()
        let shownWorkspace = shownStore.addWorkspace(name: "shown")
        let shown = shownStore.addSession(toWorkspace: shownWorkspace.id, cwd: "/shown")!
        shown.isSplit = true
        shown.hasSplit = true
        shown.splitInitialCommand = "ssh split-host"
        shown.splitCommandWait = true

        let shownSnapshot = shownStore.snapshot()
        #expect(shownSnapshot.workspaces[0].sessions[0].splitInitialCommand == "ssh split-host")
        #expect(shownSnapshot.workspaces[0].sessions[0].splitCommandWait == true)

        let restoredShown = makeStore()
        restoredShown.restore(from: shownSnapshot)
        #expect(restoredShown.workspaces[0].sessions[0].splitInitialCommand == "ssh split-host")
        #expect(restoredShown.workspaces[0].sessions[0].splitCommandWait)

        let hiddenStore = makeStore()
        let hiddenWorkspace = hiddenStore.addWorkspace(name: "hidden")
        let hidden = hiddenStore.addSession(toWorkspace: hiddenWorkspace.id, cwd: "/hidden")!
        hidden.hasSplit = true
        hidden.splitInitialCommand = "ssh hidden-host"
        hidden.splitCommandWait = true

        let restoredHidden = makeStore()
        restoredHidden.restore(from: hiddenStore.snapshot())
        #expect(restoredHidden.workspaces[0].sessions[0].splitInitialCommand == "ssh hidden-host")
        #expect(restoredHidden.workspaces[0].sessions[0].splitCommandWait)
    }

    @Test func legacySnapshotWithoutCommandWaitDecodesNil() throws {
        // the missing key must decode as nil rather than failing the whole load, like every post-v1 field.
        let json = #"{"id":"\#(UUID().uuidString)","customName":null,"cwd":"/a","initialCommand":"make test"}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.commandWait == nil)
        #expect(snap.splitInitialCommand == nil)
        #expect(snap.splitCommandWait == nil)
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

    @Test func splitAxisRoundTripsAndLegacyOrUnknownValuesDefaultLeftRight() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.hasSplit = true
        session.splitAxis = .topBottom

        let snapshot = store.snapshot()
        #expect(snapshot.workspaces[0].sessions[0].splitAxis == .topBottom)
        let restored = makeStore()
        restored.restore(from: snapshot)
        #expect(restored.workspaces[0].sessions[0].splitAxis == .topBottom)

        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","cwd":"/tmp","isSplit":true}"#
        let legacySession = try JSONDecoder().decode(SessionSnapshot.self, from: Data(legacy.utf8))
        #expect(legacySession.splitAxis == nil)
        let legacyStore = makeStore()
        legacyStore.restore(from: Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "legacy", sessions: [legacySession]),
        ]))
        #expect(legacyStore.workspaces[0].sessions[0].splitAxis == .leftRight)

        let unknown = #"{"id":"00000000-0000-0000-0000-000000000002","cwd":"/tmp","isSplit":true,"splitAxis":"diagonal"}"#
        let unknownSession = try JSONDecoder().decode(SessionSnapshot.self, from: Data(unknown.utf8))
        #expect(unknownSession.splitAxis == nil)
    }

    @Test func anUnknownTintColorDropsOnlyTheTint() throws {
        let session = #"{"id":"00000000-0000-0000-0000-000000000003","cwd":"/tmp","flagged":true,"tint":{"color":"maroon","on":["name"]}}"#
        let decodedSession = try JSONDecoder().decode(SessionSnapshot.self, from: Data(session.utf8))
        #expect(decodedSession.tint == nil)
        #expect(decodedSession.flagged == true)

        let workspace = #"{"id":"00000000-0000-0000-0000-000000000004","name":"w","sessions":[],"collapsed":true,"tint":"red"}"#
        let decodedWorkspace = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(workspace.utf8))
        #expect(decodedWorkspace.tint == nil)
        #expect(decodedWorkspace.collapsed == true)
    }

    @Test func anUntintedTreeWritesNoTintKey() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))

        let json = try String(decoding: JSONEncoder().encode(store.snapshot()), as: UTF8.self)

        #expect(!json.contains("\"tint\""))
    }

    @Test func hiddenSplitKeepsIdentityAndAxisButDefaultsFocusToPrimary() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.toggleSplit(session.id)
        let splitIdentity = session.splitPaneIdentity
        session.splitFocused = true
        store.toggleSplit(session.id)
        session.isSplit = false
        session.splitAxis = .topBottom
        let snapshot = store.snapshot()
        let saved = snapshot.workspaces[0].sessions[0]
        #expect(saved.hasSplit == true)
        #expect(saved.splitPaneIdentity == splitIdentity)
        #expect(saved.splitAxis == .topBottom)

        let restored = makeStore()
        restored.restore(from: snapshot)
        let result = restored.workspaces[0].sessions[0]
        #expect(result.hasSplit)
        #expect(!result.isSplit)
        #expect(!result.splitFocused)
        #expect(result.splitPaneIdentity == splitIdentity)
        #expect(result.splitAxis == .topBottom)
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

    @Test func contextRoundTripsThroughSnapshot() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.context = "PR #517: restore reap ordering"
        let snap = store.snapshot()
        #expect(snap.workspaces[0].sessions[0].context == "PR #517: restore reap ordering")
        let restored = makeStore()
        restored.restore(from: snap)
        #expect(restored.workspaces[0].sessions[0].context == "PR #517: restore reap ordering")
    }

    @Test func lastSelectedAtSurvivesARestoreThatReselectsTheSession() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        session.lastSelectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = store.snapshot()
        #expect(snap.workspaces[0].sessions[0].lastSelectedAt == 1_700_000_000)
        #expect(snap.selectedSessionID == session.id)

        let restored = makeStore()
        restored.restore(from: snap)

        #expect(restored.workspaces[0].sessions[0].lastSelectedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func snapshotWithoutLastSelectedAtDecodesNil() throws {
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp"}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.lastSelectedAt == nil)
    }

    @Test func companionLinksAndParentFoldRoundTripThroughSnapshot() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: ws.id, cwd: "/parent"))
        let companion = try store.addCompanion(to: parent.id).get()
        parent.isExpanded = false

        let snapshot = store.snapshot()
        let restored = makeStore()
        restored.restore(from: snapshot)

        let sessions = try #require(restored.workspaces.first).sessions
        #expect(sessions.map(\.id) == [parent.id, companion.id])
        #expect(sessions[1].parentID == parent.id)
        #expect(!sessions[0].isExpanded)
        #expect(sessions[1].isExpanded)
        #expect(snapshot.workspaces[0].sessions[1].collapsed == nil)
    }

    @Test func snapshotWithoutCompanionFieldsDecodesATopLevelExpandedSession() throws {
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp","parentID":42,"customName":"keep"}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.parentID == nil)
        #expect(snap.collapsed == nil)
        #expect(snap.customName == "keep")
    }

    @Test func restoreDropsAnInvalidCompanionLinkAndRegroupsAHandEditedOrder() {
        let parent = UUID()
        let companion = UUID()
        let orphan = UUID()
        let other = UUID()
        let snapshot = Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
            SessionSnapshot(id: companion, customName: nil, cwd: "/c", parentID: parent),
            SessionSnapshot(id: other, customName: nil, cwd: "/o"),
            SessionSnapshot(id: parent, customName: nil, cwd: "/p"),
            SessionSnapshot(id: orphan, customName: nil, cwd: "/x", parentID: UUID()),
        ])])
        let store = makeStore()

        store.restore(from: snapshot)

        let sessions = store.workspaces[0].sessions
        #expect(sessions.map(\.id) == [other, parent, companion, orphan])
        #expect(sessions.map(\.parentID) == [nil, nil, parent, nil])
    }

    @Test func snapshotWithoutContextDecodesNil() throws {
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp"}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.context == nil)
    }

    // `stored` is the JSON-ESCAPED body: an unescaped control byte is invalid JSON, so embedding one would
    // test the parser's leniency instead of the context rule.
    @Test(arguments: [#""#, #"   "#, #"PR\n517"#, #"PR\u2028517"#, #"PR\t517"#, #"PR517\n"#])
    func handEditedInvalidContextDropsWithoutFailingTheDecode(stored: String) throws {
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp","context":"\#(stored)","customName":"keep"}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.context == nil)
        #expect(snap.customName == "keep")
    }

    @Test func handEditedOversizedContextDropsWithoutFailingTheDecode() throws {
        let oversized = String(repeating: "a", count: Session.contextByteLimit + 1)
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp","context":"\#(oversized)","customName":"keep"}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.context == nil)
        #expect(snap.customName == "keep")
    }

    @Test func handEditedContextIsTrimmedOnDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp","context":"  PR #517  "}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.context == "PR #517")
    }

    @Test func duplicatedSessionDoesNotInheritContext() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.context = "PR #517"
        let copy = store.duplicateSession(session.id)
        #expect(copy?.context == nil)
    }

    @Test func sessionInfoIsNotSnapshottedOrDuplicated() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.setInfo(try SessionInfo.make(source: "3 agents", markdown: false, hideAfter: 0).get(), forSession: session.id)
        let restored = makeStore()
        restored.restore(from: store.snapshot())
        #expect(restored.workspaces[0].sessions[0].info == nil)
        #expect(store.duplicateSession(session.id)?.info == nil)
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

    private func throughDisk(_ snapshot: Snapshot) throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
    }

    @Test func aFilePageRowRoundTripsWithItsOptions() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let overlay = HtmlOverlay(source: .file(path: "/tmp/site/index.html", grantRoot: "/tmp/site"), navigation: true,
                                  javascript: true, chromeless: true)
        let page = try addPageRow(to: store, workspace: ws.id, overlay: overlay, backgroundColor: "#102030")
        store.renameSession(page.id, to: "dash")
        page.flagged = true
        page.context = "build status"

        let snapshot = try throughDisk(store.snapshot())
        let saved = try #require(snapshot.workspaces.first { $0.id == ws.id }?.sessions.first)
        let restored = makeStore()
        restored.restore(from: snapshot)

        #expect(saved.page == PageSnapshot(source: .file(path: "/tmp/site/index.html", grantRoot: "/tmp/site"),
                                           javascript: true, navigation: true, chromeless: true, backgroundColor: "#102030"))
        #expect(saved.paneIdentity == nil)
        let row = try #require(restored.session(withID: page.id))
        let shown = try #require(row.htmlOverlay)
        #expect(row.content == .page)
        #expect(shown.source == overlay.source)
        #expect(shown.javascript && shown.navigation && shown.chromeless)
        #expect(!shown.persistent && !shown.browse)
        #expect(shown.id != overlay.id)
        #expect(row.overlayActive)
        #expect(row.overlayBackgroundColor == "#102030")
        #expect(row.overlaySizePercent == nil)
        #expect(row.displayName == "dash")
        #expect(row.flagged)
        #expect(row.context == "build status")
        #expect(row.locallyManagedPaneIdentities.isEmpty)
    }

    @Test func aURLPageRowRoundTripsWithItsOptions() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let url = try #require(URL(string: "https://example.com/app?x=1"))
        let page = try addPageRow(to: store, workspace: ws.id,
                                  overlay: HtmlOverlay(source: .url(url), navigation: true, persistent: true, browse: true))

        let restored = makeStore()
        restored.restore(from: try throughDisk(store.snapshot()))

        let shown = try #require(restored.session(withID: page.id)?.htmlOverlay)
        #expect(shown.source == .url(url))
        #expect(shown.navigation && shown.persistent && shown.browse)
        #expect(!shown.javascript && !shown.chromeless)
        #expect(restored.session(withID: page.id)?.overlayBackgroundColor == nil)
    }

    @Test func aPageParentRoundTripsWithTerminalAndPageCompanions() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let root = try addPageRow(to: store, workspace: ws.id, overlay: HtmlOverlay(source: .file(path: "/tmp/root.html", grantRoot: nil)))
        let after = try #require(store.addSession(toWorkspace: ws.id, cwd: "/after"))
        let terminal = try store.addCompanion(to: root.id, options: CompanionOptions(cwd: "/term")).get()
        let url = try #require(URL(string: "https://example.com"))
        let nested = try store.addPageCompanion(to: root.id, overlay: HtmlOverlay(source: .url(url))).get()
        root.isExpanded = false

        let restored = makeStore()
        restored.restore(from: try throughDisk(store.snapshot()))

        let sessions = try #require(restored.workspaces.first { $0.id == ws.id }).sessions
        #expect(sessions.map(\.id) == [root.id, terminal.id, nested.id, after.id])
        #expect(sessions.map(\.content) == [.page, .terminal, .page, .terminal])
        #expect(sessions.map(\.parentID) == [nil, root.id, root.id, nil])
        #expect(!sessions[0].isExpanded)
        #expect(sessions[0].htmlOverlay?.source == .file(path: "/tmp/root.html", grantRoot: nil))
        #expect(sessions[1].paneIdentity == terminal.paneIdentity)
        #expect(sessions[1].initialCwd == "/term")
        #expect(sessions[2].htmlOverlay?.source == .url(url))
        #expect(restored.companions(of: root.id).map(\.id) == [terminal.id, nested.id])
    }

    @Test(arguments: [false, true])
    func aPageGroupRestoresWhetherOrNotTheLaunchArmsCommands(launchRestore: Bool) throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let root = try addPageRow(to: store, workspace: ws.id, overlay: HtmlOverlay(source: .file(path: "/tmp/root.html", grantRoot: nil)))
        let terminal = try store.addCompanion(to: root.id).get()
        terminal.foregroundCommand = ["vim", "notes.md"]

        let restored = makeStore()
        restored.restore(from: store.snapshot(), launchRestore: launchRestore)

        #expect(restored.session(withID: root.id)?.htmlOverlay?.source == .file(path: "/tmp/root.html", grantRoot: nil))
        #expect(restored.companions(of: root.id).map(\.id) == [terminal.id])
        #expect(restored.session(withID: terminal.id)?.pendingForegroundCommand == (launchRestore ? ["vim", "notes.md"] : nil))
    }

    @Test func aPageRowWhoseLoadFailsStaysWithItsCompanionsAndReload() throws {
        let root = UUID()
        let companion = UUID()
        let workspace = UUID()
        let store = makeStore()
        store.restore(from: Snapshot(workspaces: [WorkspaceSnapshot(id: workspace, name: "work", sessions: [
            SessionSnapshot(id: root, customName: nil, cwd: "/tmp",
                            page: PageSnapshot(source: .file(path: "/nonexistent/gone.html", grantRoot: "/nonexistent"))),
            SessionSnapshot(id: companion, customName: nil, cwd: "/tmp", parentID: root),
        ])]))
        let page = try #require(store.session(withID: root)?.htmlOverlay)

        store.setHtmlLoadState(page.id, state: .failed, error: "The file couldn’t be opened.")

        let row = try #require(store.session(withID: root))
        #expect(row.htmlOverlay?.loadState == .failed)
        #expect(store.companions(of: root).map(\.id) == [companion])
        #expect(store.reloadHtmlOverlay(root, pane: nil) == nil)
        #expect(row.htmlOverlay?.loadState == .loading)
        #expect(store.snapshot().workspaces[0].sessions.map(\.id) == [root, companion])
    }

    @Test func aReplicaPageRowIsAbsentFromTheSnapshot() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let local = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let replica = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b", remoteHost: "buildbox", content: .page))
        let overlay = HtmlOverlay(source: .replica(path: "/srv/page.html", content: .html), replicaOf: UUID())
        #expect(store.openHtmlOverlay(replica.id, pane: nil, overlay: overlay, sizePercent: nil) == nil)
        let url = try #require(URL(string: "https://example.com"))
        let remoteURL = try addPageRow(to: store, workspace: ws.id, overlay: HtmlOverlay(source: .url(url)))
        let remote = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c", remoteHost: "buildbox", content: .page))
        #expect(store.openHtmlOverlay(remote.id, pane: nil, overlay: HtmlOverlay(source: .url(url)), sizePercent: nil) == nil)

        let ids = store.snapshot().workspaces.first { $0.id == ws.id }?.sessions.map(\.id)

        #expect(ids == [local.id, remoteURL.id])
        #expect(replica.pageSnapshot == nil)
        #expect(remote.pageSnapshot == nil)
    }

    @Test func aPageRowJoinsTheSnapshotOnlyOnceItsPageIsPlaced() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let page = try #require(store.addSession(toWorkspace: ws.id, cwd: "/page", content: .page))
        let before = store.snapshot().workspaces.first { $0.id == ws.id }?.sessions.map(\.id)

        #expect(store.openHtmlOverlay(page.id, pane: nil, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil)),
                                      sizePercent: nil) == nil)

        #expect(before == [])
        #expect(store.snapshot().workspaces.first { $0.id == ws.id }?.sessions.map(\.id) == [page.id])
    }

    @Test func aPageRowShowingAnotherKindOfPageIsNotSaved() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = try addPageRow(to: store, workspace: ws.id, overlay: HtmlOverlay(source: .markdown(path: "/tmp/notes.md")))

        #expect(store.snapshot().workspaces.first { $0.id == ws.id }?.sessions.isEmpty == true)
    }

    @Test(arguments: [
        (#"{"file":"/tmp/a.html","javascript":"yes","navigation":true}"#, PageSnapshot?.some(PageSnapshot(source: .file(path: "/tmp/a.html", grantRoot: nil), navigation: true))),
        (#"{"url":"https://example.com","grantRoot":"/tmp"}"#, PageSnapshot?.some(PageSnapshot(source: .url(URL(string: "https://example.com")!)))),
        (#"{"url":"ftp://example.com"}"#, PageSnapshot?.some(PageSnapshot(source: .unreadable(PageSnapshot.unreadableReason)))),
        (#"{"javascript":true}"#, PageSnapshot?.some(PageSnapshot(source: .unreadable(PageSnapshot.unreadableReason)))),
        (#""page""#, PageSnapshot?.some(PageSnapshot(source: .unreadable(PageSnapshot.unreadableReason)))),
        (#"{"file":42}"#, PageSnapshot?.some(PageSnapshot(source: .unreadable(PageSnapshot.unreadableReason)))),
        (#"{"slides":"/tmp/deck.key","navigation":true}"#, PageSnapshot?.some(PageSnapshot(source: .unreadable(PageSnapshot.unreadableReason)))),
        (#"{"unreadable":"kept reason","navigation":true}"#, PageSnapshot?.some(PageSnapshot(source: .unreadable("kept reason"), navigation: true))),
    ])
    func aPageDescriptorDecodesLossilyAndAnUnusableOneReadsAsUnreadable(page: String, expected: PageSnapshot?) throws {
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp","customName":"keep","page":\#(page)}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.page == expected)
        #expect(snap.customName == "keep")
    }

    @Test(arguments: [#"{"url":"ftp://example.com"}"#, #"{"javascript":true}"#, #"{"file":42}"#, #""page""#,
                      #"{"slides":"/tmp/deck.key"}"#])
    func anUnreadablePageDescriptorRestoresAFailedPageRowWithItsCompanions(page: String) throws {
        let root = UUID(), companion = UUID(), pane = UUID(), workspace = UUID()
        let json = #"{"id":"\#(root.uuidString)","cwd":"/tmp","customName":"dash","page":\#(page)}"#
        let unreadable = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        let store = makeStore()

        store.restore(from: Snapshot(workspaces: [WorkspaceSnapshot(id: workspace, name: "work", sessions: [
            unreadable,
            SessionSnapshot(id: companion, paneIdentity: pane, customName: nil, cwd: "/tmp", parentID: root),
        ])]))

        let row = try #require(store.session(withID: root))
        let shown = try #require(row.htmlOverlay)
        #expect(row.content == .page)
        #expect(row.displayName == "dash")
        #expect(shown.source == .unreadable(reason: PageSnapshot.unreadableReason))
        #expect(shown.loadState == .failed)
        #expect(shown.loadError == PageSnapshot.unreadableReason)
        #expect(row.locallyManagedPaneIdentities.isEmpty)
        #expect(store.companions(of: root).map(\.id) == [companion])
        #expect(PaneIdentityInventory.identities(in: store.workspaces.flatMap(\.sessions)) == [pane])
        #expect(store.htmlOverlayNodes(row, zoom: nil)?.first.map { [$0.file, $0.url, $0.document] } == [nil, nil, nil])
    }

    @Test func anUnreadablePageRowSurvivesASecondSave() throws {
        let root = UUID(), companion = UUID()
        let json = #"{"id":"\#(root.uuidString)","cwd":"/tmp","page":{"url":"ftp://example.com","navigation":true}}"#
        let first = makeStore()
        first.restore(from: Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
            try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8)),
            SessionSnapshot(id: companion, paneIdentity: UUID(), customName: nil, cwd: "/tmp", parentID: root),
        ])]))
        let second = makeStore()

        second.restore(from: try throughDisk(first.snapshot()))
        let saved = try throughDisk(second.snapshot()).workspaces[0].sessions

        #expect(saved.map(\.id) == [root, companion])
        #expect(saved[0].page == PageSnapshot(source: .unreadable(PageSnapshot.unreadableReason)))
        #expect(saved[0].paneIdentity == nil)
        #expect(second.session(withID: root)?.content == .page)
        #expect(second.session(withID: root)?.htmlOverlay?.loadState == .failed)
        #expect(second.companions(of: root).map(\.id) == [companion])
    }

    @Test func aSnapshotWithoutAPageDescriptorRestoresATerminal() throws {
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp"}"#
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        let store = makeStore()

        store.restore(from: Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [snap])]))

        #expect(snap.page == nil)
        #expect(store.workspaces[0].sessions[0].content == .terminal)
        #expect(store.workspaces[0].sessions[0].htmlOverlay == nil)
    }

    @Test func sessionSnapshotDecodesWithoutSplitRatio() throws {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"cwd\":\"/a\"}"
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snap.splitRatio == nil)
        #expect(snap.isSplit == nil)
        #expect(snap.fontSize == nil)
    }
}
