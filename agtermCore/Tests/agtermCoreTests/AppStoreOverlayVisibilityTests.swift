import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreOverlayVisibilityTests {
    private final class Events {
        var kinds: [ControlEventKind] = []
        var treeChanges: Int { kinds.filter { $0 == .treeChanged }.count }
    }

    private struct Fixture {
        let store: AppStore
        let session: Session
        let events: Events
    }

    private func makeFixture() throws -> Fixture {
        let events = Events()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: dir),
                             controlEventSink: { events.kinds.append($0.kind) }, paneFinalizer: nil)
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        return Fixture(store: store, session: session, events: events)
    }

    private func openAll(_ fixture: Fixture) {
        let id = fixture.session.id
        #expect(fixture.store.openOverlay(id, command: "less"))
        #expect(fixture.store.openPaneOverlay(id, pane: .left, command: "htop") == nil)
        #expect(fixture.store.openPaneOverlay(id, pane: .right, command: "top") == nil)
    }

    @Test func hidingAndShowingTheSessionActsOnEverySlotAndKeepsOccupants() throws {
        let fixture = try makeFixture()
        let session = fixture.session
        openAll(fixture)

        #expect(fixture.store.setOverlaysHidden(session.id, pane: nil, hidden: true) == nil)
        #expect(session.hiddenOverlayNames == ["session", "left", "right"])
        #expect(session.overlayActive)
        #expect(session.openPaneOverlays == [.left, .right])
        #expect(!session.coverOverlayVisible)

        #expect(fixture.store.setOverlaysHidden(session.id, pane: nil, hidden: false) == nil)
        #expect(session.hiddenOverlayNames.isEmpty)
        #expect(session.coverOverlayVisible)
    }

    @Test(arguments: OverlayPane.allCases)
    func paneScopeTouchesOnlyThatPane(pane: OverlayPane) throws {
        let fixture = try makeFixture()
        openAll(fixture)

        #expect(fixture.store.setOverlaysHidden(fixture.session.id, pane: pane, hidden: true) == nil)

        #expect(fixture.session.hiddenOverlayNames == [pane.rawValue])
    }

    @Test func treeChangedFiresOnlyOnAnActualTransition() throws {
        let fixture = try makeFixture()
        let id = fixture.session.id
        openAll(fixture)
        let before = fixture.events.treeChanges

        fixture.store.setOverlaysHidden(id, pane: .left, hidden: true)
        #expect(fixture.events.treeChanges == before + 1)
        fixture.store.setOverlaysHidden(id, pane: .left, hidden: true)
        #expect(fixture.events.treeChanges == before + 1)
        fixture.store.setOverlaysHidden(id, pane: .left, hidden: false)
        #expect(fixture.events.treeChanges == before + 2)
        #expect(fixture.store.setOverlaysHidden(id, pane: .left, hidden: false) == nil)
        #expect(fixture.events.treeChanges == before + 2)
    }

    @Test func toggleHidesEverythingWhileAnyIsShownThenShowsAll() throws {
        let fixture = try makeFixture()
        let session = fixture.session
        openAll(fixture)
        fixture.store.setOverlaysHidden(session.id, pane: .left, hidden: true)

        #expect(fixture.store.toggleOverlaysHidden(session.id, pane: nil) == nil)
        #expect(session.hiddenOverlayNames == ["session", "left", "right"])

        #expect(fixture.store.toggleOverlaysHidden(session.id, pane: nil) == nil)
        #expect(session.hiddenOverlayNames.isEmpty)
    }

    @Test func toggleWithAPaneFlipsOnlyThatPane() throws {
        let fixture = try makeFixture()
        let session = fixture.session
        openAll(fixture)

        #expect(fixture.store.toggleOverlaysHidden(session.id, pane: .right) == nil)
        #expect(session.hiddenOverlayNames == ["right"])
        #expect(fixture.store.toggleOverlaysHidden(session.id, pane: .right) == nil)
        #expect(session.hiddenOverlayNames.isEmpty)
    }

    @Test func refusesAnUnknownSessionAndAnEmptyScope() throws {
        let fixture = try makeFixture()

        #expect(fixture.store.setOverlaysHidden(UUID(), pane: nil, hidden: true) == .unknownSession)
        #expect(fixture.store.toggleOverlaysHidden(UUID(), pane: nil) == .unknownSession)
        #expect(fixture.store.setOverlaysHidden(fixture.session.id, pane: nil, hidden: true) == .noOverlay)
        #expect(fixture.store.toggleOverlaysHidden(fixture.session.id, pane: .left) == .noOverlay)
    }

    @Test func aHudAloneHasNothingToHide() throws {
        let fixture = try makeFixture()
        fixture.session.overlayActive = true
        fixture.session.hudSpec = HudSpec(message: "deploying")

        #expect(fixture.store.toggleOverlaysHidden(fixture.session.id, pane: nil) == .noOverlay)
        #expect(!fixture.session.overlayHidden)
    }

    @Test func sessionScopeSkipsARemoteReservationAndActsOnLocalSlots() throws {
        let fixture = try makeFixture()
        let session = fixture.session
        session.remoteOverlays.reserve(RemoteOverlaySlot(job: "job", pane: .right, owner: 1, sizePercent: nil))

        #expect(fixture.store.toggleOverlaysHidden(session.id, pane: nil) == .remote)
        #expect(fixture.store.toggleOverlaysHidden(session.id, pane: .right) == .remote)

        #expect(fixture.store.openPaneOverlay(session.id, pane: .left, command: "htop") == nil)
        #expect(fixture.store.toggleOverlaysHidden(session.id, pane: nil) == nil)
        #expect(session.hiddenOverlayNames == ["left"])
    }

    @Test func closingTheSessionSlotClearsItsBitAndANewOccupantStartsShown() throws {
        let fixture = try makeFixture()
        let id = fixture.session.id
        #expect(fixture.store.openOverlay(id, command: "less"))
        fixture.store.setOverlaysHidden(id, pane: nil, hidden: true)

        #expect(!fixture.store.openOverlay(id, command: "vim"))
        #expect(fixture.store.closeOverlay(id))
        #expect(!fixture.session.overlayHidden)
        #expect(fixture.store.openOverlay(id, command: "vim"))
        #expect(fixture.session.coverOverlayVisible)
    }

    @Test func closingAPaneSlotClearsItsBitAndAReopenStartsShown() throws {
        let fixture = try makeFixture()
        let id = fixture.session.id
        #expect(fixture.store.openPaneOverlay(id, pane: .left, command: "htop") == nil)
        fixture.store.setOverlaysHidden(id, pane: .left, hidden: true)

        #expect(fixture.store.openPaneOverlay(id, pane: .left, command: "top") == .alreadyOpen)
        #expect(fixture.store.closePaneOverlay(id, pane: .left))
        #expect(fixture.store.openPaneOverlay(id, pane: .left, command: "top") == nil)
        #expect(fixture.session.paneOverlayVisible(.left))
    }

    @Test func aWaitProgramExitKeepsTheSlotHidden() throws {
        let fixture = try makeFixture()
        let id = fixture.session.id
        #expect(fixture.store.openOverlay(id, command: "make", wait: true))
        fixture.store.setOverlaysHidden(id, pane: nil, hidden: true)

        fixture.store.recordOverlayExit(id, code: 2)

        #expect(fixture.session.overlayHidden)
        #expect(fixture.session.overlayActive)
    }

    @Test(arguments: [OverlayPane?.none, .left])
    func aPageUpdateKeepsItsSlotHidden(pane: OverlayPane?) throws {
        let fixture = try makeFixture()
        let id = fixture.session.id
        let page = HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))
        #expect(fixture.store.openHtmlOverlay(id, pane: pane, overlay: page, sizePercent: nil) == nil)
        fixture.store.setOverlaysHidden(id, pane: pane, hidden: true)

        fixture.store.setHtmlLoadState(page.id, state: .loaded, error: nil)

        #expect(fixture.session.overlayHidden(pane))
        let node = try #require(fixture.store.controlTree().workspaces[0].sessions[0].htmlOverlays?.first)
        #expect(node.hidden == true)
        #expect(node.state == "loaded")
    }

    @Test(arguments: [OverlayPane?.none, .right])
    func aReplicaUpdateKeepsItsSlotHidden(pane: OverlayPane?) throws {
        let fixture = try makeFixture()
        let id = fixture.session.id
        if let pane {
            #expect(fixture.store.openPaneOverlay(id, pane: pane, command: "job") == nil)
        } else {
            #expect(fixture.store.openOverlay(id, command: "job"))
        }
        fixture.store.setOverlaysHidden(id, pane: pane, hidden: true)

        fixture.session.setOverlayReplica(OverlayReplica(job: "job"), pane: pane)

        #expect(fixture.session.overlayHidden(pane))
    }

    @Test func visibleCoverChangesOnlyWithWhatOwnsTheKeyboard() throws {
        let fixture = try makeFixture()
        let session = fixture.session
        let id = session.id
        #expect(session.visibleCover == nil)

        #expect(fixture.store.openOverlay(id, command: "less"))
        #expect(session.visibleCover == .session)
        fixture.store.setOverlaysHidden(id, pane: nil, hidden: true)
        #expect(session.visibleCover == nil)
        fixture.store.setOverlaysHidden(id, pane: nil, hidden: false)
        #expect(session.visibleCover == .session)
        fixture.store.setOverlaysHidden(id, pane: nil, hidden: true)
        #expect(fixture.store.closeOverlay(id))
        #expect(session.visibleCover == nil, "closing a hidden overlay leaves the terminal in charge")
    }

    // regression: hiding or closing the unfocused pane's overlay refocused the active pane and stole Find's keys.
    @Test func theOtherPanesOverlayNeverChangesTheVisibleCover() throws {
        let fixture = try makeFixture()
        let session = fixture.session
        let id = session.id
        session.splitFocused = false
        #expect(fixture.store.openPaneOverlay(id, pane: .right, command: "htop") == nil)
        #expect(session.visibleCover == nil)

        fixture.store.setOverlaysHidden(id, pane: .right, hidden: true)
        #expect(session.visibleCover == nil)
        fixture.store.setOverlaysHidden(id, pane: .right, hidden: false)
        #expect(session.visibleCover == nil)
        #expect(fixture.store.closePaneOverlay(id, pane: .right))
        #expect(session.visibleCover == nil)

        #expect(fixture.store.openPaneOverlay(id, pane: .left, command: "htop") == nil)
        #expect(session.visibleCover == .focusedPane)
        fixture.store.setOverlaysHidden(id, pane: .left, hidden: true)
        #expect(session.visibleCover == nil)
    }

    // regression: a pane overlay changing under the scratch refocused the scratch and stole Find's keys.
    @Test func aPaneOverlayUnderTheScratchNeverChangesTheVisibleCover() throws {
        let fixture = try makeFixture()
        let session = fixture.session
        let id = session.id
        session.splitFocused = false
        session.scratchActive = true

        #expect(fixture.store.openPaneOverlay(id, pane: .left, command: "htop") == nil)
        #expect(session.visibleCover == nil)
        fixture.store.setOverlaysHidden(id, pane: .left, hidden: true)
        #expect(session.visibleCover == nil)
        #expect(fixture.store.closePaneOverlay(id, pane: .left))
        #expect(session.visibleCover == nil)

        #expect(fixture.store.openOverlay(id, command: "less"))
        #expect(session.visibleCover == .session, "a session-wide overlay draws above the scratch")
    }

    @Test func aPagesOwnHideUsesThePageScope() throws {
        let fixture = try makeFixture()
        let id = fixture.session.id
        let panePage = HtmlOverlay(source: .file(path: "/tmp/pane.html", grantRoot: nil))
        #expect(fixture.store.openOverlay(id, command: "less"))
        #expect(fixture.store.openHtmlOverlay(id, pane: .right, overlay: panePage, sizePercent: nil) == nil)

        #expect(fixture.store.hideHtmlOverlay(panePage.id))
        #expect(fixture.session.hiddenOverlayNames == ["right"], "a pane page hides its own pane only")

        #expect(fixture.store.closePaneOverlay(id, pane: .right))
        #expect(!fixture.store.hideHtmlOverlay(panePage.id), "a page that left its slot has nothing to hide")
    }

    @Test func aSessionWidePagesOwnHideHidesTheSession() throws {
        let fixture = try makeFixture()
        let id = fixture.session.id
        let page = HtmlOverlay(source: .file(path: "/tmp/session.html", grantRoot: nil))
        #expect(fixture.store.openHtmlOverlay(id, pane: nil, overlay: page, sizePercent: nil) == nil)
        #expect(fixture.store.openPaneOverlay(id, pane: .left, command: "htop") == nil)

        #expect(fixture.store.hideHtmlOverlay(page.id))

        #expect(fixture.session.hiddenOverlayNames == ["session", "left"])
    }
}
