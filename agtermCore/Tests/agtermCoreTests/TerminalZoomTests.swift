import Foundation
import Testing
@testable import agtermCore

@MainActor
struct TerminalZoomTests {
    @Test func resolveTargetPrioritizesQuickThenSessionCoversThenFocusedPane() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        #expect(TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: true) == .quick)
        #expect(TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: false) == .session(session.id, .primary))

        session.splitFocused = true
        #expect(TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: false) == .session(session.id, .split))

        session.scratchActive = true
        #expect(TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: false) == .session(session.id, .scratch))

        session.overlayActive = true
        #expect(TerminalZoomController.resolveTarget(store: store, quickTerminalVisible: false) == .session(session.id, .overlay))
    }

    @Test func targetValidityTracksQuickVisibilityAndSessionLifetime() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        #expect(TerminalZoomController.isTargetValid(.quick, in: store, quickTerminalVisible: true))
        #expect(!TerminalZoomController.isTargetValid(.quick, in: store, quickTerminalVisible: false))
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .primary), in: store, quickTerminalVisible: false))

        store.closeSession(session.id)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .primary), in: store, quickTerminalVisible: false))
    }

    @Test func splitTargetStaysValidWhenHiddenAndClearsWhenPromotedOrClosed() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        store.toggleSplit(session.id)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .split), in: store, quickTerminalVisible: false))

        store.toggleSplit(session.id)
        #expect(session.isSplit == false)
        #expect(session.hasSplit == true)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .split), in: store, quickTerminalVisible: false))

        // the primary exits: the survivor is PROMOTED into the main slot, so no right pane exists
        // anymore — a zoom on the split target must end, not keep covering the promoted main pane.
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        store.closePrimaryPane(session.id)
        #expect(session.hasSplit == false)
        #expect(session.splitSurface == nil)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .split), in: store, quickTerminalVisible: false))

        // closing a live split clears the target the ordinary way too.
        store.toggleSplit(session.id)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .split), in: store, quickTerminalVisible: false))
        store.closeSplit(session.id)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .split), in: store, quickTerminalVisible: false))
    }

    @Test func primaryTargetStaysValidWhenPrimaryExitsAndSplitIsPromoted() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        #expect(TerminalZoomController.isTargetValid(.session(session.id, .primary), in: store, quickTerminalVisible: false))

        let survivor = SpySurface()
        session.surface = SpySurface()
        session.splitSurface = survivor
        session.isSplit = true
        session.hasSplit = true
        store.closePrimaryPane(session.id)

        // the survivor MOVES into the primary slot: the primary target keeps pointing at the live
        // shell (now the survivor), and the split target dies with the vacated right pane.
        #expect(session.surface === survivor)
        #expect(session.splitSurface == nil)
        #expect(session.splitFocused == false)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .primary), in: store, quickTerminalVisible: false))
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .split), in: store, quickTerminalVisible: false))
    }

    @Test func scratchAndOverlayTargetsFollowActiveFlags() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        store.toggleScratch(session.id)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .scratch), in: store, quickTerminalVisible: false))
        store.toggleScratch(session.id)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .scratch), in: store, quickTerminalVisible: false))
        session.scratchSurface = SpySurface()
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .scratch), in: store, quickTerminalVisible: false))
        store.closeScratch(session.id)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .scratch), in: store, quickTerminalVisible: false))

        #expect(store.openOverlay(session.id, command: "top"))
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .overlay), in: store, quickTerminalVisible: false))
        #expect(store.closeOverlay(session.id))
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .overlay), in: store, quickTerminalVisible: false))
    }

    @Test func surfaceIDsRoundTripControlNames() throws {
        let sessionID = try #require(UUID(uuidString: "5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9"))
        let surfaceID = TerminalSurfaceID(sessionID: sessionID, surface: .split)

        #expect(surfaceID.rawValue == "surface:5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9:right")
        #expect(TerminalSurfaceID(rawValue: surfaceID.rawValue) == surfaceID)
        #expect(TerminalSurfaceID(rawValue: "surface:\(sessionID.uuidString):split") == surfaceID)
        #expect(TerminalSurfaceID(rawValue: "session:\(sessionID.uuidString):right") == nil)
    }

    @Test func setModeIsIdempotentAndTargeted() {
        let controller = TerminalZoomController()
        let sessionID = UUID()
        let left = TerminalZoomTarget.session(sessionID, .primary)
        let right = TerminalZoomTarget.session(sessionID, .split)

        controller.set(.on, target: left)
        #expect(controller.target == left)
        controller.set(.on, target: left)
        #expect(controller.target == left)
        controller.set(.off, target: right)
        #expect(controller.target == left)
        controller.set(.toggle, target: left)
        #expect(controller.target == nil)
        controller.set(.toggle, target: right)
        #expect(controller.target == right)
        controller.set(.off, target: nil)
        #expect(controller.target == nil)
    }
}
