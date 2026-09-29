import Foundation
import Testing
@testable import agtermCore

@MainActor
struct HtmlPageOutcomesTests {
    let store = makeStore()
    let session: Session
    let outcomes = HtmlPageOutcomes.shared

    init() throws {
        let workspace = store.addWorkspace(name: "work")
        session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
    }

    private func open(pane: OverlayPane? = nil) throws -> UUID {
        let overlay = HtmlOverlay(source: .file(path: "/tmp/a/pick.html", grantRoot: nil))
        #expect(store.openHtmlOverlay(session.id, pane: pane, overlay: overlay, sizePercent: nil) == nil)
        return overlay.id
    }

    private func state(_ id: UUID) -> ControlHtmlPageOutcomeState? { outcomes.outcome(for: id)?.outcome }

    @Test func anOpenPageIsPendingAndARefusedOpenRegistersNothing() throws {
        let id = try open()
        #expect(state(id) == .pending)
        let refused = HtmlOverlay(source: .file(path: "/tmp/a/second.html", grantRoot: nil))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: refused, sizePercent: nil) == .alreadyOpen)
        #expect(outcomes.outcome(for: refused.id) == nil)
    }

    @Test func submitRecordsTheValueAndClosesThePage() throws {
        let id = try open()
        #expect(store.submitHtmlOverlay(session.id, pane: nil, value: "feature-x") == nil)
        #expect(outcomes.outcome(for: id) == ControlHtmlPageOutcome(pageID: id.uuidString, outcome: .submitted,
                                                                    value: "feature-x"))
        #expect(!session.overlayActive)
    }

    @Test func anEmptyOrMultilineValueIsARealAnswer() throws {
        let first = try open()
        #expect(store.submitHtmlOverlay(session.id, pane: nil, value: "") == nil)
        #expect(outcomes.outcome(for: first)?.value == "")
        let second = try open()
        #expect(store.submitHtmlOverlay(session.id, pane: nil, value: "a\nb") == nil)
        #expect(outcomes.outcome(for: second)?.value == "a\nb")
    }

    @Test func submitWithoutAPageIsRefused() {
        #expect(store.submitHtmlOverlay(session.id, pane: nil, value: "x") == .noOverlay)
        #expect(store.submitHtmlOverlay(UUID(), pane: nil, value: "x") == .unknownSession)
    }

    @Test func closingAPendingPageRecordsDismissed() throws {
        let id = try open()
        #expect(store.closeOverlay(session.id))
        #expect(state(id) == .dismissed)
        #expect(outcomes.outcome(for: id)?.value == nil)
    }

    @Test func aPaneSlotPageSubmitsAndDismissesLikeTheSessionSlot() throws {
        store.toggleSplit(session.id)
        session.surface = SpySurface(paneToken: "left")
        session.splitSurface = SpySurface(paneToken: "right")
        let submitted = try open(pane: .right)
        #expect(store.submitHtmlOverlay(session.id, pane: .right, value: "r") == nil)
        #expect(state(submitted) == .submitted)
        let dismissed = try open(pane: .right)
        #expect(store.closePaneOverlay(session.id, pane: .right))
        #expect(state(dismissed) == .dismissed)
    }

    @Test func eachTransitionHappensOnce() {
        let outcomes = HtmlPageOutcomes()
        let id = UUID()
        outcomes.register(id)
        #expect(outcomes.submit(id, value: "first"))
        #expect(!outcomes.submit(id, value: "second"))
        outcomes.dismiss(id)
        #expect(outcomes.outcome(for: id)?.outcome == .submitted)
        #expect(outcomes.outcome(for: id)?.value == "first")
        let unknown = UUID()
        #expect(!outcomes.submit(unknown, value: "x"))
        outcomes.dismiss(unknown)
        #expect(outcomes.outcome(for: unknown) == nil)
    }

    @Test func theResultReplyCarriesTheOutcomeOrNamesAnUnknownPage() {
        let outcomes = HtmlPageOutcomes()
        let id = UUID()
        outcomes.register(id)
        #expect(outcomes.submit(id, value: "v"))
        let expected = ControlHtmlPageOutcome(pageID: id.uuidString, outcome: .submitted, value: "v")
        #expect(outcomes.response(for: id) == ControlResponse(ok: true, result: ControlResult(pageOutcome: expected)))
        #expect(outcomes.response(for: UUID()) == ControlResponse(ok: false, error: OverlayHtmlError.unknownPage))
    }

    @Test func aReadNeverConsumesTheOutcome() {
        let outcomes = HtmlPageOutcomes()
        let id = UUID()
        outcomes.register(id)
        outcomes.dismiss(id)
        #expect(outcomes.outcome(for: id)?.outcome == .dismissed)
        #expect(outcomes.outcome(for: id)?.outcome == .dismissed)
    }

    @Test func retentionEvictsOldFinishedOutcomesButNeverAPendingOne() {
        let outcomes = HtmlPageOutcomes()
        let waiting = UUID()
        outcomes.register(waiting)
        let finished = (0..<(HtmlPageOutcomes.retainedLimit + 1)).map { _ in UUID() }
        for id in finished {
            outcomes.register(id)
            outcomes.dismiss(id)
        }
        #expect(outcomes.outcome(for: finished[0]) == nil)
        #expect(outcomes.outcome(for: finished[1])?.outcome == .dismissed)
        #expect(outcomes.outcome(for: waiting)?.outcome == .pending)
    }

    @Test func anOutcomeOutlivesItsPageAndSession() throws {
        let id = try open()
        #expect(store.submitHtmlOverlay(session.id, pane: nil, value: "kept") == nil)
        store.closeSession(session.id)
        #expect(outcomes.outcome(for: id)?.value == "kept")
    }

    @Test func aSingleSessionCloseDismissesAtOnce() throws {
        let id = try open()
        store.closeSession(session.id)
        #expect(state(id) == .dismissed)
    }

    @Test func aSoftClosedPageStaysPendingThroughUndoAndIsDismissedWhenTheCloseIsFinal() throws {
        let workspace = try #require(store.workspaces.first)
        let other = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let id = try open()
        #expect(store.softCloseSessions([session.id, other.id], grace: 60))
        #expect(state(id) == .pending)
        #expect(store.undoPendingClose())
        #expect(state(id) == .pending)
        #expect(store.softCloseSessions([session.id, other.id], grace: 60))
        store.finalizeAllPendingCloses()
        #expect(state(id) == .dismissed)
    }

    @Test func aSwapKeepsThePagePending() throws {
        store.toggleSplit(session.id)
        session.surface = SpySurface(paneToken: "left")
        session.splitSurface = SpySurface(paneToken: "right")
        let id = try open(pane: .left)
        #expect(store.swapPanes(session.id) == nil)
        #expect(session.paneOverlay(.right)?.html?.id == id)
        #expect(state(id) == .pending)
    }
}
