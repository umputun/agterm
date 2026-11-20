import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `ControlServer`'s workspace commands, which resolve a target against the real
/// window library before touching the store.
@MainActor
final class ControlServerWorkspaceCommandsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-workspace-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            let actions = AppActions(library: library)
            server = ControlServer(
                library: library,
                actions: actions,
                settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                bundleURL: stateDir.appendingPathComponent("Installed.app", isDirectory: true),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            server = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    // the workspace's first session may already be the selected one, so selecting through the store's
    // own `selectWorkspace` is what makes the command retarget rather than report a lie
    func testSelectingTheWorkspaceOwningTheSelectionDropsTheFreshWorkspace() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        // the command selects the workspace's FIRST session, so that is the one that must already be
        // selected for this to be the same-value case
        let session = try XCTUnwrap(store.workspaces.first { $0.id == owner }?.sessions.first)
        store.selectSession(session.id)
        let fresh = store.addWorkspace(name: "fresh")
        XCTAssertEqual(store.currentWorkspaceID, fresh.id)

        let response = server.selectWorkspace(owner.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.id, owner.uuidString)
        XCTAssertEqual(store.selectedSessionID, session.id)
        XCTAssertEqual(store.currentWorkspaceID, owner)
    }

    // both projections must be the SAME injected identity, not two independent bundle reads
    func testVersionAndTreeReportTheInjectedIdentity() throws {
        let injected = AppIdentity(version: "9.9.9", commit: "testsha")

        let version = server.appIdentity()
        XCTAssertTrue(version.ok, version.error ?? "")
        XCTAssertEqual(version.result?.app, injected)

        let tree = server.controlTree(window: nil)
        XCTAssertTrue(tree.ok, tree.error ?? "")
        XCTAssertEqual(tree.result?.tree?.app, injected)
    }

    func testVersionRereadsInstalledMetadataWhileTheRunningIdentityStaysFixed() throws {
        let running = AppIdentity(version: "9.9.9", commit: "testsha")
        let contents = stateDir.appendingPathComponent("Installed.app/Contents", isDirectory: true)
        let plist = contents.appendingPathComponent("Info.plist")
        func writeInstalled(version: String, commit: String) throws {
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleShortVersionString": version, "GitCommit": commit]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        }

        XCTAssertNil(server.appIdentity().result?.installed)

        try writeInstalled(version: "9.9.9", commit: "testsha")
        XCTAssertEqual(server.appIdentity().result?.installed, running)

        try writeInstalled(version: "10.0.0", commit: "newsha")
        let replaced = server.appIdentity()
        XCTAssertTrue(replaced.ok, replaced.error ?? "")
        XCTAssertEqual(replaced.result?.installed, AppIdentity(version: "10.0.0", commit: "newsha"))
        XCTAssertEqual(replaced.result?.app, running)

        try FileManager.default.removeItem(at: plist)
        let removed = server.appIdentity()
        XCTAssertTrue(removed.ok, removed.error ?? "")
        XCTAssertNil(removed.result?.installed)
        XCTAssertEqual(removed.result?.app, running)
    }

    func testSelectingAnEmptyWorkspaceReportsAndTargetsIt() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(session.id)
        let empty = store.addWorkspace(name: "empty", revealNewWorkspace: false)

        let response = server.selectWorkspace(empty.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.id, empty.id.uuidString)
        XCTAssertEqual(store.selectedSessionID, session.id, "an empty workspace has nothing to select")
        XCTAssertEqual(store.currentWorkspaceID, empty.id)
    }

    func testSelectingAFilteredOutEmptyWorkspaceRevealsIt() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let empty = store.addWorkspace(name: "empty", revealNewWorkspace: false)
        let other = store.addWorkspace(name: "other", revealNewWorkspace: false)
        store.setFocusMembership(owner, member: true)
        store.setFocusEnabled(true)
        XCTAssertEqual(store.visibleWorkspaces.map(\.id), [owner])

        let response = server.selectWorkspace(empty.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.currentWorkspaceID, empty.id)
        XCTAssertEqual(store.visibleWorkspaces.map(\.id), [owner, empty.id], "the target must be on screen")
        XCTAssertTrue(store.focusEnabled, "the filter must widen, not switch off")
        XCTAssertFalse(store.focusedWorkspaceIDs.contains(other.id), "an unrelated workspace stays filtered out")
    }

    func testWorkspaceOnlyCommandsRefuseTheRootByIdPrefixAndActive() throws {
        let store = try XCTUnwrap(library.activeStore)
        store.addWorkspace(name: "second")
        let root = try XCTUnwrap(store.rootWorkspace)
        let top = try XCTUnwrap(store.addSession(toWorkspace: root.id, cwd: "/tmp"))
        store.selectSession(top.id)
        let refusal = "top-level sessions are not a workspace"

        for target in [root.id.uuidString, String(root.id.uuidString.prefix(8)), "active", "root"] {
            XCTAssertEqual(server.selectWorkspace(target, window: nil).error, refusal, target)
            XCTAssertEqual(server.renameWorkspace(target, window: nil, name: "x").error, refusal, target)
            XCTAssertEqual(server.deleteWorkspace(target, window: nil).error, refusal, target)
            XCTAssertEqual(server.moveWorkspace(target, window: nil, direction: .top).error, refusal, target)
            XCTAssertEqual(server.setWorkspaceExpansion(target, window: nil, expanded: false).error, refusal, target)
            XCTAssertEqual(server.setWorkspaceTint(target, window: nil, update: .set(.red, parts: nil)).error, refusal, target)
            XCTAssertEqual(server.detachWorkspace(target, window: nil).error, refusal, target)
        }
        XCTAssertEqual(store.workspaces.last?.id, root.id)
        XCTAssertEqual(store.rootWorkspace?.name, "")
    }

    func testTheRootTargetCreatesASessionInTheRootOfTheFrontmostWindow() throws {
        let store = try XCTUnwrap(library.activeStore)
        let root = try XCTUnwrap(store.rootWorkspace).id

        let created = server.createSession(ControlSessionCreateOptions(
            window: nil, cwd: "/tmp", workspace: "root", workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: true))

        let id = try XCTUnwrap(created.result?.id.flatMap(UUID.init(uuidString:)), created.error ?? "")
        XCTAssertEqual(store.workspace(forSession: id)?.id, root)
    }

    func testSessionMoveByTheRootTargetRelocatesOneAndSeveralSessions() throws {
        let store = try XCTUnwrap(library.activeStore)
        let named = try XCTUnwrap(store.namedWorkspaces.first).id
        let ids = try (0..<3).map { _ in try XCTUnwrap(store.addSession(toWorkspace: named, cwd: "/tmp")).id }

        let single = server.moveSession(ids[0].uuidString, window: nil, move: .workspace("root"))
        let batch = server.moveSessions(ids[1...].map(\.uuidString), window: nil, move: .workspace("root"))

        XCTAssertTrue(single.ok, single.error ?? "")
        XCTAssertEqual(batch.result?.affected, 2, batch.error ?? "")
        XCTAssertEqual(store.rootWorkspace?.sessions.map(\.id), ids)
    }

    func testAnchoredAndStepMovesStayAmongTheTopLevelSessions() throws {
        let store = try XCTUnwrap(library.activeStore)
        let root = try XCTUnwrap(store.rootWorkspace).id
        let first = try XCTUnwrap(store.addSession(toWorkspace: root, cwd: "/tmp")).id
        let second = try XCTUnwrap(store.addSession(toWorkspace: root, cwd: "/tmp")).id
        let named = try XCTUnwrap(store.namedWorkspaces.first?.sessions.first).id

        XCTAssertTrue(server.moveSession(named.uuidString, window: nil, move: .place(anchor: first.uuidString, after: true)).ok)
        XCTAssertEqual(store.rootWorkspace?.sessions.map(\.id), [first, named, second])
        XCTAssertTrue(server.moveSession(second.uuidString, window: nil, move: .reorder(.top)).ok)
        XCTAssertTrue(server.moveSession(first.uuidString, window: nil, move: .reorder(.down)).ok)
        XCTAssertEqual(store.rootWorkspace?.sessions.map(\.id), [second, named, first])
        XCTAssertTrue(server.moveSession(first.uuidString, window: nil, move: .reorder(.up)).ok)
        XCTAssertTrue(server.moveSession(second.uuidString, window: nil, move: .reorder(.bottom)).ok)
        XCTAssertTrue(server.moveSession(named.uuidString, window: nil, move: .place(anchor: first.uuidString, after: false)).ok)

        XCTAssertEqual(store.rootWorkspace?.sessions.map(\.id), [named, first, second])
    }

    func testWorkspaceFocusAndFlagActOnTheRootByItsTargetAndAsActive() throws {
        let store = try XCTUnwrap(library.activeStore)
        let root = try XCTUnwrap(store.rootWorkspace).id
        let top = try XCTUnwrap(store.addSession(toWorkspace: root, cwd: "/tmp"))
        let companion = try store.addCompanion(to: top.id, options: CompanionOptions(cwd: "/tmp")).get()
        store.selectSession(top.id)

        XCTAssertEqual(server.focusWorkspace("root", window: nil, mode: .on).result?.id, root.uuidString)
        XCTAssertEqual(store.soleFocusedWorkspaceID, root)
        XCTAssertTrue(server.focusWorkspace("root", window: nil, mode: .toggle).ok)
        XCTAssertTrue(store.focusedWorkspaceIDs.isEmpty)
        XCTAssertTrue(server.focusWorkspace("active", window: nil, mode: .add).ok)
        XCTAssertEqual(store.focusedWorkspaceIDs, [root])
        XCTAssertFalse(store.focusEnabled)
        XCTAssertTrue(server.focusWorkspace("root", window: nil, mode: .off).ok)
        XCTAssertTrue(store.focusedWorkspaceIDs.isEmpty)

        XCTAssertEqual(server.setWorkspaceFlag("active", window: nil, mode: .on).result?.id, root.uuidString)
        XCTAssertTrue(top.flagged && companion.flagged)
        XCTAssertTrue(server.setWorkspaceFlag("root", window: nil, mode: .toggle).ok)
        XCTAssertFalse(top.flagged || companion.flagged)
    }

    func testWorkspaceGoFromATopLevelSessionEntersTheNamedWorkspaces() throws {
        let store = try XCTUnwrap(library.activeStore)
        let named = try XCTUnwrap(store.namedWorkspaces.first).id
        let top = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.rootWorkspace).id, cwd: "/tmp"))
        store.selectSession(top.id)

        let step = server.goWorkspace(window: nil, direction: .next)

        XCTAssertEqual(step.result?.id, named.uuidString, step.error ?? "")
    }

    func testTheLastNamedWorkspaceIsDeletedLeavingTheRoot() throws {
        let store = try XCTUnwrap(library.activeStore)
        let only = try XCTUnwrap(store.namedWorkspaces.first).id

        XCTAssertTrue(server.deleteWorkspace(only.uuidString, window: nil).ok)

        XCTAssertTrue(store.namedWorkspaces.isEmpty)
        XCTAssertNotNil(store.rootWorkspace)
    }

    func testASessionIsCreatedInAndMovedIntoTheRootByItsId() throws {
        let store = try XCTUnwrap(library.activeStore)
        let root = try XCTUnwrap(store.rootWorkspace).id
        let created = server.createSession(ControlSessionCreateOptions(
            window: nil, cwd: "/tmp", workspace: root.uuidString, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: true))
        let id = try XCTUnwrap(created.result?.id.flatMap(UUID.init(uuidString:)), created.error ?? "")
        XCTAssertEqual(store.workspace(forSession: id)?.id, root)

        let named = try XCTUnwrap(store.namedWorkspaces.first?.sessions.first)
        XCTAssertTrue(server.moveSession(named.id.uuidString, window: nil, move: .workspace(root.uuidString)).ok)
        XCTAssertEqual(store.workspace(forSession: named.id)?.id, root)
    }

}
