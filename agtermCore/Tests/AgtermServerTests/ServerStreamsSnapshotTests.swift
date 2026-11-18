import Foundation
import Testing
@testable import AgtermServerKit
@testable import agtermCore

/// Snapshots: a forwarded click an `open` selector takes is answered with one read of its file instead of a page.
extension ServerStreamsTests {
    private func snapshotSession() throws -> Session {
        let session = try newSession()
        session.currentCwd = harness.scratch.root
        return session
    }

    private func snapshotFile(_ name: String, _ text: String = "# notes\n") throws -> String {
        let path = harness.scratch.root + "/" + name
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func snapshotClick(_ raw: String, on session: Session, click: UUID?, openers: [String]?, from viewer: Viewer) throws {
        try viewer.send(.linkClick(PresentationLinkClick(raw: raw, pane: session.paneIdentity, mode: .overlay, click: click,
                                                         openers: openers)))
    }

    private func answer(from viewer: Viewer) async -> PresentationFrame.Body? {
        await offPool {
            viewer.first {
                switch $0 {
                case .linkSnapshot, .linkRefused, .pageRequest: true
                default: false
                }
            }
        }
    }

    private func channel(_ token: String) throws -> LogClient {
        let claimed = streams.claimPageStream(token)
        let claim = try #require(claimed.result?.id.flatMap(UUID.init(uuidString:)), "\(claimed)")
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0)
        streams.adoptPageServeStream(descriptor: pair[0], page: claim, token: token)
        return LogClient(fd: pair[1])
    }

    private func read(_ client: LogClient, id: Int, path: String) async throws -> (head: String?, data: Data, end: PageServeFrame?) {
        try await offPool { () throws -> (String?, Data, PageServeFrame?) in
            try client.send(.resource(id: id, path: path))
            var head: String?
            var data = Data()
            while let frame = client.frame() {
                switch frame {
                case .head(_, let mimeType): head = mimeType
                case .chunk(_, let chunk): data.append(chunk)
                default: return (head, data, frame)
                }
            }
            return (head, data, nil)
        }
    }

    private func request(_ client: LogClient, _ frame: PageServeFrame) async throws -> PageServeFrame? {
        try await offPool { () throws -> PageServeFrame? in
            try client.send(frame)
            return client.frame()
        }
    }

    @Test func aClickASelectorTakesIsAnsweredWithOneReadOfItsFile() async throws {
        let session = try snapshotSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        _ = try snapshotFile("notes.md", "# notes\nbody\n")
        let click = UUID()

        try snapshotClick("./notes.md", on: session, click: click, openers: ["*.md"], from: viewer)

        guard case .linkSnapshot(let snapshot)? = await answer(from: viewer) else { Issue.record("no snapshot"); return }
        #expect(snapshot.click == click)
        #expect(snapshot.name == "notes.md")
        #expect(snapshot.size == 13)
        #expect(session.remoteOverlays.slot(nil)?.page == nil)
        let client = try channel(snapshot.token)
        #expect(try await request(client, .resource(id: 1, path: "/etc/hosts")) == .failure(id: 1, error: "not offered"))
        #expect(try await request(client, .bridge(id: 2, request: "{}")) == .failure(id: 2, error: "not offered"))
        let first = try await read(client, id: 3, path: "notes.md")
        #expect(first.head == "application/octet-stream")
        #expect(first.data == Data("# notes\nbody\n".utf8))
        #expect(first.end == .end(id: 3))
        #expect(try await request(client, .resource(id: 4, path: "notes.md")) == .failure(id: 4, error: "not offered"))
        #expect(!streams.claimPageStream(snapshot.token).ok)
    }

    @Test func aClickWithoutAnIDOrFromAViewerWithoutSnapshotsOpensThePage() async throws {
        let session = try snapshotSession()
        _ = try snapshotFile("notes.md")
        let older = try await presenter(for: session, kinds: PresentationHub.supportedKinds.filter { $0 != PresentationHub.linkSnapshotKind })

        try snapshotClick("./notes.md", on: session, click: UUID(), openers: ["*.md"], from: older)
        guard case .pageRequest? = await answer(from: older) else { Issue.record("no page for an older viewer"); return }
        older.disconnect()
        #expect(harness.actions.closeSessionOverlay(session.id.uuidString, window: nil, pane: nil).ok)

        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        try snapshotClick("./notes.md", on: session, click: nil, openers: ["*.md"], from: viewer)
        guard case .pageRequest? = await answer(from: viewer) else { Issue.record("no page for a click without an id"); return }
    }

    @Test func aFileNoSelectorTakesOpensThePage() async throws {
        let session = try snapshotSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        _ = try snapshotFile("notes.md")

        try snapshotClick("./notes.md", on: session, click: UUID(), openers: ["*.go", "Makefile", "*.[md]", "a/b"], from: viewer)

        guard case .pageRequest? = await answer(from: viewer) else { Issue.record("no page"); return }
        #expect(streams.snapshotBook.isIdle)
    }

    @Test func aFileOverItsPagesCapIsLeftToThePagePathAndItsRefusalNamesTheClick() async throws {
        let session = try snapshotSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        _ = try snapshotFile("big.md", String(repeating: "x", count: MarkdownPage.maxBytes + 1))
        let click = UUID()

        try snapshotClick("./big.md", on: session, click: click, openers: ["*.md"], from: viewer)

        guard case .linkRefused(let refusal)? = await answer(from: viewer) else { Issue.record("no refusal"); return }
        #expect(refusal.click == click)
        #expect(streams.snapshotBook.isIdle)
    }

    @Test func aRefusalNamesTheClickItAnswers() async throws {
        let session = try snapshotSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        let click = UUID()

        try snapshotClick("./missing.md", on: session, click: click, openers: ["*.md"], from: viewer)

        guard case .linkRefused(let refusal)? = await answer(from: viewer) else { Issue.record("no refusal"); return }
        #expect(refusal == PresentationLinkRefusal(reason: .notFound, click: click))
    }

    @Test func anOfferNobodyClaimsWithinTheWindowExpires() async throws {
        let session = try snapshotSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        _ = try snapshotFile("notes.md")
        let start = Date()
        streams.now = { start }

        try snapshotClick("./notes.md", on: session, click: UUID(), openers: ["*.md"], from: viewer)
        guard case .linkSnapshot(let snapshot)? = await answer(from: viewer) else { Issue.record("no snapshot"); return }
        streams.now = { start.addingTimeInterval(AppStore.pageClaimWindow + 1) }

        #expect(!streams.claimPageStream(snapshot.token).ok)
        #expect(streams.snapshotBook.isIdle)
    }

    @Test func aClaimWhoseReplyNeverReachedItsHelperIsDroppedWithoutTouchingThePage() async throws {
        let session = try snapshotSession()
        let viewer = try await presenter(for: session)
        defer { viewer.disconnect() }
        let page = try snapshotFile("page.md")
        #expect(harness.actions.openSessionOverlay(session.id.uuidString, window: nil, options: ControlSessionOverlayOpenOptions(
            command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, page: .markdown(path: page))).ok)
        _ = await answer(from: viewer)
        _ = try snapshotFile("notes.md")
        try snapshotClick("./notes.md", on: session, click: UUID(), openers: ["*.md"], from: viewer)
        guard case .linkSnapshot(let snapshot)? = await answer(from: viewer) else { Issue.record("no snapshot"); return }
        let claimed = streams.claimPageStream(snapshot.token)
        let claim = try #require(claimed.result?.id.flatMap(UUID.init(uuidString:)))

        streams.pageClaimUnanswered(claim, token: snapshot.token)

        #expect(streams.snapshotBook.isIdle)
        #expect(session.remoteOverlays.slot(nil)?.page != nil)
        let reoffer = await offPool { viewer.first(within: 1) { if case .pageRequest = $0 { true } else { false } } }
        #expect(reoffer == nil)
    }
}
