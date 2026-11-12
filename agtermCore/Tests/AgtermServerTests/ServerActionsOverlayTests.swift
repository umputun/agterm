import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsOverlayTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession() throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    private func open(_ session: Session, page: HtmlSource? = nil, textLog: TextLog? = nil) -> ControlResponse {
        harness.actions.openSessionOverlay(session.id.uuidString, window: nil, options: ControlSessionOverlayOpenOptions(
            command: "true", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, page: page, textLog: textLog))
    }

    private func file(_ name: String, _ bytes: [UInt8]) throws -> String {
        let path = harness.scratch.root + "/" + name
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func interactions(_ session: Session) -> [ControlInteraction]? {
        harness.store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }?.interactions
    }

    @Test func aProgramWithNoConnectedMacWaitsAndHoldsItsSlot() throws {
        let session = try newSession()

        #expect(open(session).ok)

        let slot = try #require(session.remoteOverlays.slot(nil))
        #expect(slot.owner == nil)
        #expect(harness.actions.streams.overlayJobs.job(slot.job)?.state == .unpresented)
        #expect(interactions(session) == [ControlInteraction(kind: "job", id: slot.job, state: ControlInteraction.unpresented)])
        #expect(open(session) == ControlResponse(ok: false, error: "overlay already open"))
        #expect(harness.actions.closeSessionOverlay(session.id.uuidString, window: nil, pane: nil).ok)
        #expect(session.remoteOverlays.slot(nil) == nil)
    }

    @Test func aPageWithNoConnectedMacWaitsAndHoldsItsSlot() throws {
        let session = try newSession()
        let path = try file("page.html", Array("<p>hi</p>".utf8))

        let reply = open(session, page: .file(path: path, grantRoot: nil))

        #expect(reply.ok)
        let slot = try #require(session.remoteOverlays.slot(nil))
        #expect(slot.owner == nil)
        #expect(interactions(session) == [ControlInteraction(kind: "page", id: slot.job, state: ControlInteraction.unpresented)])
    }

    @Test func aFilePageIsJudgedOnTheServerBeforeAnyMacIsAsked() throws {
        let session = try newSession()
        let missing = harness.scratch.root + "/missing.md"
        let binary = try file("binary.txt", [0x61, 0x00, 0x62])
        let notImage = try file("fake.png", Array("not a picture".utf8))

        #expect(open(session, page: .markdown(path: missing)).error == "session.overlay.open: \(MarkdownFile.Failure.unreadable(missing))")
        #expect(open(session, page: .text(path: binary, line: nil)).error == "session.overlay.open: \(TextProbe.Failure.notText(binary))")
        #expect(open(session, page: .image(path: notImage)).error == "session.overlay.open: \(ImageFile.Failure.notAnImage(notImage))")
    }

    @Test func aLogOverTheWholeFileCapWaitsForAMacWhileAPlainTextPageIsRefused() throws {
        let session = try newSession()
        let line = String(repeating: "x", count: 99) + "\n"
        let path = try file("big.log", Array(String(repeating: line, count: TextPage.maxBytes / 100 + 10).utf8))

        #expect(open(session, page: .text(path: path, line: nil)).error == "session.overlay.open: \(TextProbe.Failure.tooLarge(path))")
        #expect(open(session, page: .text(path: path, line: nil), textLog: TextLog(tail: 10, follow: true)).ok)

        let slot = try #require(session.remoteOverlays.slot(nil))
        #expect(slot.owner == nil)
        #expect(slot.page?.overlay.textLog == TextLog(tail: 10, follow: true))
    }

    @Test func textCommandsOnAnEmptySlotGetTheSlotsRefusal() async throws {
        let id = try newSession().id.uuidString

        let follow = await harness.actions.setSessionOverlayFollow(id, window: nil, pane: nil, mode: .on)
        let wrap = await harness.actions.setSessionOverlayWrap(id, window: nil, pane: nil, mode: .on)
        let search = await harness.actions.searchSessionOverlay(id, window: nil, pane: nil, request: .next)
        let changes = await harness.actions.stepSessionOverlayChanges(id, window: nil, pane: nil, forward: true)

        #expect([follow, wrap, search, changes].map(\.error) == Array(repeating: OverlayHtmlError.noOverlay, count: 4))
    }

    @Test func textCommandsOnALogHeldForNoMacAnswerThatTheViewerIsGone() async throws {
        let session = try newSession()
        let id = session.id.uuidString
        let path = try file("app.log", Array("one\ntwo\n".utf8))
        #expect(open(session, page: .text(path: path, line: nil), textLog: TextLog(tail: 10, follow: true)).ok)

        let follow = await harness.actions.setSessionOverlayFollow(id, window: nil, pane: nil, mode: .on)
        let wrap = await harness.actions.setSessionOverlayWrap(id, window: nil, pane: nil, mode: .on)
        let search = await harness.actions.searchSessionOverlay(id, window: nil, pane: nil, request: .next)
        let changes = await harness.actions.stepSessionOverlayChanges(id, window: nil, pane: nil, forward: true)

        #expect([follow, wrap, search, changes].map(\.error) == Array(repeating: OverlayResultError.viewerGone, count: 4))
    }

    @Test func followUpsOnAnEmptySlotAreRefused() throws {
        let session = try newSession()
        let id = session.id.uuidString

        #expect(harness.actions.closeSessionOverlay(id, window: nil, pane: nil) == ControlResponse(ok: false, error: "no overlay"))
        #expect(harness.actions.resizeSessionOverlay(id, window: nil, sizePercent: 50) == ControlResponse(ok: false, error: "no overlay"))
        #expect(harness.actions.sessionOverlayResult(id, window: nil, pane: nil)
            == ControlResponse(ok: false, error: OverlayResultError.noResult))
        #expect(harness.actions.reloadSessionOverlay(id, window: nil, pane: nil, current: false)
            == ControlResponse(ok: false, error: OverlayHtmlError.noOverlay))
    }

    @Test func aHudTakesAWidthButNotFullSizeOrPoints() throws {
        let session = try newSession()
        let id = session.id.uuidString
        _ = harness.actions.openHud(id, window: nil, spec: HudSpec(message: "building"))

        #expect(harness.actions.resizeSessionOverlay(id, window: nil, sizePercent: 50).ok)
        #expect(session.effectiveHudSpec?.sizePercent == 50)
        #expect(harness.actions.resizeSessionOverlay(id, window: nil, sizePercent: nil)
            == ControlResponse(ok: false, error: OverlayHudError.fullResize))
        #expect(harness.actions.resizeSessionOverlay(id, window: nil, sizePercent: 50, points: OverlayPointSize(width: 300))
            == ControlResponse(ok: false, error: OverlayPointError.hud))
    }

    @Test func aHudClosesThroughOverlayClose() throws {
        let session = try newSession()
        _ = harness.actions.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "building"))

        #expect(harness.actions.closeSessionOverlay(session.id.uuidString, window: nil, pane: nil).ok)
        #expect(!session.hudActive)
    }
}
