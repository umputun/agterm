import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreReplicaPageTests {
    static let remoteLeft = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let remoteRight = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
    static let origin = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!

    private final class Changes { var ids: [UUID] = [] }

    private func attached(split: Bool = true) throws -> (AppStore, Session) {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", remoteHost: "buildbox"))
        if split { store.toggleSplit(session.id) }
        var daemons = [session.paneIdentity: ZmxSupport.daemonName(for: Self.remoteLeft)]
        if let local = session.splitPaneIdentity { daemons[local] = ZmxSupport.daemonName(for: Self.remoteRight) }
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: daemons, presentationVersion: 1),
                         forSession: session.id)
        return (store, session)
    }

    private func page(_ source: PresentationPageSource = .file(path: "/docs/index.html", grantRoot: "/docs"),
                      id: UUID = AppStoreReplicaPageTests.origin, pane: PresentationPane? = nil, size: Int? = nil,
                      follow: Bool = false) -> PresentationPage {
        PresentationPage(page: id.uuidString, token: "tok", source: source, identity: "index.html", chromeless: false,
                         javascript: true, navigation: true, browse: false, persistent: false, backgroundColor: "#102030",
                         pane: pane, sizePercent: size, follow: follow)
    }

    @Test func aFilePageIsShownSessionWideUnderItsOwnId() throws {
        let (store, session) = try attached()

        #expect(store.presentReplicaPage(page(size: 70), forSession: session.id) == nil)

        let shown = try #require(session.htmlOverlay)
        #expect(session.htmlOverlayActive)
        #expect(shown.source == .replica(path: "/docs/index.html"))
        #expect(shown.replicaOf == Self.origin)
        #expect(shown.id != Self.origin)
        #expect(shown.javascript && shown.navigation)
        #expect(session.overlaySizePercent == 70)
        #expect(session.overlayBackgroundColor == "#102030")
        #expect(HtmlPageOutcomes.shared.outcome(for: shown.id) == nil)
        #expect(store.replicaPage(Self.origin.uuidString, forSession: session.id)?.page.id == shown.id)
    }

    @Test func aPageWithoutAGrantIsShownAsAReplicaOfItsFile() throws {
        let (store, session) = try attached()

        #expect(store.presentReplicaPage(page(.file(path: "/docs/index.html", grantRoot: nil)), forSession: session.id) == nil)

        #expect(session.htmlOverlay?.source == .replica(path: "/docs/index.html"))
    }

    @Test func aUrlPageLoadsItsFullAddressHere() throws {
        let (store, session) = try attached()

        #expect(store.presentReplicaPage(page(.url("https://example.com/a?b=1")), forSession: session.id) == nil)

        #expect(session.htmlOverlay?.source == .url(try #require(URL(string: "https://example.com/a?b=1"))))
        #expect(session.htmlOverlay?.replicaOf == Self.origin)
    }

    @Test func aPagePresentedForTheOriginsSplitTakesTheMappedPane() throws {
        let (store, session) = try attached()

        #expect(store.presentReplicaPage(page(pane: .identity(Self.remoteRight)), forSession: session.id) == nil)

        #expect(session.paneOverlay(.right)?.html?.replicaOf == Self.origin)
        #expect(!session.htmlOverlayActive)
        #expect(store.replicaPage(Self.origin.uuidString, forSession: session.id)?.pane == .right)
    }

    @Test(arguments: [
        (PresentationPageSource.url("not a url"), PresentationPane?.none, "invalid url"),
        (PresentationPageSource.file(path: "/a.html", grantRoot: nil), PresentationPane.identity(UUID()), PaneOverlayError.paneNotVisible),
    ])
    func aPageThatCannotBePlacedIsRefused(source: PresentationPageSource, pane: PresentationPane?, reason: String) throws {
        let (store, session) = try attached()

        #expect(store.presentReplicaPage(page(source, pane: pane), forSession: session.id) == reason)
        #expect(!session.overlayActive)
    }

    @Test func aTakenSlotRefusesThePage() throws {
        let (store, session) = try attached()
        #expect(store.openOverlay(session.id, command: "top"))

        #expect(store.presentReplicaPage(page(), forSession: session.id) == "overlay already open")
        #expect(session.htmlOverlay == nil)
    }

    @Test func followSelectsTheSession() throws {
        let (store, session) = try attached()
        let ws = try #require(store.currentWorkspaceID)
        let other = try #require(store.addSession(toWorkspace: ws, cwd: "/tmp"))
        store.selectSession(other.id)

        #expect(store.presentReplicaPage(page(follow: true), forSession: session.id) == nil)

        #expect(store.selectedSessionID == session.id)
    }

    @Test func closingByOriginIdFreesTheSlot() throws {
        let (store, session) = try attached()
        #expect(store.presentReplicaPage(page(pane: .identity(Self.remoteRight)), forSession: session.id) == nil)

        store.closeReplicaPage(UUID().uuidString, forSession: session.id)
        #expect(session.paneOverlay(.right) != nil)
        store.closeReplicaPage(Self.origin.uuidString, forSession: session.id)

        #expect(session.paneOverlay(.right) == nil)
    }

    @Test func losingTheStreamClosesThePages() throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        #expect(store.presentReplicaPage(page(), forSession: session.id) == nil)

        store.setRemoteConnection(.failed("gone"), forSession: session.id)

        #expect(!session.overlayActive)
        #expect(session.htmlOverlay == nil)
    }

    @Test func aSocketSubmitOnAReplicaIsRefusedAndLeavesItOpen() throws {
        let (store, session) = try attached()
        #expect(store.presentReplicaPage(page(), forSession: session.id) == nil)

        #expect(store.submitHtmlOverlay(session.id, pane: nil, value: "x") == .replica)

        #expect(session.htmlOverlayActive)
    }

    @Test func hidingTheReplicaLeavesItsNeighbourAlone() throws {
        let (store, session) = try attached()
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "top") == nil)
        #expect(store.presentReplicaPage(page(), forSession: session.id) == nil)
        let changes = Changes()
        store.onReplicaPageChanged = { changes.ids.append($0) }
        let local = try #require(session.htmlOverlay?.id)

        store.setReplicaPageHidden(Self.origin.uuidString, forSession: session.id, hidden: true)

        #expect(session.overlayHidden(nil))
        #expect(!session.overlayHidden(.right))
        #expect(changes.ids == [local])
        #expect(store.replicaPageState(local, appliedSeq: 3)?.hidden == true)
    }

    @Test func aLocalHideOfTheReplicaIsReported() throws {
        let (store, session) = try attached()
        #expect(store.presentReplicaPage(page(), forSession: session.id) == nil)
        let changes = Changes()
        store.onReplicaPageChanged = { changes.ids.append($0) }

        store.setOverlaysHidden(session.id, pane: nil, hidden: true)

        #expect(changes.ids == [try #require(session.htmlOverlay?.id)])
    }

    @Test func aLocalPaneOpenerOverTheReplicaLeavesItsReportedStateAlone() throws {
        let (store, session) = try attached()
        #expect(store.presentReplicaPage(page(), forSession: session.id) == nil)
        let local = try #require(session.htmlOverlay?.id)
        let changes = Changes()
        store.onReplicaPageChanged = { changes.ids.append($0) }

        #expect(store.openPaneOverlay(session.id, pane: .right, command: "top") == nil)

        #expect(!session.htmlOverlayVisible)
        #expect(store.replicaPageState(local, appliedSeq: 1)?.hidden == false)
        #expect(changes.ids.isEmpty)
    }

    @Test func anOriginHideOutlivesALocalPaneOpener() throws {
        let (store, session) = try attached()
        #expect(store.presentReplicaPage(page(), forSession: session.id) == nil)
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "top") == nil)

        store.setReplicaPageHidden(Self.origin.uuidString, forSession: session.id, hidden: true)
        #expect(store.closePaneOverlay(session.id, pane: .right))

        #expect(!session.htmlOverlayVisible)
        let local = try #require(session.htmlOverlay?.id)
        #expect(store.replicaPageState(local, appliedSeq: 1)?.hidden == true)
    }

    @Test func theStateMirrorsWhatThePageReported() throws {
        let (store, session) = try attached()
        #expect(store.presentReplicaPage(page(), forSession: session.id) == nil)
        let local = try #require(session.htmlOverlay?.id)
        let changes = Changes()
        store.onReplicaPageChanged = { changes.ids.append($0) }

        store.setHtmlLoadState(local, state: .loaded, error: nil)
        store.setHtmlPage(local, HtmlPageInfo(page: "/docs/next.html", title: "Next", canGoBack: true, canGoForward: false))

        #expect(changes.ids == [local, local])
        let state = try #require(store.replicaPageState(local, appliedSeq: 5))
        #expect(state == PresentationPageState(page: Self.origin.uuidString, title: "Next", address: "/docs/next.html",
                                               load: .loaded, error: nil, canGoBack: true, canGoForward: false,
                                               hidden: false, appliedSeq: 5))
    }

    @Test func aLocalPageReportsNoReplicaChange() throws {
        let (store, session) = try attached()
        let local = HtmlOverlay(source: .file(path: "/a.html", grantRoot: nil))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: local, sizePercent: nil) == nil)
        let changes = Changes()
        store.onReplicaPageChanged = { changes.ids.append($0) }

        store.setHtmlLoadState(local.id, state: .loaded, error: nil)

        #expect(changes.ids.isEmpty)
        #expect(store.replicaPageState(local.id, appliedSeq: 0) == nil)
    }

    private final class Releases { var pairs: [[UUID]] = [] }

    private func releases(of local: UUID, during action: () -> Void) -> [[UUID]] {
        let seen = Releases()
        HtmlOverlayReleases.shared.onReplicaRelease = { if $0 == local { seen.pairs.append([$0, $1]) } }
        defer { HtmlOverlayReleases.shared.onReplicaRelease = nil }
        action()
        return seen.pairs
    }

    @Test func closingAUrlReplicaHereTellsItsOriginOnce() throws {
        let (store, session) = try attached()
        #expect(store.presentReplicaPage(page(.url("https://example.com/")), forSession: session.id) == nil)
        let local = try #require(session.htmlOverlay?.id)

        let seen = releases(of: local) {
            store.closeOverlay(session.id)
            store.closeOverlay(session.id)
        }

        #expect(seen == [[local, Self.origin]])
    }

    @Test func removingTheSessionTellsTheOriginOfAPanePage() throws {
        let (store, session) = try attached()
        #expect(store.presentReplicaPage(page(.url("https://example.com/"), pane: .identity(Self.remoteRight)),
                                         forSession: session.id) == nil)
        let local = try #require(session.paneOverlay(.right)?.html?.id)

        let seen = releases(of: local) { store.closeSession(session.id) }

        #expect(seen == [[local, Self.origin]])
    }

    @Test func aLocalPageIsNoReplicaRelease() throws {
        let (store, session) = try attached()
        let local = HtmlOverlay(source: .file(path: "/a.html", grantRoot: nil))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: local, sizePercent: nil) == nil)

        #expect(releases(of: local.id) { store.closeOverlay(session.id) }.isEmpty)
    }

    @Test func resizeReachesOnlyTheSessionWideSlot() throws {
        let (store, session) = try attached()
        #expect(store.presentReplicaPage(page(size: 50), forSession: session.id) == nil)

        store.resizeReplicaPage(Self.origin.uuidString, forSession: session.id, sizePercent: 80)

        #expect(session.overlaySizePercent == 80)
    }
}
