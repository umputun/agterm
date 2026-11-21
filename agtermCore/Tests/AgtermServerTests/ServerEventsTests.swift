import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerEventsTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession() throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    private func read(after cursor: ControlEventCursor?, kinds: Set<ControlEventKind>? = nil) -> ControlResponse {
        harness.actions.readEvents(ControlEventReadOptions(cursor: cursor, kinds: kinds, limit: 100))
    }

    @Test func aStatusWriteIsReadBackAsAnEventOfTheCatalogWindow() async throws {
        let session = try newSession()
        let anchor = try #require(read(after: nil).result?.events)

        _ = await harness.actions.setSessionStatus(session.id.uuidString, window: nil, update: ControlSessionStatusUpdate(
            status: .completed, blink: nil, autoReset: nil, sound: nil, color: nil, shape: nil, pane: nil, paneID: nil,
            ifIdle: false))
        let batch = try #require(read(after: ControlEventCursor(run: anchor.run, after: anchor.next), kinds: [.status]).result?.events)

        #expect(batch.items.count == 1)
        #expect(batch.items.first?.session == session.id.uuidString)
        #expect(batch.items.first?.window == harness.catalog.id.uuidString)
    }

    @Test func treeChangesFoldIntoOneEventBeforeARead() throws {
        let anchor = try #require(read(after: nil).result?.events)

        harness.events.receive(ControlEventDraft(kind: .treeChanged))
        harness.events.receive(ControlEventDraft(kind: .treeChanged))
        let batch = try #require(read(after: ControlEventCursor(run: anchor.run, after: anchor.next)).result?.events)

        #expect(batch.items.map(\.kind) == [.treeChanged])
        #expect(batch.items.first?.window == harness.catalog.id.uuidString)
    }

    @Test func aCursorFromAnotherRunIsRefusedWithTheAnchor() throws {
        let reply = read(after: ControlEventCursor(run: UUID(), after: 0))

        #expect(!reply.ok)
        #expect(reply.error == ControlEventReadError.runChanged.rawValue)
        #expect(reply.result?.events != nil)
    }
}
