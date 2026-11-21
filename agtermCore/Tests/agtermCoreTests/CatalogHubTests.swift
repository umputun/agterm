import Foundation
import Testing
@testable import agtermCore

enum CatalogFixture {
    static let endpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/zmx")
    static let versions = CatalogVersions(server: "1.2.3", protocolVersion: 1, catalog: 1)
    static let catalog = UUID()

    static func pane(_ id: UUID = UUID(), daemon: String? = nil) -> CatalogPane {
        CatalogPane(identity: id, daemon: daemon ?? "agterm-\(id.uuidString)", endpoint: endpoint)
    }

    static func session(_ id: UUID = UUID(), name: String = "s", panes: [CatalogPane]? = nil, cwd: String = "/home",
                        ended: Bool = false, parent: UUID? = nil) -> CatalogSession {
        let panes = panes ?? [CatalogFixture.pane()]
        let fields = CatalogSessionFields(id: id, name: name, parent: parent, cwd: cwd, primary: panes.first?.identity ?? UUID(),
                                          axis: panes.count > 1 ? "vertical" : nil, shown: panes.count > 1,
                                          lifecycle: ended ? .ended : .live)
        return CatalogSession(fields: fields, panes: panes)
    }

    static func pageRow(_ id: UUID = UUID(), name: String = "page", parent: UUID? = nil) -> CatalogSession {
        let fields = CatalogSessionFields(id: id, name: name, parent: parent, cwd: "/home", primary: id, axis: nil, shown: false,
                                          lifecycle: .live, page: CatalogPage(kind: "url", identity: "example.com", endpoint: endpoint))
        return CatalogSession(fields: fields, panes: [])
    }

    static func snapshot(_ workspaces: [CatalogWorkspace]) -> CatalogSnapshot {
        CatalogSnapshot(epoch: "e1", rev: 0, catalogID: catalog, versions: versions, workspaces: workspaces)
    }

    static func transitions() -> [(String, [CatalogWorkspace], [CatalogWorkspace])] {
        let a = CatalogFixture.session(name: "a"), b = CatalogFixture.session(name: "b"), c = CatalogFixture.session(name: "c")
        let left = CatalogFixture.pane(), right = CatalogFixture.pane()
        let split = CatalogFixture.session(panes: [left, right])
        var swapped = split
        swapped.fields.primary = right.identity
        swapped.normalize()
        var renamed = a
        renamed.fields.name = "renamed"
        var ended = a
        ended.fields.lifecycle = .ended
        ended.panes = []
        var moved = a
        moved.fields.cwd = "/tmp"
        let w1 = UUID(), w2 = UUID()
        return [
            ("first workspace", [], [CatalogWorkspace(id: w1, name: "w1", sessions: [a])]),
            ("workspace renamed", [CatalogWorkspace(id: w1, name: "w1", sessions: [])], [CatalogWorkspace(id: w1, name: "dev", sessions: [])]),
            ("workspace removed with its sessions", [CatalogWorkspace(id: w1, name: "w1", sessions: [a]), CatalogWorkspace(id: w2, name: "w2", sessions: [])],
             [CatalogWorkspace(id: w2, name: "w2", sessions: [])]),
            ("workspaces reordered", [CatalogWorkspace(id: w1, name: "w1", sessions: []), CatalogWorkspace(id: w2, name: "w2", sessions: [])],
             [CatalogWorkspace(id: w2, name: "w2", sessions: []), CatalogWorkspace(id: w1, name: "w1", sessions: [])]),
            ("session added in the middle", [CatalogWorkspace(id: w1, name: "w1", sessions: [a, c])], [CatalogWorkspace(id: w1, name: "w1", sessions: [a, b, c])]),
            ("sessions reordered", [CatalogWorkspace(id: w1, name: "w1", sessions: [a, b, c])], [CatalogWorkspace(id: w1, name: "w1", sessions: [c, a, b])]),
            ("session moved to another workspace", [CatalogWorkspace(id: w1, name: "w1", sessions: [a, b]), CatalogWorkspace(id: w2, name: "w2", sessions: [c])],
             [CatalogWorkspace(id: w1, name: "w1", sessions: [b]), CatalogWorkspace(id: w2, name: "w2", sessions: [a, c])]),
            ("session moved into a new workspace", [CatalogWorkspace(id: w1, name: "w1", sessions: [a, b])],
             [CatalogWorkspace(id: w1, name: "w1", sessions: [b]), CatalogWorkspace(id: w2, name: "w2", sessions: [a])]),
            ("session renamed and its cwd changed", [CatalogWorkspace(id: w1, name: "w1", sessions: [a])],
             [CatalogWorkspace(id: w1, name: "w1", sessions: [{ var s = renamed; s.fields.cwd = moved.fields.cwd; return s }()])]),
            ("split added", [CatalogWorkspace(id: w1, name: "w1", sessions: [CatalogFixture.session(split.id, panes: [left])])],
             [CatalogWorkspace(id: w1, name: "w1", sessions: [split])]),
            ("split closed", [CatalogWorkspace(id: w1, name: "w1", sessions: [split])],
             [CatalogWorkspace(id: w1, name: "w1", sessions: [CatalogFixture.session(split.id, panes: [left])])]),
            ("panes swapped", [CatalogWorkspace(id: w1, name: "w1", sessions: [split])], [CatalogWorkspace(id: w1, name: "w1", sessions: [swapped])]),
            ("session ended", [CatalogWorkspace(id: w1, name: "w1", sessions: [a])], [CatalogWorkspace(id: w1, name: "w1", sessions: [ended])]),
            ("pane daemon changed", [CatalogWorkspace(id: w1, name: "w1", sessions: [CatalogFixture.session(a.id, panes: [CatalogFixture.pane(left.identity, daemon: "old")])])],
             [CatalogWorkspace(id: w1, name: "w1", sessions: [CatalogFixture.session(a.id, panes: [CatalogFixture.pane(left.identity, daemon: "new")])])]),
            ("everything at once", [CatalogWorkspace(id: w1, name: "w1", sessions: [a, b, split]), CatalogWorkspace(id: w2, name: "w2", sessions: [c])],
             [CatalogWorkspace(id: w2, name: "x", sessions: [swapped, c, a]), CatalogWorkspace(id: UUID(), name: "new", sessions: [CatalogFixture.session()])]),
        ]
    }
}

@MainActor
struct CatalogHubTests {
    private final class Sink: CatalogSink {
        var frames: [CatalogFrame] = []
        var closed: [CatalogHub.CloseReason] = []
        var accepts = true

        func offer(_ frame: CatalogFrame) -> Bool {
            guard accepts else { return false }
            frames.append(frame)
            return true
        }

        func close(_ reason: CatalogHub.CloseReason) { closed.append(reason) }

        var deltas: [(rev: Int, change: CatalogChange)] {
            frames.compactMap { frame in
                guard case .delta(_, let rev, let change) = frame else { return nil }
                return (rev, change)
            }
        }
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1000)
    }

    @Test func aSubscriberGetsHelloThenTheSnapshotThenNumberedDeltas() throws {
        var workspaces = [CatalogWorkspace(id: UUID(), name: "w", sessions: [CatalogFixture.session(name: "a")])]
        let hub = CatalogHub(epoch: "e1", staleTimeout: 30) { CatalogFixture.snapshot(workspaces) }
        let sink = Sink()

        try hub.subscribe(hello: CatalogHello(version: 1), sink: sink, versions: CatalogFixture.versions)
        workspaces[0].sessions.append(CatalogFixture.session(name: "b"))
        hub.refresh()
        workspaces[0].name = "dev"
        hub.refresh()

        guard sink.frames.count == 4, case .hello(let hello) = sink.frames[0], case .snapshot(let snapshot) = sink.frames[1] else {
            Issue.record("unexpected frames \(sink.frames)")
            return
        }
        #expect(hello == CatalogHello(version: 1, epoch: "e1", versions: CatalogFixture.versions))
        #expect(snapshot.rev == 0)
        #expect(snapshot.epoch == "e1")
        #expect(sink.deltas.map(\.rev) == [1, 2])
        #expect(sink.deltas.map(\.change.kind) == ["session.added", "workspace.changed"])
    }

    @Test func aChangeMadeBeforeSubscribingIsInTheSnapshotAndNeverRepeatedAsADelta() throws {
        var workspaces = [CatalogWorkspace(id: UUID(), name: "w", sessions: [])]
        let hub = CatalogHub(epoch: "e1", staleTimeout: 30) { CatalogFixture.snapshot(workspaces) }
        let early = Sink()
        try hub.subscribe(hello: CatalogHello(version: 1), sink: early, versions: CatalogFixture.versions)
        workspaces[0].sessions.append(CatalogFixture.session())
        let late = Sink()

        try hub.subscribe(hello: CatalogHello(version: 1), sink: late, versions: CatalogFixture.versions)

        guard case .snapshot(let snapshot) = late.frames.last else {
            Issue.record("no snapshot")
            return
        }
        #expect(snapshot.rev == 1)
        #expect(snapshot.workspaces == workspaces)
        #expect(late.deltas.isEmpty)
        #expect(early.deltas.map(\.rev) == [1])
    }

    @Test func aRefreshThatChangesNothingPublishesNothing() throws {
        let workspaces = [CatalogWorkspace(id: UUID(), name: "w", sessions: [CatalogFixture.session()])]
        let hub = CatalogHub(epoch: "e1", staleTimeout: 30) { CatalogFixture.snapshot(workspaces) }
        let sink = Sink()
        try hub.subscribe(hello: CatalogHello(version: 1), sink: sink, versions: CatalogFixture.versions)

        hub.refresh()
        hub.refresh()

        #expect(sink.frames.count == 2)
        #expect(hub.rev == 0)
    }

    @Test func aViewerSpeakingNoVersionIsRefused() {
        let hub = CatalogHub(epoch: "e1", staleTimeout: 30) { CatalogFixture.snapshot([]) }

        #expect(throws: CatalogHub.SubscribeError.unsupportedVersion(0)) {
            try hub.subscribe(hello: CatalogHello(version: 0), sink: Sink(), versions: CatalogFixture.versions)
        }
    }

    @Test func aStalledSubscriberIsDroppedAndTheOthersKeepTheirDeltas() throws {
        var workspaces: [CatalogWorkspace] = []
        let hub = CatalogHub(epoch: "e1", staleTimeout: 30) { CatalogFixture.snapshot(workspaces) }
        let stalled = Sink(), healthy = Sink()
        try hub.subscribe(hello: CatalogHello(version: 1), sink: stalled, versions: CatalogFixture.versions)
        try hub.subscribe(hello: CatalogHello(version: 1), sink: healthy, versions: CatalogFixture.versions)
        stalled.accepts = false

        workspaces.append(CatalogWorkspace(id: UUID(), name: "w", sessions: []))
        hub.refresh()

        #expect(stalled.closed == [.stalled])
        #expect(healthy.deltas.count == 1)
        #expect(hub.subscriberCount == 1)
    }

    @Test func aSubscriberThatStopsAckingGoesStaleAndAnAckingOneIsPinged() throws {
        let clock = Clock()
        let hub = CatalogHub(epoch: "e1", staleTimeout: 30, now: { clock.now }, source: { CatalogFixture.snapshot([]) })
        let quiet = Sink(), acking = Sink()
        try hub.subscribe(hello: CatalogHello(version: 1), sink: quiet, versions: CatalogFixture.versions)
        let id = try hub.subscribe(hello: CatalogHello(version: 1), sink: acking, versions: CatalogFixture.versions)

        hub.heartbeat()
        clock.now += 20
        hub.receive(.ack, from: id)
        clock.now += 20
        hub.heartbeat()

        #expect(quiet.closed == [.stale])
        #expect(acking.frames.last == .ping)
        #expect(acking.closed.isEmpty)
    }

    // regression: a heartbeat late past the stale timeout dropped subscribers it had never given a ping to answer
    @Test func aLongGapBetweenHeartbeatsLeavesTheSubscriberAPingToAnswer() throws {
        let clock = Clock()
        let hub = CatalogHub(epoch: "e1", staleTimeout: 30, now: { clock.now }, source: { CatalogFixture.snapshot([]) })
        let sink = Sink()
        let id = try hub.subscribe(hello: CatalogHello(version: 1), sink: sink, versions: CatalogFixture.versions)

        clock.now += 60
        hub.heartbeat()
        #expect(sink.closed.isEmpty)
        hub.receive(.ack, from: id)
        clock.now += 60
        hub.heartbeat()

        #expect(sink.closed.isEmpty)
        #expect(sink.frames.filter { $0 == .ping }.count == 2)
    }

    @Test func anUnansweredPingExpiresFromItsFirstProbe() throws {
        let clock = Clock()
        let hub = CatalogHub(epoch: "e1", staleTimeout: 30, now: { clock.now }, source: { CatalogFixture.snapshot([]) })
        let sink = Sink()
        try hub.subscribe(hello: CatalogHello(version: 1), sink: sink, versions: CatalogFixture.versions)

        hub.heartbeat()
        clock.now += 20
        hub.heartbeat()
        #expect(sink.closed.isEmpty)
        clock.now += 11
        hub.heartbeat()

        #expect(sink.closed == [.stale])
    }

    private struct OlderViewer {
        var state: CatalogSnapshot?
        var gap = false

        mutating func take(_ frames: [CatalogFrame]) {
            for frame in frames {
                switch frame {
                case .snapshot(let snapshot):
                    state = snapshot
                case .delta(_, let rev, let change):
                    step(rev)
                    state?.apply(change)
                case .unknown(_, _, let rev?):
                    step(rev)
                default: break
                }
            }
        }

        private mutating func step(_ rev: Int) {
            guard let current = state?.rev else { return }
            if rev != current + 1 { gap = true }
            state?.rev = rev
        }
    }

    @Test func aViewerWithoutPageRowsFollowsEveryRevisionAndNeverSeesAPage() throws {
        let a = CatalogFixture.session(name: "a"), b = CatalogFixture.session(name: "b")
        let page = CatalogFixture.pageRow()
        let w1 = UUID(), w2 = UUID()
        var workspaces = [CatalogWorkspace(id: w1, name: "w1", sessions: [a, page, b]), CatalogWorkspace(id: w2, name: "w2", sessions: [])]
        let hub = CatalogHub(epoch: "e1", staleTimeout: 30) { CatalogFixture.snapshot(workspaces) }
        let older = Sink(), newer = Sink()
        try hub.subscribe(hello: CatalogHello(version: 1), sink: older, versions: CatalogFixture.versions)
        try hub.subscribe(hello: CatalogHello(version: 1, pageRows: true), sink: newer, versions: CatalogFixture.versions)

        workspaces[0].sessions[1].fields.name = "docs"
        hub.refresh()
        let c = CatalogFixture.session(name: "c")
        workspaces[0].sessions.insert(c, at: 2)
        hub.refresh()
        workspaces[0].sessions = [b, page, c, a]
        hub.refresh()
        workspaces[0].sessions.removeAll { $0.id == a.id }
        workspaces[1].sessions = [a]
        hub.refresh()
        workspaces[0].sessions.removeAll { $0.id == page.id }
        hub.refresh()

        var viewer = OlderViewer()
        viewer.take(older.frames)
        #expect(!viewer.gap)
        let lines = try older.frames.map { String(decoding: try CatalogCodec.encode($0), as: UTF8.self) }
        #expect(!lines.contains { $0.contains(page.id.uuidString) })
        #expect(viewer.state?.rev == hub.rev)
        #expect(viewer.state?.workspaces == CatalogHub.withoutPageRows(hub.snapshot()).workspaces)
        #expect(newer.deltas.map(\.rev) == Array(1...hub.rev))
        #expect(newer.deltas.contains { if case .sessionChanged(let fields) = $0.change { fields.page != nil } else { false } })
    }

    @Test func aPageRootsCompanionShowsTopLevelToAViewerWithoutPageRows() throws {
        let root = CatalogFixture.pageRow()
        var workspaces = [CatalogWorkspace(id: UUID(), name: "w", sessions: [root])]
        let hub = CatalogHub(epoch: "e1", staleTimeout: 30) { CatalogFixture.snapshot(workspaces) }
        let older = Sink()
        try hub.subscribe(hello: CatalogHello(version: 1), sink: older, versions: CatalogFixture.versions)

        let companion = CatalogFixture.session(name: "shell", parent: root.id)
        workspaces[0].sessions.append(companion)
        hub.refresh()

        guard case .snapshot(let first)? = older.frames.dropFirst().first else {
            Issue.record("no snapshot")
            return
        }
        #expect(first.workspaces[0].sessions.isEmpty)
        guard case .sessionAdded(let added, _, _)? = older.deltas.first?.change else {
            Issue.record("no added companion: \(older.frames)")
            return
        }
        #expect(added.id == companion.id && added.fields.parent == nil)
    }

    @Test func aFilteredChangeListLongerThanTheRevisionsGoesAsAFilteredSnapshot() throws {
        let root = CatalogFixture.pageRow()
        let first = CatalogFixture.session(name: "one", parent: root.id), second = CatalogFixture.session(name: "two", parent: root.id)
        var workspaces = [CatalogWorkspace(id: UUID(), name: "w", sessions: [root, first, second])]
        let hub = CatalogHub(epoch: "e1", staleTimeout: 30) { CatalogFixture.snapshot(workspaces) }
        let older = Sink()
        try hub.subscribe(hello: CatalogHello(version: 1), sink: older, versions: CatalogFixture.versions)

        workspaces[0].sessions.removeFirst()
        hub.refresh()

        guard hub.rev == 1, case .snapshot(let snapshot)? = older.frames.last else {
            Issue.record("no filtered snapshot: \(older.frames)")
            return
        }
        #expect(snapshot.rev == 1)
        #expect(snapshot.workspaces == CatalogHub.withoutPageRows(hub.snapshot()).workspaces)
    }

    @Test func aPingIsAnsweredWithAnAck() throws {
        let hub = CatalogHub(epoch: "e1", staleTimeout: 30) { CatalogFixture.snapshot([]) }
        let sink = Sink()
        let id = try hub.subscribe(hello: CatalogHello(version: 1), sink: sink, versions: CatalogFixture.versions)

        hub.receive(.ping, from: id)

        #expect(sink.frames.last == .ack)
    }

}
