import Foundation
import Testing
@testable import agtermCore

@MainActor
struct SessionOverlayVisibilityTests {
    enum Occupant: CaseIterable { case empty, fullProgram, floatingProgram, page, hud }

    @Test(arguments: Occupant.allCases, [false, true])
    func visiblePredicatesSubtractTheHiddenBit(occupant: Occupant, hidden: Bool) {
        let session = Session(initialCwd: "/tmp")
        switch occupant {
        case .empty: break
        case .fullProgram: session.overlayActive = true
        case .floatingProgram:
            session.overlayActive = true
            session.overlaySizePercent = 60
        case .page:
            session.overlayActive = true
            session.htmlOverlay = HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))
        case .hud:
            session.overlayActive = true
            session.hudSpec = HudSpec(message: "deploying")
        }
        session.overlayHidden = hidden

        #expect(session.coverOverlayVisible == (session.coverOverlayActive && !hidden))
        #expect(session.programOverlayVisible == (session.programOverlayActive && !hidden))
        #expect(session.htmlOverlayVisible == (session.htmlOverlayActive && !hidden))
        #expect(session.fullOverlayVisible == (session.fullOverlayActive && !hidden))
        #expect(session.coverOverlayActive == [.fullProgram, .floatingProgram, .page].contains(occupant))
        #expect(session.overlayHidden(nil) == hidden)
    }

    @Test(arguments: OverlayPane.allCases)
    func paneVisibilityFollowsItsOverlayHiddenBit(pane: OverlayPane) {
        let session = Session(initialCwd: "/tmp")
        #expect(!session.paneOverlayVisible(pane))
        #expect(!session.overlayHidden(pane))

        session.setPaneOverlay(PaneOverlay(command: "htop"), pane: pane)
        #expect(session.paneOverlayVisible(pane))

        session.setOverlayHidden(true, slot: pane)
        #expect(!session.paneOverlayVisible(pane))
        #expect(session.overlayHidden(pane))
        #expect(session.paneOverlay(pane)?.command == "htop")
        #expect(!session.overlayHidden(nil))
    }

    @Test func anyOverlayShownCountsOnlyUnhiddenSlotsInScope() {
        let session = Session(initialCwd: "/tmp")
        #expect(!session.anyOverlayShown(nil))

        session.overlayActive = true
        session.setPaneOverlay(PaneOverlay(command: "htop"), pane: .right)
        #expect(session.anyOverlayShown(nil))

        session.overlayHidden = true
        #expect(session.anyOverlayShown(nil))
        #expect(session.anyOverlayShown(.right))
        #expect(!session.anyOverlayShown(.left))

        session.setOverlayHidden(true, slot: .right)
        #expect(!session.anyOverlayShown(nil))
        #expect(!session.anyOverlayShown(.right))
    }

    @Test func hideableSlotsSkipAHudAndEmptyPanes() {
        let session = Session(initialCwd: "/tmp")
        session.overlayActive = true
        session.hudSpec = HudSpec(message: "deploying")
        session.setPaneOverlay(PaneOverlay(command: "htop"), pane: .right)

        #expect(session.hideableOverlaySlots(nil) == [.right])
        #expect(session.hideableOverlaySlots(.left).isEmpty)
        #expect(session.hideableOverlaySlots(.right) == [.right])
    }

    @Test func hideableSlotsListSessionThenLeftThenRight() {
        let session = Session(initialCwd: "/tmp")
        session.overlayActive = true
        session.setPaneOverlay(PaneOverlay(command: "a"), pane: .right)
        session.setPaneOverlay(PaneOverlay(command: "b"), pane: .left)

        #expect(session.hideableOverlaySlots(nil) == [nil, .left, .right])
    }

    @Test func hiddenOverlayNamesListOnlyHiddenSlotsInOrder() {
        let session = Session(initialCwd: "/tmp")
        session.overlayActive = true
        session.setPaneOverlay(PaneOverlay(command: "a"), pane: .left)
        session.setPaneOverlay(PaneOverlay(command: "b"), pane: .right)
        #expect(session.hiddenOverlayNames.isEmpty)

        session.setOverlayHidden(true, slot: .right)
        session.setOverlayHidden(true, slot: nil)
        #expect(session.hiddenOverlayNames == ["session", "right"])
    }

    @Test func promotedPaneOverlayKeepsItsHiddenBit() {
        let session = Session(initialCwd: "/tmp")
        session.setPaneOverlay(PaneOverlay(command: "htop"), pane: .right)
        session.setOverlayHidden(true, slot: .right)

        session.promotePaneOverlay()

        #expect(session.overlayHidden(.left))
        #expect(session.paneOverlay(.left)?.command == "htop")
        #expect(session.paneOverlay(.right) == nil)
    }

    @Test(arguments: [OverlayPane?.none, .left, .right])
    func refusalNamesARemoteReservationInScope(pane: OverlayPane?) {
        let session = Session(initialCwd: "/tmp")
        #expect(session.overlayVisibilityRefusal(pane) == .noOverlay)

        session.remoteOverlays.reserve(RemoteOverlaySlot(job: "job", pane: .right, owner: 1, sizePercent: nil))

        #expect(session.overlayVisibilityRefusal(pane) == (pane == .left ? .noOverlay : .remote))
    }

    @Test func focusRoutingSkipsHiddenCoversAndLandsOnThePane() {
        let session = Session(initialCwd: "/tmp")
        let primary = SpySurface()
        let program = SpySurface()
        let paneProgram = SpySurface()
        session.surface = primary
        session.overlayActive = true
        session.overlaySurface = program
        session.setPaneOverlay(PaneOverlay(command: "htop"), pane: .left)
        session.setPaneOverlaySurface(paneProgram, pane: .left)
        #expect(session.topmostSurface === program)

        session.setOverlayHidden(true, slot: nil)
        #expect(session.topmostSurface === paneProgram)
        #expect(session.focusedOverlayPane == .left)
        #expect(session.focusTarget(wantSplit: false) === paneProgram)

        session.setOverlayHidden(true, slot: .left)
        #expect(session.topmostSurface === primary)
        #expect(session.focusedOverlayPane == nil)
        #expect(session.focusTarget(wantSplit: false) === primary)
    }

    @Test func aHiddenPageNeitherTakesTheKeysNorHidesTheTerminalFromFontCommands() {
        let session = Session(initialCwd: "/tmp")
        session.overlayActive = true
        session.htmlOverlay = HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))
        session.setPaneOverlay(PaneOverlay(html: HtmlOverlay(source: .file(path: "/tmp/q.html", grantRoot: nil))), pane: .right)
        #expect(session.topmostHtmlOverlay != nil)
        #expect(session.htmlHidesTerminal(.left))

        session.setOverlayHidden(true, slot: nil)
        session.setOverlayHidden(true, slot: .right)

        #expect(session.topmostHtmlOverlay == nil)
        #expect(!session.htmlHidesTerminal(.left))
        #expect(!session.htmlHidesTerminal(.right))
        #expect(session.htmlCovers(nil))
    }

    @Test func anUnrealizedHiddenPaneOverlayOnARenderedPaneIsKept() {
        let session = Session(initialCwd: "/tmp")
        session.setPaneOverlay(PaneOverlay(command: "htop"), pane: .left)
        session.setOverlayHidden(true, slot: .left)

        #expect(!session.dropUnrealizedPaneOverlays())
        #expect(session.paneOverlay(.left)?.hidden == true)
    }
}
