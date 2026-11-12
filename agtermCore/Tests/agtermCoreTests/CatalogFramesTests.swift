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
    ])
    func everyFrameRoundTrips(_ frame: CatalogFrame) throws {
        let line = try CatalogCodec.encode(frame)

        #expect(line.last == UInt8(ascii: "\n"))
        #expect(try CatalogCodec.decode(line.dropLast()) == frame)
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

    @Test func versionsTravelWithTheProtocolKeyword() throws {
        let json = String(decoding: try JSONEncoder().encode(CatalogFixture.versions), as: UTF8.self)

        #expect(json.contains(#""protocol":1"#))
    }
}
