import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerCatalogTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private var hub: CatalogHub { harness.actions.streams.catalogHub }

    private final class Sink: CatalogSink {
        var frames: [CatalogFrame] = []

        func offer(_ frame: CatalogFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: CatalogHub.CloseReason) {}

        var changes: [CatalogChange] {
            frames.compactMap { frame in
                guard case .delta(_, _, let change) = frame else { return nil }
                return change
            }
        }
    }

    private func subscribe() throws -> Sink {
        let sink = Sink()
        try hub.subscribe(hello: CatalogHello(version: 1), sink: sink, versions: harness.actions.catalogVersions)
        return sink
    }

    private func serve(_ cmd: Command, target: String? = nil, args: ControlArgs? = nil) async -> ControlResponse {
        await harness.actions.serve(ControlRequest(cmd: cmd, target: target, args: args))
    }

    private func newSession() async throws -> Session {
        try harness.session(await serve(.sessionNew))
    }

    @Test func theLiveCatalogCarriesTheScratchAndTheSavedStoreDoesNot() async throws {
        let session = try await newSession()
        _ = await serve(.sessionScratch, target: session.id.uuidString, args: ControlArgs(mode: "on"))
        let identity = try #require(session.scratchDaemon?.identity)

        let projected = try #require(hub.snapshot().workspaces.flatMap(\.sessions).first { $0.id == session.id })
        let saved = String(decoding: try JSONEncoder().encode(harness.store.snapshot()), as: UTF8.self)

        #expect(projected.fields.scratch?.shown == true)
        #expect(projected.fields.scratch?.pane.identity == identity)
        #expect(projected.fields.scratch?.pane.daemon == ZmxSupport.scratchDaemonName(for: identity))
        #expect(projected.panes.map(\.identity) == [session.paneIdentity])
        #expect(!saved.contains(identity.uuidString))
    }

    @Test func hidingTheScratchPublishesASessionChange() async throws {
        let session = try await newSession()
        _ = await serve(.sessionScratch, target: session.id.uuidString, args: ControlArgs(mode: "on"))
        let sink = try subscribe()

        _ = await serve(.sessionScratch, target: session.id.uuidString, args: ControlArgs(mode: "off"))

        guard case .sessionChanged(let fields)? = sink.changes.last else { Issue.record("no session change"); return }
        #expect(fields.scratch?.shown == false)
    }

    @Test func versionAdvertisesTheServerProtocolAndCatalogVersions() async {
        let reply = await serve(.version)

        #expect(reply.result?.versions == CatalogVersions(server: "1.2.3", protocolVersion: PresentationCodec.version,
                                                          catalog: CatalogCodec.version))
    }

    @Test func theSnapshotCarriesTheCatalogItsVersionsAndEveryPane() async throws {
        let session = try await newSession()
        _ = await serve(.sessionSplit, target: session.id.uuidString, args: ControlArgs(mode: "on"))
        let split = try #require(session.splitPaneIdentity)

        let snapshot = hub.snapshot()

        let projected = try #require(snapshot.workspaces.first?.sessions.first { $0.id == session.id })
        #expect(snapshot.catalogID == harness.catalog.id)
        #expect(snapshot.versions == harness.actions.catalogVersions)
        #expect(projected.panes.map(\.identity) == [session.paneIdentity, split])
        #expect(projected.panes.map(\.daemon) == [ZmxSupport.daemonName(for: session.paneIdentity), ZmxSupport.daemonName(for: split)])
        #expect(projected.panes.first?.endpoint.socketDirectory == harness.panes.configuration.zmxSocketDirectory)
        #expect(projected.fields.axis == "vertical")
        #expect(projected.fields.shown)
        #expect(projected.fields.lifecycle == .live)
    }

    @Test func aCompanionCarriesItsParent() async throws {
        let parent = try await newSession()
        let reply = await serve(.sessionCompanionNew, target: parent.id.uuidString)
        let companion = try harness.session(reply)

        let projected = hub.snapshot().workspaces.flatMap(\.sessions).first { $0.id == companion.id }

        #expect(projected?.fields.parent == parent.id)
    }

    @Test func eachServedStructuralCommandPublishesItsChange() async throws {
        let sink = try subscribe()
        let session = try await newSession()
        _ = await serve(.sessionRename, target: session.id.uuidString, args: ControlArgs(name: "build"))
        _ = await serve(.sessionSplit, target: session.id.uuidString, args: ControlArgs(mode: "on"))
        _ = await serve(.sessionSwap, target: session.id.uuidString)
        _ = await serve(.sessionSplitClose, target: session.id.uuidString)
        let workspace = await serve(.workspaceNew, args: ControlArgs(name: "dev"))
        let workspaceID = try #require(workspace.result?.id)
        _ = await serve(.workspaceRename, target: workspaceID, args: ControlArgs(name: "ops"))
        _ = await serve(.sessionMove, target: session.id.uuidString, args: ControlArgs(workspace: workspaceID))
        _ = await serve(.workspaceMove, target: workspaceID, args: ControlArgs(to: "top"))
        _ = await serve(.sessionClose, target: session.id.uuidString)
        _ = await serve(.workspaceDelete, target: workspaceID)

        #expect(sink.changes.map(\.kind) == [
            "session.added",
            "session.changed",
            "pane.added", "session.changed",
            "session.changed",
            "pane.removed", "session.changed",
            "workspace.added",
            "workspace.changed",
            "session.moved",
            "workspace.order",
            "session.removed",
            "workspace.removed",
        ])
        let revisions = sink.frames.compactMap { frame -> Int? in
            guard case .delta(_, let rev, _) = frame else { return nil }
            return rev
        }
        #expect(revisions == Array(1...revisions.count))
    }

    @Test func aRefusedCommandPublishesNothing() async throws {
        let sink = try subscribe()

        let reply = await serve(.sessionRename, target: UUID().uuidString, args: ControlArgs(name: "x"))

        #expect(!reply.ok)
        #expect(sink.changes.isEmpty)
    }

    @Test func aLostDaemonPublishesTheSessionEndedWithItsPaneGone() async throws {
        let session = try await newSession()
        let observer = PaneObserver(store: harness.store, panes: harness.panes, cwd: { _ in nil })
        observer.onApplied = { [hub] in hub.refresh() }
        let sink = try subscribe()

        observer.apply([], listedAt: Date().addingTimeInterval(1))

        #expect(session.ended)
        #expect(sink.changes.map(\.kind) == ["pane.removed", "session.changed"])
        guard case .sessionChanged(let fields)? = sink.changes.last else { Issue.record("no session change"); return }
        #expect(fields.lifecycle == .ended)
    }

    @Test func aCwdTheObserverReadsIsPublished() async throws {
        let session = try await newSession()
        let observer = PaneObserver(store: harness.store, panes: harness.panes, cwd: { _ in "/srv/app" })
        observer.onApplied = { [hub] in hub.refresh() }
        let sink = try subscribe()

        observer.apply([ZmxSessionRecord(name: ZmxSupport.daemonName(for: session.paneIdentity), clients: 0, leaderPID: 42)],
                       listedAt: Date().addingTimeInterval(1))

        guard case .sessionChanged(let fields)? = sink.changes.last else { Issue.record("no session change"); return }
        #expect(fields.cwd == "/srv/app")
    }

    @Test func aStreamOverTheSocketGetsTheSnapshotThenADelta() async throws {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &fds) == 0)
        defer { close(fds[1]) }
        harness.actions.streams.adoptCatalogStream(descriptor: fds[0])
        let viewer = fds[1]
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(viewer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try sendNoSignal(viewer, try CatalogCodec.encode(.hello(CatalogHello(version: 1))))

        let opening = await offPool { [Self.readFrame(viewer), Self.readFrame(viewer)] }
        _ = try await newSession()
        let delta = await offPool { Self.readFrame(viewer) }

        guard case .hello(let hello)? = opening[0], case .snapshot(let snapshot)? = opening[1] else {
            Issue.record("unexpected opening \(opening)")
            return
        }
        #expect(hello.epoch == hub.epoch)
        #expect(hello.versions == harness.actions.catalogVersions)
        #expect(snapshot.epoch == hub.epoch)
        guard case .delta(let epoch, let rev, .sessionAdded)? = delta else {
            Issue.record("unexpected delta \(String(describing: delta))")
            return
        }
        #expect(epoch == hub.epoch)
        #expect(rev == snapshot.rev + 1)
    }

    @Test func eachServerRunHasItsOwnEpoch() throws {
        let other = try ServerHarness()

        #expect(other.actions.streams.catalogHub.epoch != hub.epoch)
    }

    @Test func catalogSubscribeIsServed() {
        #expect(ServerCommandPolicy.refusal(.catalogSubscribe) == nil)
    }

    @Test func aServerOpensNoRemoteWindows() async {
        let direct = await harness.actions.windowRemoteOpen(host: "buildbox")

        #expect(ServerCommandPolicy.refusal(.windowRemoteOpen)
            == "window.remote.open is not available on agterm-server: it drives a window on the Mac showing it")
        #expect(direct.ok == false)
    }

    private nonisolated static func readFrame(_ fd: Int32) -> CatalogFrame? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            guard byte == UInt8(ascii: "\n") else {
                bytes.append(byte)
                continue
            }
            return try? CatalogCodec.decode(Data(bytes))
        }
        return nil
    }
}
