import agtermCore
import XCTest
@testable import agterm

@MainActor
final class GhosttySurfaceViewTitleTests: XCTestCase {
    func testCwdEqualTitleIsDroppedAfterPwdReport() {
        let (session, view) = makeView()

        view.applyPwd("/tmp/\u{7}repo")
        view.applyTitle("/tmp/repo")

        XCTAssertEqual(session.currentCwd, "/tmp/repo")
        XCTAssertNil(session.oscTitle)
    }

    func testCwdEqualTitleIsDroppedWithoutAnyPwdReport() {
        // a live-restored pane can get the synthetic title before the PWD action, leaving a guard armed
        // by applyPwd unfired and the absolute path in the sidebar.
        let (session, view) = makeView()

        view.applyTitle("/tmp/start")

        XCTAssertNil(session.currentCwd)
        XCTAssertNil(session.oscTitle)
    }

    func testRepeatedCwdEqualTitleStaysDropped() {
        let (session, view) = makeView()

        view.applyPwd("/tmp/repo")
        view.applyTitle("/tmp/repo")
        view.applyTitle("/tmp/repo")

        XCTAssertNil(session.oscTitle)
    }

    func testCwdEqualTitleLeavesAnExistingTitleAlone() {
        let (session, view) = makeView()
        session.oscTitle = "existing"

        view.applyPwd("/tmp/repo")
        view.applyTitle("/tmp/repo")

        XCTAssertEqual(session.oscTitle, "existing")
    }

    func testRealTitleIsKeptAndDoesNotUnlockTheCwdTitle() {
        let (session, view) = makeView()

        view.applyPwd("/tmp/repo")
        view.applyTitle("chosen")
        view.applyTitle("/tmp/repo")

        XCTAssertEqual(session.oscTitle, "chosen")
    }

    func testTitleUnderTheCwdIsKept() {
        let (session, view) = makeView()

        view.applyPwd("/tmp/repo")
        view.applyTitle("repo")

        XCTAssertEqual(session.oscTitle, "repo")
    }

    func testSplitPaneDropsATitleEqualToItsOwnCwd() {
        let (session, view) = makeView(split: true)
        session.initialSplitCwd = "/tmp/right"

        view.applyTitle("/tmp/right")

        XCTAssertNil(session.splitTitle)
    }

    func testTitleIsSanitizedBeforeTheCwdComparison() {
        let (session, view) = makeView()

        view.applyPwd("/tmp/repo")
        view.applyTitle("/tmp/\u{7}repo")

        XCTAssertNil(session.oscTitle)
    }

    func testSplitPaneComparesTheLiveSplitCwdOverTheRestoredOne() {
        let (session, view) = makeView(split: true)
        session.initialSplitCwd = "/tmp/restored"

        view.applyPwd("/tmp/live")
        view.applyTitle("/tmp/live")

        XCTAssertNil(session.splitTitle)
    }

    func testSplitPaneWithNoSplitCwdFallsBackToThePrimaryCwd() {
        let (session, view) = makeView(split: true)

        view.applyTitle("/tmp/start")

        XCTAssertNil(session.splitTitle)
    }

    func testSplitPaneKeepsATitleEqualToThePrimaryCwd() {
        let (session, view) = makeView(split: true)
        session.initialSplitCwd = "/tmp/right"

        view.applyTitle("/tmp/start")

        XCTAssertEqual(session.splitTitle, "/tmp/start")
    }

    func testPromotedSplitDropsTheTitleEqualToTheMigratedCwd() {
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
