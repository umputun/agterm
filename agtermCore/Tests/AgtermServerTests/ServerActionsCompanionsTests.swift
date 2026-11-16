import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsCompanionsTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession(split: Bool = false) throws -> Session {
        let session = try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: "/tmp", workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
        if split { _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on") }
        return session
    }

    private func listed(_ identities: UUID...) {
        harness.runner.records = identities.enumerated().map { index, identity in
            ZmxSessionRecord(name: ZmxSupport.daemonName(for: identity), clients: 1, leaderPID: Int32(100 + index))
        }
    }

    private func observing(_ argv: [String], executable: String? = nil, path: String? = nil) {
        let root = harness.scratch.root
        harness.actions.replayObservation = { _, _ in
            RestartReplay.Observation(foreground: CommandRestore.paneForeground(argv: argv, extra: "zsh"), isDaemonLeader: false,
                                      workingDirectory: root, executablePath: executable, searchPath: path)
        }
    }

    @Test func aDuplicateStartsTheCopysPanesWithArgumentsReboundToTheCopy() async throws {
        let source = try newSession()
        listed(source.paneIdentity)
        observing(["/usr/bin/env", "AGTERM_SESSION_ID=\(source.id.uuidString)", ZmxSupport.daemonName(for: source.paneIdentity)])

        let reply = await harness.actions.duplicateAsCompanion(source.id.uuidString, window: nil, select: true)

        let copy = try harness.session(reply)
        #expect(copy.parentID == source.id)
        let argv = ["/usr/bin/env", "AGTERM_SESSION_ID=\(copy.id.uuidString)", ZmxSupport.daemonName(for: copy.paneIdentity)]
        let launch = try #require(harness.runner.launches.last)
        #expect(launch.name == ZmxSupport.daemonName(for: copy.paneIdentity))
        #expect(launch.argv == ["/bin/zsh", "-lic", ZmxReplayScript.renderEnding(commandLine: CommandRestore.shellQuotedLine(argv))])
        #expect(launch.directory == harness.scratch.root)
    }

    private func overlay(on session: Session, pane: OverlayPane? = nil, page: HtmlSource? = nil) -> ControlResponse {
        harness.actions.openSessionOverlay(session.id.uuidString, window: nil, options: ControlSessionOverlayOpenOptions(
            command: page == nil ? "top" : "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, pane: pane, page: page))
    }

    private func presenter(for session: Session) async throws -> ServerStreamsTests.Viewer {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &fds) == 0)
        harness.actions.streams.adoptPresentationStream(descriptor: fds[0], session: session.id)
        let viewer = ServerStreamsTests.Viewer(fd: fds[1])
        try viewer.send(.hello(PresentationHello(version: PresentationCodec.version, kinds: PresentationHub.supportedKinds,
                                                 mode: .presenter)))
        let snapshot = await offPool { viewer.first { if case .snapshot = $0 { true } else { false } } }
        #expect(snapshot != nil)
        try viewer.send(.presenterAcquire)
        let granted = await offPool { viewer.first { $0 == .presenterGranted || $0 == .presenterRefused } }
        #expect(granted == .presenterGranted)
        return viewer
    }

    @Test(arguments: [(nil as OverlayPane?, "a program overlay covers the session; nothing was created"),
                      (.left, "left pane is covered by a program overlay; nothing was created")])
    func aProgramOverlayHeldForAViewerRefusesTheDuplicate(pane: OverlayPane?, message: String) async throws {
        let source = try newSession()
        listed(source.paneIdentity)
        observing(["top"], executable: "/usr/bin/top")
        #expect(overlay(on: source, pane: pane).ok)

        let reply = await harness.actions.duplicateAsCompanion(source.id.uuidString, window: nil, select: false)

        #expect(reply == ControlResponse(ok: false, error: message))
        #expect(harness.store.companions(of: source.id).isEmpty)
    }

    @Test func aPageShownOverTheSessionLeavesTheDuplicateToTheShell() async throws {
        let source = try newSession()
        listed(source.paneIdentity)
        observing(["top"], executable: "/usr/bin/top")
        let viewer = try await presenter(for: source)
        defer { viewer.disconnect() }
        #expect(overlay(on: source, page: .url(try #require(URL(string: "https://example.com")))).ok)
        #expect(source.remoteOverlays.slot(nil)?.page != nil)

        let reply = await harness.actions.duplicateAsCompanion(source.id.uuidString, window: nil, select: false)

        #expect(try harness.session(reply).parentID == source.id)
    }

    @Test func aBareProgramIsCopiedByThePathItWasStartedFrom() async throws {
        let source = try newSession()
        listed(source.paneIdentity)
        let bin = harness.scratch.bin
        let tool = bin + "/tool"
        FileManager.default.createFile(atPath: tool, contents: Data(), attributes: [.posixPermissions: 0o755])
        observing(["tool", "--flag"], executable: tool, path: "/nowhere:" + bin)

        let reply = await harness.actions.duplicateAsCompanion(source.id.uuidString, window: nil, select: true)

        let copy = try harness.session(reply)
        #expect(copy.initialCommand == CommandRestore.shellQuotedLine([tool, "--flag"]))
    }

    @Test func aSplitSourceCopiesBothPanes() async throws {
        let source = try newSession(split: true)
        let split = try #require(source.splitPaneIdentity)
        listed(source.paneIdentity, split)
        observing(["/usr/bin/top"])

        let reply = await harness.actions.duplicateAsCompanion(source.id.uuidString, window: nil, select: true)

        let copy = try harness.session(reply)
        let copySplit = try #require(copy.splitPaneIdentity)
        #expect(harness.runner.launches.suffix(2).map(\.name)
            == [ZmxSupport.daemonName(for: copy.paneIdentity), ZmxSupport.daemonName(for: copySplit)])
        #expect(copy.daemonBackedPanes == [copy.paneIdentity, copySplit])
    }

    @Test(arguments: [(["/usr/bin/tmux", "attach"], "left pane: tmux is on the restore denylist; nothing was created"),
                      (["tool"], "left pane: the foreground program's executable path cannot be read; nothing was created")])
    func aPaneItCannotCopyCreatesNothing(argv: [String], message: String) async throws {
        let source = try newSession()
        listed(source.paneIdentity)
        observing(argv)
        let count = harness.store.workspaces.flatMap(\.sessions).count

        let reply = await harness.actions.duplicateAsCompanion(source.id.uuidString, window: nil, select: true)

        #expect(reply.error == message)
        #expect(harness.store.workspaces.flatMap(\.sessions).count == count)
    }

    @Test func aPaneWithNoListedDaemonIsRefused() async throws {
        let source = try newSession()
        harness.runner.records = []

        let reply = await harness.actions.duplicateAsCompanion(source.id.uuidString, window: nil, select: true)

        #expect(reply.error == "left pane is not running; nothing was created")
    }

    @Test func aCompanionMovesUnderAnotherSessionAtTheServersIndex() async throws {
        let session = try newSession()
        let companion = try harness.session(await harness.actions.createCompanion(session.id.uuidString, options: CompanionOptions(select: false),
                                                                                  window: nil))
        let destination = try newSession()
        var residents: [Session] = []
        for _ in 0..<2 {
            residents.append(try harness.session(await harness.actions.createCompanion(destination.id.uuidString,
                                                                                       options: CompanionOptions(select: false), window: nil)))
        }
        let launches = harness.runner.launches.count

        let reply = await harness.actions.moveCompanion(companion.id.uuidString, parent: String(destination.id.uuidString.prefix(8)),
                                                        index: 1, window: nil)

        #expect(reply.ok, "\(reply)")
        #expect(reply.result?.parent == destination.id.uuidString)
        #expect(harness.store.companions(of: destination.id).map(\.id) == [residents[0].id, companion.id, residents[1].id])
        #expect(harness.runner.launches.count == launches, "a move starts no pane")
    }

    @Test func aCompanionMoveRefusesWhatTheStoreRefuses() async throws {
        let session = try newSession()
        let companion = try harness.session(await harness.actions.createCompanion(session.id.uuidString, options: CompanionOptions(select: false),
                                                                                  window: nil))

        let underCompanion = await harness.actions.moveCompanion(session.id.uuidString, parent: companion.id.uuidString, index: nil, window: nil)
        let unknown = await harness.actions.moveCompanion(companion.id.uuidString, parent: UUID().uuidString, index: nil, window: nil)

        #expect(underCompanion.error == CompanionMoveRefusal.notCompanion.message)
        #expect(unknown.ok == false)
        #expect(companion.parentID == session.id)
    }

    @Test func aConvertStartsTheFreshParent() throws {
        let session = try newSession()
        let launches = harness.runner.launches.count

        let reply = harness.actions.convertToCompanion(session.id.uuidString, window: nil)

        let parent = try #require(reply.result?.parent.flatMap(UUID.init(uuidString:)).flatMap(harness.store.session(withID:)))
        #expect(session.parentID == parent.id)
        #expect(harness.runner.launches.count == launches + 1)
        #expect(harness.runner.launches.last?.name == ZmxSupport.daemonName(for: parent.paneIdentity))
    }

    @Test func aConvertWhoseParentCannotStartRegroupsAndEndsNothingItHeld() async throws {
        let session = try newSession()
        let companion = try harness.session(await harness.actions.createCompanion(session.id.uuidString, options: CompanionOptions(),
                                                                                  window: nil))
        let other = try newSession()
        harness.store.selectSession(other.id)
        let order = harness.store.workspaces.flatMap(\.sessions).map(\.id)
        harness.runner.failure = "zmx is gone"

        let reply = harness.actions.convertToCompanion(session.id.uuidString, window: nil)

        #expect(reply.error == "could not start the pane: zmx is gone")
        #expect(session.parentID == nil)
        #expect(companion.parentID == session.id)
        #expect(harness.store.workspaces.flatMap(\.sessions).map(\.id) == order)
        #expect(harness.store.selectedSessionID == other.id)
        let held = [session.paneIdentity, companion.paneIdentity].map(ZmxSupport.daemonName(for:))
        #expect(harness.runner.kills.allSatisfy { !held.contains($0) })
        #expect(session.daemonBackedPanes.contains(session.paneIdentity))
    }

    // regression: a catalog with nothing selected kept the target selected after the convert failed.
    @Test func aFailedConvertLeavesNothingSelectedWhenNothingWas() throws {
        let session = try newSession()
        harness.store.selectSession(nil)
        harness.runner.failure = "zmx is gone"

        _ = harness.actions.convertToCompanion(session.id.uuidString, window: nil)

        #expect(harness.store.selectedSessionID == nil)
        #expect(session.parentID == nil)
    }
}
