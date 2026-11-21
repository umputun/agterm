import Foundation
import Testing
@testable import agtermCore

struct CatalogFramesTests {
    @Test func anOversizedSnapshotGoesAsChunksAppliedOnlyAtTheirCommit() throws {
        let sessions = (0..<1500).map { CatalogFixture.session(name: "session \($0) " + String(repeating: "x", count: 100)) }
        let big = CatalogFixture.snapshot([CatalogWorkspace(id: UUID(), name: "w", sessions: sessions)])

        let frames = try CatalogCodec.snapshotFrames(big)
        var chunks = CatalogChunks()
        var assembled: CatalogSnapshot?
        for frame in frames {
            let line = try CatalogCodec.encode(frame)
            switch try CatalogCodec.decode(line.dropLast()) {
            case .chunk(let index, let data): try chunks.add(index: index, data: data)
            case .commit(let epoch, let rev, let count): assembled = try chunks.commit(epoch: epoch, rev: rev, chunks: count)
            default: Issue.record("unexpected frame")
            }
        }

        #expect(frames.count > 2)
        #expect(assembled == big)
    }

    @Test func theRootMarkerCrossesTheWireAndANamedWorkspaceCarriesNone() throws {
        let snapshot = CatalogFixture.snapshot([CatalogWorkspace(id: UUID(), name: "w", sessions: []),
                                                CatalogWorkspace(id: UUID(), name: "", root: true, sessions: [])])
        let line = try CatalogCodec.encode(.snapshot(snapshot))

        guard case .snapshot(let decoded) = try CatalogCodec.decode(line.dropLast()) else {
            Issue.record("expected a snapshot frame")
            return
        }
        #expect(decoded.workspaces.map(\.root) == [nil, true])
        #expect(String(decoding: line, as: UTF8.self).components(separatedBy: "\"root\"").count == 2)
    }

    @Test func aSmallSnapshotGoesWhole() throws {
        let small = CatalogFixture.snapshot([CatalogWorkspace(id: UUID(), name: "w", sessions: [CatalogFixture.session()])])

        #expect(try CatalogCodec.snapshotFrames(small) == [.snapshot(small)])
    }

    @Test func chunksOutOfOrderOrShortOfTheirCommitAreRefused() throws {
        var skipped = CatalogChunks()
        #expect(throws: CatalogChunks.Failure.outOfOrder(1)) { try skipped.add(index: 1, data: "AA==") }

        var short = CatalogChunks()
        try short.add(index: 0, data: Data("{}".utf8).base64EncodedString())
        #expect(throws: CatalogChunks.Failure.incomplete(expected: 2, got: 1)) {
            _ = try short.commit(epoch: "e1", rev: 0, chunks: 2)
        }
    }

    @Test func aCommitForAnotherRevisionIsRefused() throws {
        let snapshot = CatalogFixture.snapshot([])
        let data = try JSONEncoder().encode(snapshot)
        var chunks = CatalogChunks()
        try chunks.add(index: 0, data: data.base64EncodedString())

        #expect(throws: CatalogChunks.Failure.mismatched) { _ = try chunks.commit(epoch: "e1", rev: 7, chunks: 1) }
    }

    @Test(arguments: [
        CatalogFrame.hello(CatalogHello(version: 1, epoch: "e1", versions: CatalogFixture.versions)), .ping, .ack,
        .chunk(index: 2, data: "AA=="), .commit(epoch: "e1", rev: 4, chunks: 3),
        .snapshot(CatalogSnapshot(epoch: "e1", rev: 3, catalogID: CatalogFixture.catalog, versions: CatalogFixture.versions, workspaces: [])),
        .delta(epoch: "e1", rev: 1, change: .workspaceAdded(CatalogWorkspace(id: UUID(), name: "w", sessions: [CatalogFixture.session()]), index: 0)),
        .delta(epoch: "e1", rev: 2, change: .workspaceChanged(id: UUID(), name: "dev")),
        .delta(epoch: "e1", rev: 2, change: .workspaceChanged(id: UUID(), name: "dev", tint: "red", tintOn: ["name"])),
        .delta(epoch: "e1", rev: 2, change: .workspaceChanged(id: UUID(), name: "dev", tint: "")),
        .delta(epoch: "e1", rev: 3, change: .workspaceRemoved(UUID())),
        .delta(epoch: "e1", rev: 4, change: .workspaceOrder([UUID(), UUID()])),
        .delta(epoch: "e1", rev: 5, change: .sessionAdded(CatalogFixture.session(panes: [CatalogFixture.pane(), CatalogFixture.pane()]), workspace: UUID(), index: 1)),
        .delta(epoch: "e1", rev: 6, change: .sessionChanged(CatalogFixture.session(parent: UUID()).fields)),
        .delta(epoch: "e1", rev: 7, change: .sessionRemoved(UUID())),
        .delta(epoch: "e1", rev: 8, change: .sessionOrder([UUID()], workspace: UUID())),
        .delta(epoch: "e1", rev: 9, change: .paneAdded(CatalogFixture.pane(), session: UUID())),
        .delta(epoch: "e1", rev: 10, change: .paneChanged(CatalogFixture.pane(), session: UUID())),
        .delta(epoch: "e1", rev: 11, change: .paneRemoved(UUID(), session: UUID())),
        .hello(CatalogHello(version: 1, pageRows: true)),
        .delta(epoch: "e1", rev: 12, change: .sessionAdded(CatalogFixture.pageRow(), workspace: UUID(), index: 0)),
        .unknown(kind: CatalogFrame.skipKind, epoch: "e1", rev: 13),
        .delta(epoch: "e1", rev: 14, change: .recentChanged([ControlRecentItem(id: "r1", kind: "session", title: "a", subtitle: nil,
                                                                              closedAt: 1, workspaceID: "w", sessionIDs: ["s"])])),
    ])
    func everyFrameRoundTrips(_ frame: CatalogFrame) throws {
        let line = try CatalogCodec.encode(frame)

        #expect(line.last == UInt8(ascii: "\n"))
        #expect(try CatalogCodec.decode(line.dropLast()) == frame)
    }

    @Test func flagAndTintRoundTripWithAnExplicitNoneAndAnOlderServerSendsNone() throws {
        var fields = CatalogFixture.session().fields
        fields.flagged = false
        fields.tint = ""
        let none = try JSONDecoder().decode(CatalogSessionFields.self, from: JSONEncoder().encode(fields))
        fields.flagged = true
        fields.tint = "#ff8800"
        fields.tintOn = ["icon", "name"]
        let tinted = try JSONDecoder().decode(CatalogSessionFields.self, from: JSONEncoder().encode(fields))
        let older = try JSONDecoder().decode(CatalogSessionFields.self, from: JSONEncoder().encode(CatalogFixture.session().fields))
        let workspace = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"w","sessions":[]}"#.utf8)
        let olderWorkspace = try JSONDecoder().decode(CatalogWorkspace.self, from: workspace)

        #expect(none.flagged == false && none.tint == "")
        #expect(tinted == fields)
        #expect(older.flagged == nil && older.tint == nil && older.tintOn == nil)
        #expect(olderWorkspace.tint == nil)
    }

    @Test func aCatalogTintReadsBackAsARowsTint() throws {
        let hex = try #require(TintValue(rawValue: "#ff8800"))

        #expect(CatalogTint.sidebarTint("#FF8800", on: ["name", "bogus"]) == SidebarTint(color: hex, parts: [.name]))
        #expect(CatalogTint.sidebarTint("red", on: nil) == SidebarTint(color: .red))
        #expect(CatalogTint.sidebarTint("", on: nil) == nil)
        #expect(CatalogTint.sidebarTint("mauve-ish", on: ["icon"]) == nil)
        #expect(CatalogTint.sidebarTint(nil, on: nil) == nil)
    }

    @Test func anUnknownKindDecodesAsUnknown() throws {
        let line = Data(#"{"kind":"session.teleported","epoch":"e1","rev":3,"id":"x"}"#.utf8)

        #expect(try CatalogCodec.decode(line) == .unknown(kind: "session.teleported", epoch: "e1", rev: 3))
    }

    @Test func aHelloAndASessionWithoutPageFieldsDecodeAsBefore() throws {
        let hello = Data(#"{"kind":"hello","hello":{"version":1}}"#.utf8)
        let fields = CatalogFixture.session().fields
        let encoded = try JSONEncoder().encode(fields)

        #expect(try CatalogCodec.decode(hello) == .hello(CatalogHello(version: 1)))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("page"))
        #expect(try JSONDecoder().decode(CatalogSessionFields.self, from: encoded).page == nil)
    }

    @Test func aPanesMailCountIsOmittedAtNoneAndAnOlderServersPaneDecodesWithout() throws {
        let endpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/zmx")
        var counted = CatalogPane(identity: UUID(), daemon: "d", endpoint: endpoint)
        let plain = try JSONEncoder().encode(counted)
        counted.pendingMessages = 3

        #expect(!String(decoding: plain, as: UTF8.self).contains("pendingMessages"))
        #expect(try JSONDecoder().decode(CatalogPane.self, from: plain).pendingMessages == nil)
        #expect(try JSONDecoder().decode(CatalogPane.self, from: JSONEncoder().encode(counted)).pendingMessages == 3)
    }

    @Test func aHeldPaneIsMarkedAndARunningOneCarriesNoMark() throws {
        let endpoint = ControlZmxEndpoint(executable: "/bin/zmx", socketDirectory: "/tmp/zmx")
        var held = CatalogPane(identity: UUID(), daemon: "d", endpoint: endpoint)
        let running = try JSONEncoder().encode(held)
        held.held = true

        #expect(!String(decoding: running, as: UTF8.self).contains("held"))
        #expect(try JSONDecoder().decode(CatalogPane.self, from: running).held == nil)
        #expect(try JSONDecoder().decode(CatalogPane.self, from: JSONEncoder().encode(held)).held == true)
    }

    @Test func anEmptyCustomNameTravelsAsEmptyAndAnOlderServerOmitsIt() throws {
        var unnamed = CatalogFixture.session().fields
        unnamed.customName = ""
        let legacy = CatalogFixture.session().fields

        let decoded = try JSONDecoder().decode(CatalogSessionFields.self, from: JSONEncoder().encode(unnamed))
        let encodedLegacy = try JSONEncoder().encode(legacy)

        #expect(decoded.customName == "")
        #expect(!String(decoding: encodedLegacy, as: UTF8.self).contains("customName"))
        #expect(try JSONDecoder().decode(CatalogSessionFields.self, from: encodedLegacy).customName == nil)
    }

    @Test func aSnapshotCarriesTheRecentListAndAnOlderServersSnapshotHasNone() throws {
        let item = ControlRecentItem(id: "r1", kind: "session", title: "a", subtitle: nil, closedAt: 1, workspaceID: "w", sessionIDs: ["s"])
        var snapshot = CatalogFixture.snapshot([])
        let older = try JSONDecoder().decode(CatalogSnapshot.self, from: JSONEncoder().encode(snapshot))
        snapshot.recent = [item]

        #expect(older.recent == nil)
        #expect(try JSONDecoder().decode(CatalogSnapshot.self, from: JSONEncoder().encode(snapshot)).recent == [item])
    }

    @Test func versionsTravelWithTheProtocolKeyword() throws {
        let json = String(decoding: try JSONEncoder().encode(CatalogFixture.versions), as: UTF8.self)

        #expect(json.contains(#""protocol":1"#))
    }

    @Test func aMacsLiveFlagTravelsAndAServersVersionsCarryNone() throws {
        let mac = CatalogVersions(server: "1.2.3", protocolVersion: 1, catalog: 1, live: false)

        let decoded = try JSONDecoder().decode(CatalogVersions.self, from: JSONEncoder().encode(mac))
        let server = String(decoding: try JSONEncoder().encode(CatalogFixture.versions), as: UTF8.self)

        #expect(decoded.live == false)
        #expect(!server.contains("live"))
    }

    @Test func aHelloNamesTheOriginWindowAndAnOlderHelloHasNone() throws {
        let hello = CatalogHello(version: 1, pageRows: true, window: "W1")
        let older = try JSONDecoder().decode(CatalogHello.self, from: JSONEncoder().encode(CatalogHello(version: 1)))

        #expect(try JSONDecoder().decode(CatalogHello.self, from: JSONEncoder().encode(hello)).window == "W1")
        #expect(older.window == nil)
    }

    @Test func aRefusalTravelsWithItsReasonAndFinality() throws {
        for frame in [CatalogFrame.refused(reason: "window closed on box", final: false), .refused(reason: "no Live sessions", final: true)] {
            #expect(try CatalogCodec.decode(CatalogCodec.encode(frame).dropLast()) == frame)
        }
    }

    @Test func aRefusalReachesAnOlderDecoderAsAnUnknownKind() throws {
        let line = try CatalogCodec.encode(.refused(reason: "gone", final: true)).dropLast()
        let json = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])

        #expect(json["kind"] as? String == "refused")
        #expect(json["epoch"] == nil && json["rev"] == nil)
    }

    @Test func versionReplyCarriesTheMacCatalogAdvertisementSeparately() throws {
        let result = ControlResult(macCatalog: CatalogFixture.versions)
        let decoded = try JSONDecoder().decode(ControlResult.self, from: JSONEncoder().encode(result))

        #expect(decoded.macCatalog == CatalogFixture.versions)
        #expect(decoded.versions == nil)
    }
}
