import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStorePaneTests {
    // MARK: - split panes

    @Test func toggleSplitFlipsFlag() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(session.isSplit == false)
        #expect(session.hasSplit == false)
        store.toggleSplit(session.id)
        #expect(session.isSplit == true)
        #expect(session.hasSplit == true)
        #expect(session.splitFocused == true)  // opening focuses the new (right) pane
        store.toggleSplit(session.id)
        #expect(session.isSplit == false)
        // hiding the split keeps hasSplit so the sidebar/title split indicators persist, and keeps
        // splitFocused so the focused pane is the one shown maximized.
        #expect(session.hasSplit == true)
        #expect(session.splitFocused == true)
    }

    @Test func closeSplitHidesAndTearsDownSurface() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.hasSplit = true
        session.splitFocused = true
        let split = SpySurface()
        session.splitSurface = split
        session.splitCwd = "/var/log"
        session.splitRatio = 0.7
        store.closeSplit(session.id)
        #expect(session.isSplit == false)
        #expect(session.hasSplit == false)
        #expect(session.splitFocused == false)
        #expect(session.splitSurface == nil)
        #expect(session.splitCwd == nil)
        #expect(session.initialSplitCwd == nil)
        #expect(session.splitRatio == nil) // teardown clears geometry too, so a fresh re-split opens even
        #expect(split.teardownCount == 1)
    }

    @Test func clampSplitRatioBoundsValue() {
        #expect(AppStore.clampSplitRatio(0.7) == 0.7)
        #expect(AppStore.clampSplitRatio(2.0) == AppStore.splitRatioMax)   // above the cap
        #expect(AppStore.clampSplitRatio(-1.0) == AppStore.splitRatioMin)  // below the floor
        #expect(AppStore.clampSplitRatio(AppStore.splitRatioMin) == AppStore.splitRatioMin)
        #expect(AppStore.clampSplitRatio(AppStore.splitRatioMax) == AppStore.splitRatioMax)
    }

    @Test func applySplitRatioClampsSetsAndReturns() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(store.applySplitRatio(0.7, forSession: session.id) == 0.7)
        #expect(session.splitRatio == 0.7)
        // out-of-range clamps to the cap, on both the return and the stored value.
        #expect(store.applySplitRatio(2.0, forSession: session.id) == AppStore.splitRatioMax)
        #expect(session.splitRatio == AppStore.splitRatioMax)
    }

    @Test func applySplitRatioUnknownSessionReturnsNil() {
        let store = makeStore()
        #expect(store.applySplitRatio(0.5, forSession: UUID()) == nil)
    }

    @Test func closePrimaryPaneWithSplitKeepsSessionAndPromotesSurvivor() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        let split = SpySurface(); session.splitSurface = split
        session.isSplit = true
        session.hasSplit = true
        session.splitCwd = "/var/log"
        session.splitRatio = 0.3
        session.initialCommand = "ssh host" // a --command primary whose command has now exited
        store.closePrimaryPane(session.id)
        #expect(store.session(withID: session.id) != nil) // session survives
        #expect(primary.teardownCount == 1)               // the dead primary is torn down
        #expect(split.teardownCount == 0)                 // the survivor is kept
        #expect(session.surface == nil)
        #expect(session.splitSurface != nil)
        #expect(session.isSplit == false)
        #expect(session.hasSplit == false)
        #expect(session.splitFocused == true)             // the maximized survivor is shown
        #expect(session.splitRatio == nil)                // promoted to single, so a later split opens even
        #expect(session.currentCwd == "/var/log")         // the survivor's cwd is promoted
        #expect(session.initialCommand == nil)            // the command pane is gone; a restart must NOT resurrect it
    }

    @Test func closePrimaryPaneWithoutSplitClosesSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        store.closePrimaryPane(session.id)
        #expect(store.session(withID: session.id) == nil) // single session → closed
        #expect(primary.teardownCount == 1)
    }

    @Test func closeSplitPaneWithPrimaryCollapsesToPrimary() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        let split = SpySurface(); session.splitSurface = split
        session.isSplit = true
        session.hasSplit = true
        session.splitRatio = 0.4
        store.closeSplitPane(session.id)
        #expect(store.session(withID: session.id) != nil) // session survives
        #expect(split.teardownCount == 1)                 // the split is torn down
        #expect(primary.teardownCount == 0)               // the primary is kept
        #expect(session.splitSurface == nil)
        #expect(session.isSplit == false)
        #expect(session.splitRatio == nil)                // delegates to closeSplit, which clears the ratio
    }

    @Test func closeSplitPaneWithoutPrimaryClosesSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        // the primary already exited (surface nil); only the split survives, so this is the last pane.
        let split = SpySurface(); session.splitSurface = split
        store.closeSplitPane(session.id)
        #expect(store.session(withID: session.id) == nil) // last pane → closed
        #expect(split.teardownCount == 1)
    }

    @Test func closeSplitClearsStuckSearchOnSurvivingSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let split = SpySurface()
        session.splitSurface = split
        session.isSplit = true
        session.hasSplit = true
        // search opened on the split pane, pinned as the owner
        session.searchActive = true
        session.searchNeedle = "needle"
        session.searchTotal = 3
        session.searchSelected = 1
        session.searchSurface = split
        store.closeSplit(session.id)
        #expect(session.searchActive == false)
        #expect(session.searchNeedle == "")
        #expect(session.searchTotal == nil)
        #expect(session.searchSelected == nil)
        #expect(session.searchSurface == nil)
    }

    @Test func closePrimaryPaneClearsStuckSearchOnPromotedSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        let split = SpySurface(); session.splitSurface = split
        session.isSplit = true
        session.hasSplit = true
        // search opened on the primary, which is torn down + promoted while the session survives
        session.searchActive = true
        session.searchNeedle = "needle"
        session.searchTotal = 2
        session.searchSelected = 1
        session.searchSurface = primary
        store.closePrimaryPane(session.id)
        #expect(store.session(withID: session.id) != nil) // session survives
        #expect(session.searchActive == false)
        #expect(session.searchNeedle == "")
        #expect(session.searchTotal == nil)
        #expect(session.searchSelected == nil)
        #expect(session.searchSurface == nil)
    }

    @Test func closeSplitPaneClearsStuckSearchWhenCollapsingToPrimary() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        let split = SpySurface(); session.splitSurface = split
        session.isSplit = true
        session.hasSplit = true
        session.searchActive = true
        session.searchTotal = 5
        session.searchSurface = split
        store.closeSplitPane(session.id) // primary alive → collapses via closeSplit, which clears search
        #expect(store.session(withID: session.id) != nil)
        #expect(session.searchActive == false)
        #expect(session.searchTotal == nil)
        #expect(session.searchSurface == nil)
    }

    // MARK: - overlay

    @Test func openOverlaySetsCommandAndFlag() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(store.openOverlay(session.id, command: "revdiff", cwd: "/b") == true)
        #expect(session.overlayActive == true)
        #expect(session.overlayCommand == "revdiff")
        #expect(session.overlayCwd == "/b")
        // no size given → the default full-pane overlay, not a floating one.
        #expect(session.overlaySizePercent == nil)
        // a second open while one is active is a no-op.
        #expect(store.openOverlay(session.id, command: "other") == false)
        #expect(session.overlayCommand == "revdiff")
    }

    @Test func openOverlayCarriesBackgroundColorAndCloseClears() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(store.openOverlay(session.id, command: "revdiff", backgroundColor: "#2a1a3a") == true)
        #expect(session.overlayBackgroundColor == "#2a1a3a")
        // close clears the overlay's color back to nil, like the other ephemeral overlay fields.
        store.closeOverlay(session.id)
        #expect(session.overlayBackgroundColor == nil)
        // omitting the color leaves it nil (default theme background, unchanged behavior).
        #expect(store.openOverlay(session.id, command: "revdiff") == true)
        #expect(session.overlayBackgroundColor == nil)
    }

    @Test func overlayExitCodeRecordedAndSurvivesClose() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openOverlay(session.id, command: "revdiff")
        #expect(session.overlayExitCode == nil)
        store.recordOverlayExit(session.id, code: 10)
        #expect(store.closeOverlay(session.id) == true)
        // the exit code survives close (read by session.overlay.result after the overlay vanishes)...
        #expect(session.overlayExitCode == 10)
        // ...and is reset when a new overlay opens.
        #expect(store.openOverlay(session.id, command: "revdiff") == true)
        #expect(session.overlayExitCode == nil)
    }

    @Test func recordOverlayExitUnknownSessionIsNoop() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        // a bogus id must be a no-op, not a crash, and must not touch any existing session.
        store.recordOverlayExit(UUID(), code: 5)
        #expect(session.overlayExitCode == nil)
    }

    @Test func openOverlayFloatingClampsSizePercent() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(store.openOverlay(session.id, command: "htop", sizePercent: 70) == true)
        #expect(session.overlaySizePercent == 70)
        // close clears the floating size back to nil.
        store.closeOverlay(session.id)
        #expect(session.overlaySizePercent == nil)
        // out-of-range values clamp to 1...100, including negatives; the exact bounds pass through.
        store.openOverlay(session.id, command: "htop", sizePercent: 250)
        #expect(session.overlaySizePercent == 100)
        store.closeOverlay(session.id)
        store.openOverlay(session.id, command: "htop", sizePercent: 0)
        #expect(session.overlaySizePercent == 1)
        store.closeOverlay(session.id)
        store.openOverlay(session.id, command: "htop", sizePercent: -5)
        #expect(session.overlaySizePercent == 1)
        store.closeOverlay(session.id)
        store.openOverlay(session.id, command: "htop", sizePercent: 100)
        #expect(session.overlaySizePercent == 100)
        store.closeOverlay(session.id)
        store.openOverlay(session.id, command: "htop", sizePercent: 1)
        #expect(session.overlaySizePercent == 1)
    }

    @Test func closeOverlayTearsDownAndClears() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openOverlay(session.id, command: "revdiff")
        let overlay = SpySurface()
        session.overlaySurface = overlay
        #expect(store.closeOverlay(session.id) == true)
        #expect(session.overlayActive == false)
        #expect(session.overlaySurface == nil)
        #expect(session.overlayCommand == nil)
        #expect(overlay.teardownCount == 1)
        // closing again is a no-op.
        #expect(store.closeOverlay(session.id) == false)
    }

    @Test func closeSessionTearsDownOverlaySurface() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openOverlay(session.id, command: "revdiff")
        let overlay = SpySurface()
        session.overlaySurface = overlay
        store.closeSession(session.id)
        #expect(overlay.teardownCount == 1)
    }

    // MARK: - scratch

    @Test func toggleScratchFlipsFlagAndKeepsSurfaceAlive() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(session.scratchActive == false)
        store.toggleScratch(session.id)
        #expect(session.scratchActive == true)
        // the detail pane lazily creates the surface on show; simulate that.
        let scratch = SpySurface()
        session.scratchSurface = scratch
        // hiding keeps the shell alive (slot retained), so a re-show reuses it.
        store.toggleScratch(session.id)
        #expect(session.scratchActive == false)
        #expect(session.scratchSurface === scratch)
        #expect(scratch.teardownCount == 0)
        store.toggleScratch(session.id)
        #expect(session.scratchActive == true)
        #expect(session.scratchSurface === scratch)
    }

    @Test func closeScratchTearsDownAndClears() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.scratchActive = true
        let scratch = SpySurface()
        session.scratchSurface = scratch
        #expect(store.closeScratch(session.id) == true)
        #expect(session.scratchActive == false)
        #expect(session.scratchSurface == nil)
        #expect(scratch.teardownCount == 1)
        // closing again (no surface) is a no-op.
        #expect(store.closeScratch(session.id) == false)
    }

    @Test func closeScratchClearsStuckSearchWhenScratchOwnsIt() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.scratchActive = true
        let scratch = SpySurface()
        session.scratchSurface = scratch
        // search opened on the scratch, pinned as the owner — its teardown must reset search.
        session.searchActive = true
        session.searchNeedle = "needle"
        session.searchTotal = 4
        session.searchSelected = 2
        session.searchSurface = scratch
        #expect(store.closeScratch(session.id) == true)
        #expect(session.searchActive == false)
        #expect(session.searchNeedle == "")
        #expect(session.searchTotal == nil)
        #expect(session.searchSelected == nil)
        #expect(session.searchSurface == nil)
    }

    @Test func closeScratchLeavesSearchOwnedByMainPane() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        session.scratchActive = true
        let scratch = SpySurface()
        session.scratchSurface = scratch
        // search is owned by the MAIN pane, not the scratch covering the session — tearing the scratch
        // down must not nuke a valid main-pane search.
        session.searchActive = true
        session.searchNeedle = "needle"
        session.searchSurface = primary
        #expect(store.closeScratch(session.id) == true)
        #expect(session.searchActive == true)
        #expect(session.searchNeedle == "needle")
        #expect(session.searchSurface === primary)
    }

    @Test func toggleScratchUnknownSessionIsNoop() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.toggleScratch(UUID()) // unknown id
        #expect(session.scratchActive == false) // existing session untouched
    }

    @Test func closeScratchUnknownSessionReturnsFalse() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/a")
        #expect(store.closeScratch(UUID()) == false) // unknown id, no surface
    }

    @Test func closeSessionTearsDownScratchSurface() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let scratch = SpySurface()
        session.scratchSurface = scratch
        store.closeSession(session.id)
        #expect(scratch.teardownCount == 1)
    }

    @Test func removeWorkspaceTearsDownScratchSurface() {
        let store = makeStore()
        let keep = store.addWorkspace(name: "keep")
        _ = store.addSession(toWorkspace: keep.id, cwd: "/k")
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let scratch = SpySurface()
        session.scratchSurface = scratch
        store.removeWorkspace(ws.id)
        #expect(scratch.teardownCount == 1)
    }

    // MARK: - status-pane reconcile on pane teardown

    @Test func closeSplitClearsRightTaggedStatus() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.splitSurface = SpySurface(); session.isSplit = true; session.hasSplit = true
        // a block set by the split (`--pane right`); once the split shell exits, the surviving main pane can
        // never keystroke-clear a `.right` tag, so teardown must clear it.
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)
        store.closeSplit(session.id)
        #expect(session.agentIndicator.status == .idle)
        #expect(session.agentIndicator.statusPane == nil)
    }

    @Test func closeSplitLeavesMainTaggedStatus() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.splitSurface = SpySurface(); session.isSplit = true; session.hasSplit = true
        // a `.left`/main block is owned by the surviving main pane — tearing the split down must NOT clear it.
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)
        store.closeSplit(session.id)
        #expect(session.agentIndicator.status == .blocked)
        #expect(session.agentIndicator.statusPane == .left)
    }

    @Test func closePrimaryPaneClearsLeftAndNilTaggedStatus() {
        for pane: StatusPane? in [.left, nil] {
            let store = makeStore()
            let ws = store.addWorkspace(name: "work")
            let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
            session.surface = SpySurface(); session.splitSurface = SpySurface()
            session.isSplit = true; session.hasSplit = true
            // the primary owned a `.left`/nil-tagged block and is promoted away, so the promoted (right-wired)
            // survivor could never keystroke-clear it — teardown must.
            store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: pane), forSession: session.id)
            store.closePrimaryPane(session.id)
            #expect(session.agentIndicator.status == .idle)
        }
    }

    @Test func closePrimaryPaneLeavesRightTaggedStatus() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface(); session.splitSurface = SpySurface()
        session.isSplit = true; session.hasSplit = true
        // the `.right` block is owned by the split, which becomes the promoted survivor — still clearable, keep it.
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)
        store.closePrimaryPane(session.id)
        #expect(session.agentIndicator.status == .blocked)
        #expect(session.agentIndicator.statusPane == .right)
    }

    @Test func closeScratchClearsScratchTaggedStatus() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.scratchActive = true; session.scratchSurface = SpySurface()
        // a scratch-tagged block loses its owning surface on the scratch shell's exit.
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .scratch), forSession: session.id)
        #expect(store.closeScratch(session.id) == true)
        #expect(session.agentIndicator.status == .idle)
        #expect(session.agentIndicator.statusPane == nil)
    }

    @Test func closeScratchLeavesMainTaggedStatus() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()
        session.scratchActive = true; session.scratchSurface = SpySurface()
        // a main-pane block survives the scratch teardown (the main pane is still there to clear it).
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)
        #expect(store.closeScratch(session.id) == true)
        #expect(session.agentIndicator.status == .blocked)
    }
}
