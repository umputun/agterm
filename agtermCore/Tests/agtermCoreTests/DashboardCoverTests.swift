import Foundation
import Testing
@testable import agtermCore

@MainActor
struct DashboardCoverTests {
    let store = makeStore()
    let session: Session

    init() throws {
        let workspace = store.addWorkspace(name: "work")
        session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        store.toggleSplit(session.id)
    }

    private func page(_ path: String = "/tmp/a/report.html") -> HtmlOverlay {
        HtmlOverlay(source: .file(path: path, grantRoot: nil))
    }

    @Test func anUncoveredPaneHasNoCover() {
        #expect(session.dashboardCover(for: .left) == nil)
        #expect(session.dashboardCover(for: .right) == nil)
    }

    @Test func aPanePageCoversOnlyItsOwnPane() {
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        #expect(session.dashboardCover(for: .right) == .page(identity: "report.html", title: nil))
        #expect(session.dashboardCover(for: .left) == nil)
    }

    @Test func aPageCoverCarriesTheLoadedTitle() {
        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page(), sizePercent: nil) == nil)
        session.leftOverlay?.html?.current = HtmlPageInfo(page: "/tmp/a/report.html", title: "Weekly report",
                                                          canGoBack: false, canGoForward: false)
        #expect(session.dashboardCover(for: .left) == .page(identity: "report.html", title: "Weekly report"))
    }

    @Test func aUrlPageCoverNamesItsOrigin() throws {
        let overlay = HtmlOverlay(source: .url(try #require(URL(string: "http://localhost:5173/app"))))
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: overlay, sizePercent: nil) == nil)
        #expect(session.dashboardCover(for: .right) == .page(identity: "http://localhost:5173", title: nil))
    }

    @Test func aPaneProgramCoversItsPaneWithItsCommand() {
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "htop -d 5") == nil)
        #expect(session.dashboardCover(for: .left) == .program(command: "htop -d 5"))
        #expect(session.dashboardCover(for: .right) == nil)
    }

    @Test func aFullSessionProgramCoversBothPanes() {
        #expect(store.openOverlay(session.id, command: "revdiff"))
        #expect(session.dashboardCover(for: .left) == .program(command: "revdiff"))
        #expect(session.dashboardCover(for: .right) == .program(command: "revdiff"))
    }

    @Test func aFullSessionPageTakesPrecedenceOverAPaneOverlay() {
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "htop") == nil)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page("/tmp/a/wide.html"), sizePercent: nil) == nil)
        #expect(session.dashboardCover(for: .right) == .page(identity: "wide.html", title: nil))
        #expect(session.dashboardCover(for: .left) == .page(identity: "wide.html", title: nil))
    }

    @Test func aFloatingOverlayLeavesThePanesUncovered() {
        #expect(store.openOverlay(session.id, command: "revdiff", sizePercent: 60))
        #expect(session.dashboardCover(for: .left) == nil)
        store.closeOverlay(session.id)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: 60) == nil)
        #expect(session.dashboardCover(for: .left) == nil)
    }

    @Test func aHudLeavesThePanesUncovered() {
        #expect(store.openHud(session.id, command: "hud", spec: HudSpec(message: "x"), file: "/tmp/h",
                              size: HudPanelSize(widthPercent: 30, heightPercent: 10)))
        #expect(session.dashboardCover(for: .left) == nil)
        #expect(session.dashboardCover(for: .right) == nil)
    }

    @Test func aFloatingOverlayStillShowsThePaneOverlayUnderIt() {
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "htop") == nil)
        #expect(store.openOverlay(session.id, command: "revdiff", sizePercent: 60))
        #expect(session.dashboardCover(for: .right) == .program(command: "htop"))
    }

    @Test func aHudStillShowsThePaneOverlayUnderIt() {
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "htop") == nil)
        #expect(store.openHud(session.id, command: "hud", spec: HudSpec(message: "x"), file: "/tmp/h",
                              size: HudPanelSize(widthPercent: 30, heightPercent: 10)))
        #expect(session.dashboardCover(for: .left) == .program(command: "htop"))
        #expect(session.dashboardCover(for: .right) == nil)
    }

    @Test func aReplicaProgramCoverCarriesNoCommand() {
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "ssh host run-job j") == nil)
        session.setOverlayReplica(OverlayReplica(job: "j"), pane: .right)
        #expect(session.dashboardCover(for: .right) == .program(command: nil))
        #expect(store.openOverlay(session.id, command: "ssh host run-job k"))
        session.setOverlayReplica(OverlayReplica(job: "k"), pane: nil)
        #expect(session.dashboardCover(for: .left) == .program(command: nil))
    }

    @Test func closingTheOverlayClearsTheCover() {
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        #expect(store.closePaneOverlay(session.id, pane: .right))
        #expect(session.dashboardCover(for: .right) == nil)
    }
}
