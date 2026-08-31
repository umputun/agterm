import agtermCore
import XCTest
@testable import agterm

@MainActor
final class GhosttySurfaceViewTitleTests: XCTestCase {
    func testPwdFallbackDoesNotBecomePrimaryTitle() {
        let (session, view) = makeView()

        view.applyPwd("/tmp/\u{7}repo")
        view.applyTitle("/tmp/repo")

        XCTAssertEqual(session.currentCwd, "/tmp/repo")
        XCTAssertNil(session.oscTitle)
    }

    func testRealTitleEqualToCwdWinsAfterPwdFallback() {
        let (session, view) = makeView()

        view.applyPwd("/tmp/repo")
        view.applyTitle("/tmp/repo")
        view.applyTitle("/tmp/repo")

        XCTAssertEqual(session.oscTitle, "/tmp/repo")
    }

    func testExistingTitleDoesNotArmPwdFallback() {
        let (session, view) = makeView()
        session.oscTitle = "existing"

        view.applyPwd("/tmp/repo")
        view.applyTitle("/tmp/repo")

        XCTAssertEqual(session.oscTitle, "/tmp/repo")
    }

    func testDifferentTitleClearsPwdFallbackCandidate() {
        let (session, view) = makeView()

        view.applyPwd("/tmp/repo")
        view.applyTitle("chosen")
        view.applyTitle("/tmp/repo")

        XCTAssertEqual(session.oscTitle, "/tmp/repo")
    }

    func testPwdFallbackCandidateSurvivesSplitPromotion() {
        let (session, view) = makeView(split: true)

        view.applyPwd("/tmp/right")
        view.promoteToPrimaryPane()
        session.currentCwd = session.splitCwd
        session.oscTitle = session.splitTitle
        session.splitCwd = nil
        session.splitTitle = nil
        view.applyTitle("/tmp/right")

        XCTAssertNil(session.oscTitle)
    }

    private func makeView(split: Bool = false) -> (Session, GhosttySurfaceView) {
        let session = Session(initialCwd: "/tmp/start")
        let view = GhosttySurfaceView(workingDirectory: session.initialCwd)
        view.session = session
        view.isSplitPane = split
        return (session, view)
    }
}
