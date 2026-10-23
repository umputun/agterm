import Foundation
import Testing
@testable import agtermCore

@MainActor
struct OverlayPointSizeTests {
    private let bounds = (width: 1_000.0, height: 800.0)

    @Test(arguments: [
        (OverlayPointSize(), 0.0, 600.0, 480.0),
        (OverlayPointSize(height: 240), 0.0, 600.0, 240.0),
        (OverlayPointSize(height: 240), 29.0, 600.0, 269.0),
        (OverlayPointSize(width: 300), 0.0, 300.0, 480.0),
        (OverlayPointSize(width: 5_000, height: 5_000), 0.0, 800.0, 640.0),
        (OverlayPointSize(height: 630), 29.0, 600.0, 640.0),
    ])
    func panelSizeOverridesOnlyThePointAxesAndCapsThemAfterTheChrome(
        points: OverlayPointSize, chrome: Double, width: Double, height: Double
    ) {
        let size = OverlayPointSize.panelSize(in: bounds, sizePercent: 60, points: points, chrome: chrome)

        #expect(size.width == width)
        #expect(size.height == height)
    }

    @Test func aPercentAxisKeepsTheFullPercentRange() {
        let size = OverlayPointSize.panelSize(in: bounds, sizePercent: 95, points: OverlayPointSize(height: 100),
                                              chrome: 0)

        #expect(size.width == 950)
    }

    @Test func contentSizeLeavesOutTheChrome() {
        let size = OverlayPointSize.contentSize(in: bounds, sizePercent: 60, points: OverlayPointSize(height: 240),
                                                chrome: 29)

        #expect(size.width == 600)
        #expect(size.height == 240)
    }

    @Test func mergingReplacesOnlyTheAxesItSets() {
        let merged = OverlayPointSize(width: 500, height: 200).merging(OverlayPointSize(height: 300))

        #expect(merged == OverlayPointSize(width: 500, height: 300))
    }

    @Test func openKeepsPointsOnlyBesideAPercent() throws {
        let (store, session) = try makeSession()

        store.openOverlay(session.id, command: "htop", sizePercent: 60, points: OverlayPointSize(height: 240))
        #expect(session.overlayPoints == OverlayPointSize(height: 240))
        store.closeOverlay(session.id)
        #expect(session.overlayPoints.isEmpty)

        store.openOverlay(session.id, command: "htop", points: OverlayPointSize(height: 240))
        #expect(session.overlayPoints.isEmpty)
    }

    @Test func aPageOpensWithItsPoints() throws {
        let (store, session) = try makeSession()
        let page = HtmlOverlay(source: .file(path: "/tmp/a/page.html", grantRoot: nil))

        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: 60,
                                      points: OverlayPointSize(width: 500)) == nil)

        #expect(session.overlayPoints == OverlayPointSize(width: 500))
    }

    @Test func aPercentResizeReplacesThePointsWholeAndFullClearsThem() throws {
        let (store, session) = try makeSession()
        store.openOverlay(session.id, command: "htop", sizePercent: 60, points: OverlayPointSize(width: 500, height: 240))

        store.resizeOverlay(session.id, sizePercent: 70, points: OverlayPointSize(height: 300))
        #expect(session.overlaySizePercent == 70)
        #expect(session.overlayPoints == OverlayPointSize(height: 300))

        store.resizeOverlay(session.id, sizePercent: 50)
        #expect(session.overlayPoints.isEmpty)

        store.resizeOverlay(session.id, sizePercent: 50, points: OverlayPointSize(height: 300))
        store.resizeOverlay(session.id, sizePercent: nil)
        #expect(session.overlayPoints.isEmpty)
        #expect(session.fullOverlayActive)
    }

    @Test func pointsAloneChangeTheirAxesAndKeepTheRest() throws {
        let (store, session) = try makeSession()
        store.openOverlay(session.id, command: "htop", sizePercent: 60, points: OverlayPointSize(width: 500))

        #expect(store.resizeOverlayInPoints(session.id, sizePercent: nil, points: OverlayPointSize(height: 240)) == nil)

        #expect(session.overlaySizePercent == 60)
        #expect(session.overlayPoints == OverlayPointSize(width: 500, height: 240))
    }

    @Test func pointsAloneNeedAFloatingProgramOrPage() throws {
        let (store, session) = try makeSession()
        let points = OverlayPointSize(height: 240)
        #expect(store.resizeOverlayInPoints(session.id, sizePercent: nil, points: points) == .noOverlay)

        store.openOverlay(session.id, command: "htop")
        #expect(store.resizeOverlayInPoints(session.id, sizePercent: nil, points: points) == .notFloating)
        #expect(store.resizeOverlayInPoints(session.id, sizePercent: 60, points: points) == nil)
        #expect(session.overlayPoints == points)
    }

    @Test func aHudTakesNoPointSizes() throws {
        let (store, session) = try makeSession()
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 35, heightPercent: 12), paneIdentity: session.paneIdentity)

        #expect(store.resizeOverlayInPoints(session.id, sizePercent: 40, points: OverlayPointSize(height: 240)) == .hud)

        #expect(session.overlayPoints.isEmpty)
        #expect(session.overlaySizePercent != 40)
    }

    @Test func aReplicaOfAnotherMacsPageTakesNoPointSizes() throws {
        let (store, session) = try makeSession()
        let page = HtmlOverlay(source: .file(path: "/tmp/a/page.html", grantRoot: nil), replicaOf: UUID())
        try #require(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: 60) == nil)

        #expect(store.resizeOverlayInPoints(session.id, sizePercent: nil, points: OverlayPointSize(height: 240)) == .remote)

        #expect(session.overlayPoints.isEmpty)
    }

    @Test func treeReportsTheContentSizeFromTheLastLayout() throws {
        let (store, session) = try makeSession()
        let page = HtmlOverlay(source: .file(path: "/tmp/a/page.html", grantRoot: nil))
        try #require(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: 60,
                                           points: OverlayPointSize(height: 240)) == nil)

        var node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.overlayWidth == nil)
        #expect(node.overlayHeight == nil)

        session.hudPaneFrames = HudPaneFrames(detail: HudPaneFrame(x: 0, y: 0, width: 1_000, height: 800))
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.overlayWidth == 600)
        #expect(node.overlayHeight == 240)

        store.resizeOverlay(session.id, sizePercent: nil)
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.overlayWidth == nil)
        #expect(node.overlayHeight == nil)
    }

    @Test func treeReportsAPercentPanelsContentToo() throws {
        let (store, session) = try makeSession()
        session.hudPaneFrames = HudPaneFrames(detail: HudPaneFrame(x: 0, y: 0, width: 1_000, height: 800))
        store.openOverlay(session.id, command: "htop", sizePercent: 50)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.overlayWidth == 500)
        #expect(node.overlayHeight == 400)
    }

    private func makeSession() throws -> (AppStore, Session) {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        return (store, try #require(store.addSession(toWorkspace: ws.id, cwd: "/a")))
    }
}
