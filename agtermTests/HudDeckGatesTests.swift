import agtermCore
import XCTest
@testable import agterm

/// The deck exemptions that make a HUD passive. `DeckPaneGates` and `OverlayPanelStyle` live in the app
/// target, so this cannot be host-free: they are the seam where the same overlay slot renders either a
/// caller's program — which owns first responder, mutes the session and swallows clicks — or a HUD, which
/// does none of it.
@MainActor
final class HudDeckGatesTests: XCTestCase {
    private func makeSession() -> Session { Session(initialCwd: NSTemporaryDirectory()) }

    private func hudSession(position: HudPosition = .center, sizePercent: Int = 40) -> Session {
        let session = makeSession()
        session.overlayActive = true
        session.overlaySizePercent = sizePercent
        session.hudSpec = HudSpec(message: "gathering options…", position: position)
        return session
    }

    private func programSession(sizePercent: Int?) -> Session {
        let session = makeSession()
        session.overlayActive = true
        session.overlaySizePercent = sizePercent
        return session
    }

    // MARK: - cover gate (first responder)

    func testHudLeavesTheSessionUncovered() {
        XCTAssertFalse(DeckPaneGates.coverActive(hudSession()))
    }

    func testProgramOverlayCoversTheSession() {
        XCTAssertTrue(DeckPaneGates.coverActive(programSession(sizePercent: 40)))
        XCTAssertTrue(DeckPaneGates.coverActive(programSession(sizePercent: nil)))
    }

    func testScratchCoversTheSessionWithAHudUp() {
        let session = hudSession()
        session.scratchActive = true
        XCTAssertTrue(DeckPaneGates.coverActive(session))
    }

    func testEmptySlotLeavesTheSessionUncovered() {
        XCTAssertFalse(DeckPaneGates.coverActive(makeSession()))
    }

    func testAHudReplacedByAProgramCoversAgain() {
        let session = hudSession()
        session.hudSpec = nil
        XCTAssertTrue(DeckPaneGates.coverActive(session))
    }

    // MARK: - clicks and backdrop

    func testHudPanelIsInertAndPaintsNoBackdrop() {
        let style = OverlayPanelStyle.resolve(hudSession())
        XCTAssertFalse(style.interactive)
        XCTAssertFalse(style.backdrop)
    }

    func testFloatingProgramOverlayCatchesClicksAndWashesTheBackdrop() {
        let style = OverlayPanelStyle.resolve(programSession(sizePercent: 40))
        XCTAssertTrue(style.interactive)
        XCTAssertTrue(style.backdrop)
    }

    func testFullProgramOverlayIsInteractiveWithoutABackdropWash() {
        let style = OverlayPanelStyle.resolve(programSession(sizePercent: nil))
        XCTAssertTrue(style.interactive)
        XCTAssertFalse(style.backdrop)
    }

    // MARK: - chrome

    func testHudDropsTheShadowForAStrongerBorder() {
        let style = OverlayPanelStyle.resolve(hudSession())
        XCTAssertTrue(style.framed)
        XCTAssertEqual(style.shadowRadius, 0)
        XCTAssertEqual(style.borderOpacity, 0.30, accuracy: 0.001)
        XCTAssertEqual(style.cornerRadius, 8)
    }

    func testFloatingProgramOverlayKeepsItsWindowChrome() {
        let style = OverlayPanelStyle.resolve(programSession(sizePercent: 40))
        XCTAssertTrue(style.framed)
        XCTAssertEqual(style.shadowRadius, 24)
        XCTAssertEqual(style.borderOpacity, 0.18, accuracy: 0.001)
        XCTAssertEqual(style.cornerRadius, 12)
    }

    func testFullProgramOverlayStaysChromeless() {
        let style = OverlayPanelStyle.resolve(programSession(sizePercent: nil))
        XCTAssertFalse(style.framed)
        XCTAssertEqual(style.shadowRadius, 0)
        XCTAssertEqual(style.borderOpacity, 0)
        XCTAssertEqual(style.cornerRadius, 0)
        XCTAssertEqual(style.fraction, 1)
    }

    func testSizePercentBecomesThePaneFraction() {
        XCTAssertEqual(OverlayPanelStyle.resolve(hudSession(sizePercent: 25)).fraction, 0.25, accuracy: 0.0001)
    }

    // MARK: - vertical placement

    func testCenterPlacementIsUnoffset() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .center))
        XCTAssertEqual(style.verticalOffset(paneHeight: 1000), 0)
    }

    func testTopPlacementHoldsTheEdgeMarginClear() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .top, sizePercent: 50))
        // pane 1000, panel 500 centered at 500; the top edge must land on the 10% margin, i.e. y = 100
        XCTAssertEqual(style.verticalOffset(paneHeight: 1000), -150, accuracy: 0.0001)
    }

    func testBottomPlacementMirrorsTop() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .bottom, sizePercent: 50))
        XCTAssertEqual(style.verticalOffset(paneHeight: 1000), 150, accuracy: 0.0001)
    }

    func testLargestAllowedPanelStaysInsideThePane() {
        let height: CGFloat = 1000
        for position in HudPosition.allCases {
            let style = OverlayPanelStyle.resolve(hudSession(position: position,
                                                             sizePercent: HudLayout.maxSizePercent))
            let panel = height * style.fraction
            let top = (height - panel) / 2 + style.verticalOffset(paneHeight: height)
            XCTAssertGreaterThanOrEqual(top, 0, "\(position) overhangs the top")
            XCTAssertLessThanOrEqual(top + panel, height, "\(position) overhangs the bottom")
        }
    }

    func testAPanelTooLargeForTheMarginStaysCentered() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .top, sizePercent: 95))
        XCTAssertEqual(style.verticalOffset(paneHeight: 1000), 0)
    }

    func testProgramOverlaysAreAlwaysCentered() {
        for percent in [nil, 40] as [Int?] {
            let style = OverlayPanelStyle.resolve(programSession(sizePercent: percent))
            XCTAssertEqual(style.position, .center)
            XCTAssertEqual(style.verticalOffset(paneHeight: 1000), 0)
        }
    }
}
