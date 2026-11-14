import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsInfoTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession() throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    private func info(_ source: String, hideAfter: Double = 0) throws -> SessionInfo {
        try SessionInfo.make(source: source, markdown: false, hideAfter: hideAfter).get()
    }

    @Test func anInfoLineIsSetAndCleared() throws {
        let session = try newSession()

        #expect(harness.actions.setSessionInfo(session.id.uuidString, window: nil, info: try info("building")).ok)
        #expect(session.info?.source == "building")

        #expect(harness.actions.setSessionInfo(session.id.uuidString, window: nil, info: nil).ok)
        #expect(session.info == nil)
    }

    @Test func anInfoLineWithHideAfterExpiresOnTheServer() async throws {
        let session = try newSession()

        _ = harness.actions.setSessionInfo(session.id.uuidString, window: nil, info: try info("soon", hideAfter: 0.05))

        let deadline = Date().addingTimeInterval(30)
        while session.info != nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(session.info == nil)
    }

    @Test func aRefreshedLineReplacesTheEarlierExpiry() async throws {
        let session = try newSession()
        _ = harness.actions.setSessionInfo(session.id.uuidString, window: nil, info: try info("first", hideAfter: 0.05))

        _ = harness.actions.setSessionInfo(session.id.uuidString, window: nil, info: try info("second"))
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(session.info?.source == "second")
    }

    @Test func anUnknownSessionIsRefused() throws {
        let reply = harness.actions.setSessionInfo(UUID().uuidString, window: nil, info: try info("x"))

        #expect(!reply.ok)
    }
}
