import Foundation
import Testing
@testable import agtermCore

@MainActor
struct TerminalZoomTests {
    @Test func controlAliasesPreserveCanonicalSurfaceRoles() {
        for alias in ["left", "top", "primary"] {
            #expect(TerminalZoomSurface(controlName: alias) == .primary)
        }
        for alias in ["right", "bottom", "split"] {
            #expect(TerminalZoomSurface(controlName: alias) == .split)
        }
    }

    @Test func resolveTargetPrioritizesSessionCoversThenFocusedPane() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        #expect(TerminalZoomController.resolveTarget(store: store) == .session(session.id, .primary))

        // `splitFocused` alone describes no pane: with neither a shown split nor a split surface the focused
        // pane is still the primary, matching `rendersPane`/`focusedOverlayPane` and `.split`'s isAvailable.
        session.splitFocused = true
        #expect(TerminalZoomController.resolveTarget(store: store) == .session(session.id, .primary))

        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        #expect(TerminalZoomController.resolveTarget(store: store) == .session(session.id, .split))

        session.scratchActive = true
        #expect(TerminalZoomController.resolveTarget(store: store) == .session(session.id, .scratch))

        session.overlayActive = true
        #expect(TerminalZoomController.resolveTarget(store: store) == .session(session.id, .overlay))
    }

    /// The quick terminal is one detached panel per app, so no WINDOW's zoom can hold it: `.quick` is neither
    /// resolved here nor valid here, and `QuickTerminalController.isZoomed` owns it instead.
    @Test func windowZoomNeverTakesTheQuickTerminal() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        #expect(TerminalZoomController.resolveTarget(store: store) == .session(session.id, .primary))
        #expect(!TerminalZoomController.isTargetValid(.quick, in: store))
    }

    @Test func targetValidityTracksSessionLifetime() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        #expect(TerminalZoomController.isTargetValid(.session(session.id, .primary), in: store))

        store.closeSession(session.id)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .primary), in: store))
    }

    @Test func splitTargetStaysValidWhenHiddenAndClearsWhenPromotedOrClosed() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        store.toggleSplit(session.id)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .split), in: store))

        store.toggleSplit(session.id)
        #expect(session.isSplit == false)
        #expect(session.hasSplit == true)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .split), in: store))

        // the primary exiting PROMOTES the survivor into the main slot, leaving no right pane to zoom.
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        store.closePrimaryPane(session.id)
        #expect(session.hasSplit == false)
        #expect(session.splitSurface == nil)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .split), in: store))

        store.toggleSplit(session.id)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .split), in: store))
        store.closeSplit(session.id)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .split), in: store))
    }

    @Test func primaryTargetStaysValidWhenPrimaryExitsAndSplitIsPromoted() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        #expect(TerminalZoomController.isTargetValid(.session(session.id, .primary), in: store))

        let survivor = SpySurface()
        session.surface = SpySurface()
        session.splitSurface = survivor
        session.isSplit = true
        session.hasSplit = true
        store.closePrimaryPane(session.id)

        #expect(session.surface === survivor)
        #expect(session.splitSurface == nil)
        #expect(session.splitFocused == false)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .primary), in: store))
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .split), in: store))
    }

    @Test func scratchAndOverlayTargetsFollowActiveFlags() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        store.toggleScratch(session.id)
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .scratch), in: store))
        store.toggleScratch(session.id)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .scratch), in: store))
        session.scratchSurface = SpySurface()
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .scratch), in: store))
        store.closeScratch(session.id)
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .scratch), in: store))

        #expect(store.openOverlay(session.id, command: "top"))
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .overlay), in: store))
        #expect(store.closeOverlay(session.id))
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .overlay), in: store))
    }

    @Test func paneOverlayTargetsFollowTheirSlotAndFocusedPane() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()
        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        session.splitFocused = false

        #expect(store.openPaneOverlay(session.id, pane: .left, command: "top") == nil)
        #expect(TerminalZoomController.resolveTarget(store: store) == .session(session.id, .overlayLeft))
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .overlayLeft), in: store))
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .overlayRight), in: store))

        session.splitFocused = true
        #expect(TerminalZoomController.resolveTarget(store: store) == .session(session.id, .split))

        #expect(store.openPaneOverlay(session.id, pane: .right, command: "top") == nil)
        #expect(TerminalZoomController.resolveTarget(store: store) == .session(session.id, .overlayRight))

        #expect(store.closePaneOverlay(session.id, pane: .right))
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .overlayRight), in: store))
        #expect(TerminalZoomController.resolveTarget(store: store) == .session(session.id, .split))
    }

    @Test func paneOverlayTakesItsPanesVisibilityAndSessionCoversHideBoth() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()
        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "top") == nil)
        // realized, so hiding its pane below only unmounts it — an unrealized slot is retired instead.
        session.rightOverlaySurface = SpySurface()

        #expect(TerminalZoomSurface.overlayRight.isVisible(in: session))
        #expect(!TerminalZoomSurface.split.isVisible(in: session))
        #expect(TerminalZoomSurface.primary.isVisible(in: session))

        // the split hidden with the LEFT pane focused stops laying the right pane out at all.
        session.splitFocused = false
        store.toggleSplit(session.id)
        #expect(!TerminalZoomSurface.overlayRight.isVisible(in: session))
        #expect(TerminalZoomSurface.overlayRight.isAvailable(in: session))

        store.toggleSplit(session.id)
        session.scratchActive = true
        #expect(!TerminalZoomSurface.overlayRight.isVisible(in: session))
        session.scratchActive = false
        session.overlayActive = true
        #expect(!TerminalZoomSurface.overlayRight.isVisible(in: session))
    }

    @Test func exactlyOneSurfaceIsActiveAndItIsTheOneTheDeckShowsAcrossEverySessionShape() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let names = ["isSplit", "hasSplit", "focusRight", "splitSurface", "scratch", "sessionOverlay",
                     "leftOverlay", "rightOverlay", "hud"]

        for combination in 0..<(1 << names.count) {
            let on: (Int) -> Bool = { combination & (1 << $0) != 0 }
            session.isSplit = on(0)
            session.hasSplit = on(1)
            session.splitFocused = on(2)
            session.splitSurface = on(3) ? SpySurface() : nil
            session.scratchActive = on(4)
            session.overlayActive = on(5)
            session.leftOverlay = on(6) ? PaneOverlay(command: "top") : nil
            session.rightOverlay = on(7) ? PaneOverlay(command: "top") : nil
            session.hudSpec = on(8) ? HudSpec(message: "gathering options") : nil

            // derived from the deck's OWN predicates (`focusedPane`, the pane slots), never from `isActive`,
            // so a wrong-but-unique active case cannot pass by cardinality alone.
            let focused = session.focusedPane
            let expected: TerminalZoomSurface
            if session.programOverlayActive {
                expected = .overlay
            } else if session.scratchActive {
                expected = .scratch
            } else {
                expected = session.paneOverlay(focused) != nil ? focused.zoomSurface : focused.paneZoomSurface
            }

            let active = TerminalZoomSurface.allCases.filter { $0.isActive(in: session) }
            let shape = names.indices.filter { on($0) }.map { names[$0] }.joined(separator: "+")
            #expect(active == [expected], "[\(shape.isEmpty ? "bare" : shape)] resolved to \(active)")
            #expect(TerminalZoomController.resolveTarget(store: store)
                == .session(session.id, expected), "[\(shape.isEmpty ? "bare" : shape)] wrong zoom target")
            // a pane overlay is only ever the active target while its own pane is the one on screen.
            if expected == .overlayLeft || expected == .overlayRight {
                #expect(session.focusedOverlayPane == focused && session.rendersPane(focused),
                        "[\(shape)] pane overlay active over a pane the deck does not lay out")
            }
        }
    }

    @Test func aHudLeavesThePaneActiveAndIsNotAddressableAsTheOverlaySurface() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        #expect(store.openHud(session.id, command: "/bin/sh /hud.sh", spec: HudSpec(message: "gathering options"),
                              file: "/tmp/agterm-hud.txt", size: HudPanelSize(widthPercent: 30, heightPercent: 9)))

        #expect(TerminalZoomSurface.allCases.filter { $0.isActive(in: session) } == [.primary])
        #expect(TerminalZoomSurface.primary.isVisible(in: session))
        #expect(TerminalZoomController.resolveTarget(store: store)
            == .session(session.id, .primary))

        #expect(!TerminalZoomSurface.overlay.isAvailable(in: session))
        #expect(!TerminalZoomSurface.overlay.isVisible(in: session))
        #expect(!TerminalZoomController.isTargetValid(.session(session.id, .overlay), in: store))

        // the refusal is about the HUD, not the slot: a program taking the same slot is addressable again.
        #expect(store.openOverlay(session.id, command: "top"))
        #expect(TerminalZoomSurface.overlay.isAvailable(in: session))
        #expect(TerminalZoomSurface.allCases.filter { $0.isActive(in: session) } == [.overlay])
        #expect(TerminalZoomController.isTargetValid(.session(session.id, .overlay), in: store))
    }

    @Test func aHudLeavesTheScratchAndPaneOverlayTargetsIntact() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()

        #expect(store.openHud(session.id, command: "/bin/sh /hud.sh", spec: HudSpec(message: "working"),
                              file: "/tmp/agterm-hud.txt", size: HudPanelSize(widthPercent: 30, heightPercent: 9)))

        store.toggleScratch(session.id)
        #expect(TerminalZoomSurface.allCases.filter { $0.isActive(in: session) } == [.scratch])
        #expect(TerminalZoomSurface.scratch.isVisible(in: session))
        #expect(TerminalZoomController.resolveTarget(store: store)
            == .session(session.id, .scratch))
        store.toggleScratch(session.id)

        #expect(store.openPaneOverlay(session.id, pane: .left, command: "top") == nil)
        #expect(TerminalZoomSurface.allCases.filter { $0.isActive(in: session) } == [.overlayLeft])
        #expect(TerminalZoomSurface.overlayLeft.isVisible(in: session))
        #expect(TerminalZoomController.resolveTarget(store: store)
            == .session(session.id, .overlayLeft))
    }

    @Test func closingAHudRestoresTheOverlaySurfaceAddressForTheNextProgram() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        #expect(store.openHud(session.id, command: "/bin/sh /hud.sh", spec: HudSpec(message: "working"),
                              file: "/tmp/agterm-hud.txt", size: HudPanelSize(widthPercent: 30, heightPercent: 9)))
        // ⌘W's cover ladder takes the HUD through the ordinary overlay teardown.
        #expect(store.closeOverlay(session.id))
        #expect(session.hudSpec == nil)
        #expect(!TerminalZoomSurface.overlay.isAvailable(in: session))

        #expect(store.openOverlay(session.id, command: "top", sizePercent: 40))
        #expect(TerminalZoomSurface.overlay.isAvailable(in: session))
        #expect(TerminalZoomSurface.allCases.filter { $0.isActive(in: session) } == [.overlay])
    }

    @Test func surfaceIDsRoundTripControlNames() throws {
        let sessionID = try #require(UUID(uuidString: "5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9"))
        let surfaceID = TerminalSurfaceID(sessionID: sessionID, surface: .split)

        #expect(surfaceID.rawValue == "surface:5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9:right")
        #expect(TerminalSurfaceID(rawValue: surfaceID.rawValue) == surfaceID)
        #expect(TerminalSurfaceID(rawValue: "surface:\(sessionID.uuidString):split") == surfaceID)
        #expect(TerminalSurfaceID(rawValue: "session:\(sessionID.uuidString):right") == nil)
    }

    @Test func surfaceIDsRoundTripPaneOverlayNames() throws {
        let sessionID = try #require(UUID(uuidString: "5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9"))
        let left = TerminalSurfaceID(sessionID: sessionID, surface: .overlayLeft)
        let right = TerminalSurfaceID(sessionID: sessionID, surface: .overlayRight)

        #expect(left.rawValue == "surface:5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9:overlay-left")
        #expect(right.rawValue == "surface:5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9:overlay-right")
        #expect(TerminalSurfaceID(rawValue: left.rawValue) == left)
        #expect(TerminalSurfaceID(rawValue: right.rawValue) == right)
        #expect(TerminalSurfaceID(rawValue: "surface:\(sessionID.uuidString):overlay-middle") == nil)
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
