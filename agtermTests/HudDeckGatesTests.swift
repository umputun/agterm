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

    private func hudSession(position: HudPosition = .center, sizePercent: Int = 40,
                            heightPercent: Int = 12) -> Session {
        let session = makeSession()
        session.overlayActive = true
        session.overlaySizePercent = sizePercent
        session.hudHeightPercent = heightPercent
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
        XCTAssertEqual(style.widthFraction, 1)
        XCTAssertEqual(style.heightFraction, 1)
    }

    func testSizePercentBecomesThePaneFraction() {
        let hud = OverlayPanelStyle.resolve(hudSession(sizePercent: 25, heightPercent: 9))
        XCTAssertEqual(hud.widthFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(hud.heightFraction, 0.09, accuracy: 0.0001)
        // a program overlay is a terminal, so it keeps one percent on both axes
        let program = OverlayPanelStyle.resolve(programSession(sizePercent: 40))
        XCTAssertEqual(program.widthFraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(program.heightFraction, 0.4, accuracy: 0.0001)
    }

    // the defect this split fixes: a HUD as tall as it is wide. The height comes from the message alone,
    // so a wide panel around two lines of text stays two lines tall.
    func testHudHeightIsIndependentOfItsWidth() {
        let style = OverlayPanelStyle.resolve(hudSession(sizePercent: HudLayout.maxSizePercent,
                                                         heightPercent: 9))
        XCTAssertEqual(style.widthFraction, 0.8, accuracy: 0.0001)
        XCTAssertEqual(style.heightFraction, 0.09, accuracy: 0.0001)
    }

    // an unmeasured panel must not fall back to the width, which would put the square back on the one
    // frame drawn before the first measurement lands
    func testHudWithoutAMeasuredHeightFallsBackToTheMinimum() {
        let session = hudSession(sizePercent: 70)
        session.hudHeightPercent = nil
        let style = OverlayPanelStyle.resolve(session)
        XCTAssertEqual(style.heightFraction, CGFloat(HudLayout.minSizePercent) / 100, accuracy: 0.0001)
    }

    // MARK: - vertical placement

    func testCenterPlacementIsUnoffset() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .center))
        XCTAssertEqual(style.verticalOffset(paneHeight: 1000), 0)
    }

    // the HEIGHT decides the travel now, so the width is deliberately the one that cannot move the panel
    func testTopPlacementHoldsTheEdgeMarginClear() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .topCenter, sizePercent: 90, heightPercent: 50))
        // pane 1000, panel 500 tall centered at 500; the top edge must land on the 10% margin, i.e. y = 100
        XCTAssertEqual(style.verticalOffset(paneHeight: 1000), -150, accuracy: 0.0001)
    }

    func testBottomPlacementMirrorsTop() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .bottomCenter, sizePercent: 90, heightPercent: 50))
        XCTAssertEqual(style.verticalOffset(paneHeight: 1000), 150, accuracy: 0.0001)
    }

    // a message-sized panel travels nearly to the edge, which is what `top` and `bottom` are asked for
    func testAShortPanelReachesTheEdgeMargin() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .topCenter, heightPercent: 10))
        XCTAssertEqual(style.verticalOffset(paneHeight: 1000), -350, accuracy: 0.0001)
    }

    func testLargestAllowedPanelStaysInsideThePane() {
        let height: CGFloat = 1000
        for position in HudPosition.allCases {
            let style = OverlayPanelStyle.resolve(hudSession(position: position,
                                                             sizePercent: HudLayout.maxSizePercent,
                                                             heightPercent: HudLayout.maxSizePercent))
            let panel = height * style.heightFraction
            let top = (height - panel) / 2 + style.verticalOffset(paneHeight: height)
            XCTAssertGreaterThanOrEqual(top, 0, "\(position) overhangs the top")
            XCTAssertLessThanOrEqual(top + panel, height, "\(position) overhangs the bottom")
        }
    }

    // defensive: `HudLayout.heightPercent` keeps a live HUD at or under the height where both margins
    // still fit, so no supported path reaches this branch
    func testAPanelTooLargeForTheMarginStaysCentered() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .topCenter, heightPercent: 95))
        XCTAssertEqual(style.verticalOffset(paneHeight: 1000), 0)
    }

    func testProgramOverlaysAreAlwaysCentered() {
        for percent in [nil, 40] as [Int?] {
            let style = OverlayPanelStyle.resolve(programSession(sizePercent: percent))
            XCTAssertEqual(style.position, .center)
            XCTAssertEqual(style.verticalOffset(paneHeight: 1000), 0)
            XCTAssertEqual(style.horizontalOffset(paneWidth: 1000), 0)
        }
    }

    // MARK: - horizontal placement

    func testCenterColumnIsUnoffsetHorizontally() {
        for position in [HudPosition.topCenter, .center, .bottomCenter] {
            let style = OverlayPanelStyle.resolve(hudSession(position: position, sizePercent: 40))
            XCTAssertEqual(style.horizontalOffset(paneWidth: 1000), 0, "\(position) should not move sideways")
        }
    }

    // the WIDTH decides the horizontal travel, mirroring the height on the vertical axis
    func testLeftPlacementHoldsTheEdgeMarginClear() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .centerLeft, sizePercent: 50,
                                                         heightPercent: 90))
        // pane 1000, panel 500 wide centered at 500; the left edge must land on the 10% margin, i.e. x = 100
        XCTAssertEqual(style.horizontalOffset(paneWidth: 1000), -150, accuracy: 0.0001)
    }

    func testRightPlacementMirrorsLeft() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .centerRight, sizePercent: 50,
                                                         heightPercent: 90))
        XCTAssertEqual(style.horizontalOffset(paneWidth: 1000), 150, accuracy: 0.0001)
    }

    func testANarrowPanelReachesTheEdgeMargin() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .bottomRight, sizePercent: 10))
        XCTAssertEqual(style.horizontalOffset(paneWidth: 1000), 350, accuracy: 0.0001)
    }

    // a corner has to travel on BOTH axes, which is the whole point of the anchor
    func testCornersOffsetOnBothAxes() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .topRight, sizePercent: 20,
                                                         heightPercent: 20))
        XCTAssertEqual(style.horizontalOffset(paneWidth: 1000), 300, accuracy: 0.0001)
        XCTAssertEqual(style.verticalOffset(paneHeight: 1000), -300, accuracy: 0.0001)
    }

    func testLargestAllowedPanelStaysInsideThePaneHorizontally() {
        let width: CGFloat = 1000
        for position in HudPosition.allCases {
            let style = OverlayPanelStyle.resolve(hudSession(position: position,
                                                             sizePercent: HudLayout.maxSizePercent,
                                                             heightPercent: HudLayout.maxSizePercent))
            let panel = width * style.widthFraction
            let left = (width - panel) / 2 + style.horizontalOffset(paneWidth: width)
            XCTAssertGreaterThanOrEqual(left, 0, "\(position) overhangs the left")
            XCTAssertLessThanOrEqual(left + panel, width, "\(position) overhangs the right")
        }
    }

    // defensive, matching the vertical axis: no supported width reaches this branch, `clampSizePercent`
    // bounding every caller's percent at `maxSizePercent`
    func testAPanelTooWideForTheMarginStaysCentered() {
        let style = OverlayPanelStyle.resolve(hudSession(position: .centerLeft, sizePercent: 95))
        XCTAssertEqual(style.horizontalOffset(paneWidth: 1000), 0)
    }
}
