import Foundation
import Testing
@testable import agtermCore

@MainActor
struct HtmlOverlayTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}
    }

    let store = makeStore()
    let workspace: Workspace
    let session: Session

    init() throws {
        workspace = store.addWorkspace(name: "work")
        session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
    }

    private func page(_ file: String = "/tmp/a/report.html", grant: String? = nil) -> HtmlOverlay {
        HtmlOverlay(file: file, grantRoot: grant)
    }

    private func split() {
        store.toggleSplit(session.id)
        session.surface = SpySurface(paneToken: "left")
        session.splitSurface = SpySurface(paneToken: "right")
    }

    private func recordReleases() -> () -> [UUID] {
        var released: [UUID] = []
        HtmlOverlayReleases.shared.onRelease = { released.append($0) }
        return { released }
    }

    @Test(arguments: [
        ("/a/b/report.html", String?.none, true),
        ("/a/b/report.html", "/a/b", true),
        ("/a/b/report.html", "/a", true),
        ("/a/b/report.html", "/a/b/report.html", false),
        ("/a/b/./report.html", "/a/b/report.html/", false),
        ("/a/bc/report.html", "/a/b", false),
        ("/x/report.html", "/a", false),
        ("relative/report.html", String?.none, false),
        ("/a/report.html", "relative", false),
    ])
    func grantContainment(_ file: String, _ grant: String?, _ valid: Bool) {
        #expect((HtmlOverlay.grantError(file: file, grantRoot: grant) == nil) == valid)
    }

    @Test(arguments: [
        ("file:///tmp/a/report.html", HtmlNavigationTarget.mainFrame, false, String?.none, HtmlNavigationDecision.cancel),
        ("file:///tmp/a/report.html", .mainFrame, false, "/tmp/a", .allow),
        ("file:///tmp/a/report.html#section", .mainFrame, true, "/tmp/a", .allow),
        ("file:///tmp/a/other.html", .mainFrame, true, nil, .cancel),
        ("about:blank", .mainFrame, false, nil, .allow),
        ("about:blank#section", .mainFrame, true, nil, .allow),
        ("file:///tmp/a/other.html", .mainFrame, true, "/tmp/a", .allow),
        ("file:///tmp/a/frame.html", .subframe, false, "/tmp/a", .allow),
        ("file:///etc/passwd", .mainFrame, true, "/tmp/a", .cancel),
        ("file:///tmp/ab/x.html", .subframe, false, "/tmp/a", .cancel),
        ("https://example.com/", .mainFrame, true, nil, .openExternal),
        ("http://example.com/", .mainFrame, true, nil, .openExternal),
        ("https://example.com/", .mainFrame, false, nil, .cancel),
        ("https://example.com/", .subframe, false, nil, .cancel),
        ("https://example.com/", .subframe, true, nil, .openExternal),
        ("https://example.com/", .newWindow, true, nil, .openExternal),
        ("https://example.com/", .newWindow, false, nil, .cancel),
        ("file:///tmp/a/report.html", .newWindow, true, nil, .cancel),
        ("about:blank", .subframe, false, nil, .allow),
        ("mailto:a@example.com", .mainFrame, true, nil, .cancel),
        ("x-custom://open", .mainFrame, true, nil, .cancel),
        ("data:text/html,hi", .mainFrame, false, nil, .cancel),
    ])
    func navigationPolicy(_ url: String, _ target: HtmlNavigationTarget, _ userActivated: Bool, _ grant: String?,
                          _ decision: HtmlNavigationDecision) throws {
        let action = HtmlNavigationAction(url: try #require(URL(string: url)), target: target, userActivated: userActivated)
        #expect(HtmlNavigationPolicy.decide(action, overlay: page(grant: grant)) == decision)
    }

    @Test func sessionWideOpenReplacesAHudAndClearsThePriorResult() throws {
        #expect(store.openOverlay(session.id, command: "true"))
        store.recordOverlayExit(session.id, code: 3)
        #expect(store.closeOverlay(session.id))
        #expect(store.openHud(session.id, command: "hud", spec: HudSpec(message: "x"), file: "/tmp/h",
                              size: HudPanelSize(widthPercent: 30, heightPercent: 10)))
        let generation = session.overlaySlotGeneration

        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: 60) == nil)
        #expect(session.htmlOverlayActive)
        #expect(!session.hudActive)
        #expect(session.overlayExitCode == nil)
        #expect(session.overlaySizePercent == 60)
        #expect(session.overlaySlotGeneration == generation + 1)
    }

    @Test func sessionWideOpenIsRefusedOverAProgramOrAPage() {
        #expect(store.openOverlay(session.id, command: "htop"))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == .alreadyOpen)
        #expect(store.closeOverlay(session.id))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == .alreadyOpen)
        #expect(store.openHtmlOverlay(UUID(), pane: nil, overlay: page(), sizePercent: nil) == .unknownSession)
    }

    @Test func aHudOverAPageIsRefused() {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        #expect(!store.openHud(session.id, command: "hud", spec: HudSpec(message: "x"), file: "/tmp/h",
                               size: HudPanelSize(widthPercent: 30, heightPercent: 10)))
        #expect(session.htmlOverlayActive)
    }

    @Test func paneOpenIsRefusedOverAProgramAPageOrAnUnrenderedPane() {
        split()
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "htop") == nil)
        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page(), sizePercent: nil) == .alreadyOpen)
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == .alreadyOpen)
        #expect(session.paneOverlayIsHtml(.right))
        #expect(!session.paneOverlayIsHtml(.left))
    }

    @Test func paneOpenClearsThePanesPriorResult() {
        split()
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "true") == nil)
        store.recordPaneOverlayExit(session.id, pane: .right, code: 4)
        #expect(store.closePaneOverlay(session.id, pane: .right))
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        #expect(session.paneOverlayExitCode(.right) == nil)
    }

    @Test func openIsRefusedWhileAPresenterOwnsTheSession() throws {
        let hub = PresentationHub(staleTimeout: 30)
        let presenter = Sink()
        store.presentationHub = hub
        let hello = PresentationHello(version: 1, kinds: [], mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: presenter) { PresentationSnapshot(status: nil, hud: nil) }
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)

        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == .presenter)
        #expect(!session.overlayActive)
    }

    @Test func reloadBumpsOnlyTheRevisionAndResetsTheLoadState() throws {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        let overlayID = try #require(session.htmlOverlay?.id)
        store.setHtmlLoadState(overlayID, state: .failed, error: "boom")
        let generation = session.overlaySlotGeneration

        #expect(store.reloadHtmlOverlay(session.id, pane: nil) == nil)
        #expect(session.htmlOverlay?.reloadRevision == 1)
        #expect(session.htmlOverlay?.loadState == .loading)
        #expect(session.htmlOverlay?.loadError == nil)
        #expect(session.htmlOverlay?.id == overlayID)
        #expect(session.overlaySlotGeneration == generation)
    }

    @Test func reloadOfTheCurrentPageKeepsWhatTheUserNavigatedTo() throws {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(grant: "/tmp/a"), sizePercent: nil) == nil)
        let overlayID = try #require(session.htmlOverlay?.id)
        let info = HtmlPageInfo(page: "/tmp/a/b.html", title: "B", canGoBack: true, canGoForward: false)
        store.setHtmlPage(overlayID, info)

        #expect(store.reloadHtmlOverlay(session.id, pane: nil, target: .current) == nil)
        #expect(session.htmlOverlay?.reloadTarget == .current)
        #expect(session.htmlOverlay?.current == info)
        #expect(store.reloadHtmlOverlay(session.id, pane: nil) == nil)
        #expect(session.htmlOverlay?.reloadTarget == .original)
        #expect(session.htmlOverlay?.current == nil)
        #expect(session.htmlOverlay?.reloadRevision == 2)
    }

    @Test func aPageCommandIsRefusedOnAnEmptySlotOrAProgram() {
        split()
        #expect(store.htmlOverlayCommandFailure(session.id, pane: nil) == .noOverlay)
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "htop") == nil)
        #expect(store.htmlOverlayCommandFailure(session.id, pane: .left) == .notHtml)
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        #expect(store.htmlOverlayCommandFailure(session.id, pane: .right) == nil)
    }

    @Test func reloadIsRefusedOnAnEmptySlotOrAProgram() {
        split()
        #expect(store.reloadHtmlOverlay(session.id, pane: nil) == .noOverlay)
        #expect(store.reloadHtmlOverlay(session.id, pane: .left) == .noOverlay)
        #expect(store.openOverlay(session.id, command: "htop"))
        #expect(store.reloadHtmlOverlay(session.id, pane: nil) == .notHtml)
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "htop") == nil)
        #expect(store.reloadHtmlOverlay(session.id, pane: .left) == .notHtml)
        #expect(store.reloadHtmlOverlay(UUID(), pane: nil) == .unknownSession)
    }

    @Test func loadStateReachesTheSlotByOccupantID() throws {
        split()
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        let overlayID = try #require(session.paneOverlay(.right)?.html?.id)

        store.setHtmlLoadState(overlayID, state: .loaded, error: nil)
        #expect(session.paneOverlay(.right)?.html?.loadState == .loaded)
        store.setHtmlLoadState(UUID(), state: .failed, error: "stray")
        #expect(session.paneOverlay(.right)?.html?.loadState == .loaded)
    }

    @Test func loadStateReachesASoftClosedSession() throws {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        let overlayID = try #require(session.htmlOverlay?.id)
        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(store.session(withID: session.id) == nil)

        store.setHtmlLoadState(overlayID, state: .failed, error: "gone")
        #expect(session.htmlOverlay?.loadState == .failed)
        #expect(session.htmlOverlay?.loadError == "gone")
    }

    @Test func swapKeepsEachPageWithItsIdentity() throws {
        split()
        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page("/tmp/l.html"), sizePercent: nil) == nil)
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page("/tmp/r.html"), sizePercent: nil) == nil)
        let left = try #require(session.paneOverlay(.left)?.html)
        let right = try #require(session.paneOverlay(.right)?.html)

        #expect(store.swapPanes(session.id) == nil)
        #expect(session.paneOverlay(.left)?.html == right)
        #expect(session.paneOverlay(.right)?.html == left)

        store.setHtmlLoadState(right.id, state: .loaded, error: nil)
        #expect(session.paneOverlay(.left)?.html?.loadState == .loaded)
        #expect(store.reloadHtmlOverlay(session.id, pane: .left) == nil)
        #expect(session.paneOverlay(.left)?.html?.reloadRevision == 1)
    }

    @Test func promotionMovesTheRightPageIntoTheLeftSlot() throws {
        split()
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        let right = try #require(session.paneOverlay(.right)?.html)

        store.closePrimaryPane(session.id)
        #expect(session.paneOverlay(.left)?.html?.id == right.id)
        #expect(session.paneOverlay(.right) == nil)
        #expect(released().isEmpty)

        #expect(store.closePaneOverlay(session.id, pane: .left))
        #expect(released() == [right.id])
    }

    @Test func dropUnrealizedPaneOverlaysKeepsAPage() {
        split()
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        session.isSplit = false
        session.splitFocused = false
        session.dropUnrealizedPaneOverlays()
        #expect(session.paneOverlayIsHtml(.right))
        session.isSplit = true
        #expect(session.paneOverlayIsHtml(.right))
    }

    @Test func explicitClosesReleaseEachPageOnce() throws {
        split()
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        let wide = try #require(session.htmlOverlay?.id)
        #expect(store.closeOverlay(session.id))
        #expect(!store.closeOverlay(session.id))
        #expect(session.htmlOverlay == nil)

        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page(), sizePercent: nil) == nil)
        let left = try #require(session.paneOverlay(.left)?.html?.id)
        #expect(store.closePaneOverlay(session.id, pane: .left))
        #expect(!store.closePaneOverlay(session.id, pane: .left))

        #expect(released() == [wide, left])
    }

    @Test func closingAProgramPaneKeepsItsExitCode() {
        split()
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "true") == nil)
        store.recordPaneOverlayExit(session.id, pane: .right, code: 2)
        #expect(store.closePaneOverlay(session.id, pane: .right))
        #expect(session.paneOverlayExitCode(.right) == 2)
    }

    @Test func sessionCloseReleasesBothKindsOfPageOnce() throws {
        split()
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page(), sizePercent: nil) == nil)
        let ids = [try #require(session.htmlOverlay?.id), try #require(session.paneOverlay(.left)?.html?.id)]

        store.closeSession(session.id)
        #expect(Set(released()) == Set(ids))
        #expect(released().count == 2)
    }

    @Test func workspaceRemovalReleasesThePage() throws {
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        let id = try #require(session.htmlOverlay?.id)
        store.addWorkspace(name: "other")
        store.removeWorkspace(workspace.id)
        #expect(released() == [id])
    }

    @Test func finalizingASoftCloseReleasesThePageOnce() throws {
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        let id = try #require(session.htmlOverlay?.id)
        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(released().isEmpty)
        store.finalizeAllPendingCloses()
        #expect(released() == [id])
    }

    @Test func splitCloseReleasesTheSplitPanesPage() throws {
        split()
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        let id = try #require(session.paneOverlay(.right)?.html?.id)
        store.closeSplit(session.id)
        #expect(released() == [id])
    }

    @Test func aSessionWidePageCoversWithoutBeingAProgram() {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        #expect(session.coverOverlayActive)
        #expect(!session.programOverlayActive)
        #expect(session.topmostSurface == nil)
        #expect(session.focusTarget(wantSplit: false) == nil)
        #expect(session.htmlCovers(nil))
        #expect(!session.htmlCovers(.left))
    }

    @Test func aPanePageLeavesNoTerminalFocusTarget() {
        split()
        session.splitFocused = true
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        #expect(session.topmostSurface == nil)
        #expect(session.focusTarget(wantSplit: true) == nil)
        #expect(session.htmlCovers(.right))
    }

    @Test func zoomHasNoTargetUnderASessionWidePage() {
        store.selectSession(session.id)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        #expect(TerminalZoomController.resolveTarget(store: store) == nil)
        #expect(!TerminalZoomSurface.overlay.isAvailable(in: session))
        #expect(!TerminalZoomSurface.primary.isVisible(in: session))
    }

    @Test(arguments: [OverlayPane.left, .right])
    func zoomHasNoTargetUnderAPageOnTheFocusedPane(_ pane: OverlayPane) {
        split()
        store.selectSession(session.id)
        session.splitFocused = pane == .right
        #expect(store.openHtmlOverlay(session.id, pane: pane, overlay: page(), sizePercent: nil) == nil)
        #expect(TerminalZoomController.resolveTarget(store: store) == nil)
        #expect(!pane.zoomSurface.isAvailable(in: session))
    }

    @Test func treeReportsAPageAsAnOverlay() throws {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: 40) == nil)
        let node = try #require(store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString })
        #expect(node.overlay)
        #expect(node.overlaySizePercent == 40)
    }

    @Test func aPageIsFoundAndClosedByItsIdentityAfterASwap() throws {
        split()
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page(), sizePercent: nil) == nil)
        let id = try #require(session.paneOverlay(.left)?.html?.id)
        #expect(store.swapPanes(session.id) == nil)

        let slot = try #require(store.htmlOverlaySlot(id))
        #expect(slot.session === session)
        #expect(slot.pane == .right)
        #expect(store.closeHtmlOverlay(id))
        #expect(session.paneOverlay(.right) == nil)
        #expect(released() == [id])
        #expect(!store.closeHtmlOverlay(id))
        #expect(store.htmlOverlaySlot(id) == nil)
    }

    @Test func theTopmostPageFollowsWhatCoversTheFocusedPane() throws {
        split()
        session.splitFocused = false
        #expect(session.topmostHtmlOverlay == nil)
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page("/tmp/r.html"), sizePercent: nil) == nil)
        #expect(session.topmostHtmlOverlay == nil)
        session.splitFocused = true
        #expect(session.topmostHtmlOverlay?.file == "/tmp/r.html")
        session.scratchActive = true
        #expect(session.topmostHtmlOverlay == nil)
        session.scratchActive = false
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page("/tmp/w.html"), sizePercent: nil) == nil)
        #expect(session.topmostHtmlOverlay?.file == "/tmp/w.html")
    }

    @Test func theThemeStylesheetYieldsToAnyPageRule() {
        let theme = HtmlOverlayTheme(background: "#102030", foreground: "#e0e0e0", dark: true)
        #expect(theme.stylesheet == ":where(html) { color-scheme: dark; color: #e0e0e0; }")
        #expect(theme.background == "#102030")
        #expect(theme.script.contains(theme.stylesheet))
        #expect(theme.script.contains("agterm-theme"))
    }

    @Test func aMalformedThemeColorFallsBackToAPlainPair() {
        let theme = HtmlOverlayTheme(background: "red; } body { display: none", foreground: "#ffffff", dark: false)
        #expect(theme.background == "#ffffff")
        #expect(theme.foreground == "#1e1e1e")
        #expect(!theme.stylesheet.contains("display"))
    }
}
