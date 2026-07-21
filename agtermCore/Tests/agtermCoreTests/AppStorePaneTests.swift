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

    @Test func toggleSplitReshowPreservesFocusedPane() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.toggleSplit(session.id)           // open a NEW split -> focuses the new (right) pane
        #expect(session.splitFocused == true)
        session.splitFocused = false            // focus the left pane
        store.toggleSplit(session.id)           // hide (zoom): left pane stays the maximized one
        #expect(session.isSplit == false)
        #expect(session.splitFocused == false)
        store.toggleSplit(session.id)           // re-show (un-zoom): must keep the left pane focused
        #expect(session.isSplit == true)
        #expect(session.splitFocused == false)  // regression guard: no jerk back to the right pane
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
        session.splitFocused = true
        session.splitCwd = "/var/log"
        session.splitTitle = "remote-host"
        session.splitForegroundCommand = ["ssh", "host"]
        session.splitRatio = 0.3
        session.initialCommand = "ssh host" // a --command primary whose command has now exited
        store.closePrimaryPane(session.id)
        #expect(store.session(withID: session.id) != nil) // session survives
        #expect(primary.teardownCount == 1)               // the dead primary is torn down
        #expect(split.teardownCount == 0)                 // the survivor is kept
        #expect(split.promotedCount == 1)                 // the survivor is promoted to the primary role
        // the survivor MOVES into the primary slot — the session is now a plain single pane
        #expect(session.surface === split)
        #expect(session.splitSurface == nil)
        #expect(session.isSplit == false)
        #expect(session.hasSplit == false)
        #expect(session.splitFocused == false)            // no split anymore; the survivor is the main pane
        #expect(session.splitRatio == nil)                // promoted to single, so a later split opens even
        #expect(session.initialCommand == nil)            // the command pane is gone; a restart must NOT resurrect it
        // the survivor's metadata migrates up to the session (main) fields, and the split fields clear
        #expect(session.currentCwd == "/var/log")
        #expect(session.oscTitle == "remote-host")
        #expect(session.foregroundCommand == ["ssh", "host"])
        #expect(session.splitCwd == nil)
        #expect(session.splitTitle == nil)
        #expect(session.splitForegroundCommand == nil)
        // the session-scoped control arms (session.copy/paste/selectall, font.*) must still reach the live
        // shell: the survivor now sits IN `surface`, so `addressableSurface` resolves it through the primary
        // slot (the `?? splitSurface` fallback is for a shown split pre-collapse, not for promotion).
        #expect(session.addressableSurface === split)
    }

    @Test func addressableSurfaceIsTheMainPaneUntilThePrimaryExits() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        #expect(session.addressableSurface === primary)   // plain session

        let split = SpySurface(); session.splitSurface = split
        session.isSplit = true
        session.hasSplit = true
        #expect(session.addressableSurface === primary)   // split shown, main pane still addressed

        session.splitFocused = true
        #expect(session.addressableSurface === primary)   // NOT focus-aware: selectall + copy stay paired
    }

    @Test func addressableSurfaceIsNilWhenNoPaneIsRealized() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(session.addressableSurface == nil)        // never-shown session still errors "session not realized"
    }

    @Test func closePrimaryPaneUsesRestoredSplitCwdAndClearsTitleWhenSplitHasNoOSCYet() {
        // a RESTORED split whose shell hasn't emitted OSC yet: `initialSplitCwd` is seeded but the live
        // `splitCwd`/`splitTitle` are still nil. Exiting the primary must promote the survivor showing ITS
        // restore-seed cwd and NO title — not the exited primary's cwd/title lingering until the survivor's
        // next report.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        session.isSplit = true
        session.hasSplit = true
        session.currentCwd = "/primary"             // the exited primary's live cwd on the main field
        session.oscTitle = "primary-title"          // the exited primary's title
        session.initialSplitCwd = "/restored-split" // the survivor's restore-seed; no live splitCwd/splitTitle yet
        store.closePrimaryPane(session.id)
        #expect(session.currentCwd == "/restored-split") // the survivor's restore-seed cwd, not the primary's
        #expect(session.oscTitle == nil)                 // the primary's title must NOT linger on the survivor
        #expect(session.initialSplitCwd == nil)          // split fields cleared after promotion
    }

    @Test func closePrimaryPaneKeepsSearchOwnedBySurvivor() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        let split = SpySurface(); session.splitSurface = split
        session.isSplit = true
        session.hasSplit = true
        session.searchActive = true       // the SURVIVING (split) pane owns an open search bar
        session.searchSurface = split
        store.closePrimaryPane(session.id)
        #expect(session.searchActive)              // the survivor's search stays valid across promotion
        #expect(session.searchSurface === split)
    }

    @Test func closePrimaryPaneClearsSearchOwnedByExitingPrimary() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        let split = SpySurface(); session.splitSurface = split
        session.isSplit = true
        session.hasSplit = true
        session.searchActive = true       // the EXITING primary owns the bar → reset it (no stuck bar)
        session.searchSurface = primary
        store.closePrimaryPane(session.id)
        #expect(session.searchActive == false)
        #expect(session.searchSurface == nil)
    }

    // Regression: after the primary exits and the split is promoted into the main slot, the promoted
    // surface still carries the split pane's `onExit` (→ `closeSplitPane`). Since it is now the session's
    // sole pane, that exit must CLOSE the session — not collapse a split that no longer exists, which left
    // a zombie session with a torn-down surface before `closeSplitPane`'s guard was tightened.
    @Test func closeSplitPaneAfterPromotionClosesSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        let split = SpySurface(); session.splitSurface = split
        session.isSplit = true
        session.hasSplit = true
        session.splitFocused = true
        store.closePrimaryPane(session.id)                 // primary exits → split promoted into the main slot
        #expect(session.surface === split)                 // precondition: the survivor is now the sole pane
        #expect(session.splitSurface == nil)
        store.closeSplitPane(session.id)                   // the survivor's stale split `onExit` fires
        #expect(store.session(withID: session.id) == nil)  // last pane → session closed, no zombie
        #expect(split.teardownCount == 1)                  // the promoted surface is torn down exactly once
    }

    // Regression (the fix `handlePaneExit` routes to): promote a survivor into the main slot, split AGAIN,
    // then exit the (promoted) MAIN pane. Because the survivor's role is now primary, its exit runs
    // `closePrimaryPane` — which must collapse onto the FRESH right pane (promote it, tear down the exited
    // main), not the stale `closeSplitPane` that would tear down the new split and strand the dead main.
    @Test func closePrimaryPaneAfterPromotionAndResplitCollapsesToNewSplit() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        let firstSplit = SpySurface(); session.splitSurface = firstSplit
        session.isSplit = true
        session.hasSplit = true
        session.splitFocused = true
        store.closePrimaryPane(session.id)                 // primary exits → firstSplit promoted into main
        #expect(session.surface === firstSplit)            // precondition: firstSplit is now the sole pane
        #expect(session.splitSurface == nil)
        // re-split the promoted single pane: a fresh right pane mounts beside the survivor.
        let secondSplit = SpySurface(); session.splitSurface = secondSplit
        session.isSplit = true
        session.hasSplit = true
        session.splitFocused = true
        store.closePrimaryPane(session.id)                 // the promoted MAIN pane's own exit routes here
        #expect(store.session(withID: session.id) != nil)  // session survives — the split is promoted, not lost
        #expect(session.surface === secondSplit)           // the FRESH right pane took over the main slot
        #expect(session.splitSurface == nil)
        #expect(secondSplit.promotedCount == 1)            // it was promoted, not torn down
        #expect(secondSplit.teardownCount == 0)
        #expect(firstSplit.teardownCount == 1)             // the exited (promoted) main pane is torn down
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

    @Test func closePrimaryPaneMigratesBothRestoreOverrideHalvesUp() {
        // the survivor's restore-command override follows it into the main slot: the persisted pin (so the
        // next launch restores the promoted pane's command, not the dead primary's) AND any payload still
        // armed for this launch (so a surface built after promotion still runs it).
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        session.isSplit = true
        session.hasSplit = true
        session.restoreCommand = "claude --resume primary"
        session.pendingRestoreCommand = "claude --resume primary"
        session.splitRestoreCommand = "tail -f /var/log/x"
        session.pendingSplitRestoreCommand = "tail -f /var/log/x"

        store.closePrimaryPane(session.id)

        #expect(session.restoreCommand == "tail -f /var/log/x")        // the survivor's pin replaces the dead primary's
        #expect(session.pendingRestoreCommand == "tail -f /var/log/x")
        #expect(session.splitRestoreCommand == nil)                    // nothing still describes the gone pane
        #expect(session.pendingSplitRestoreCommand == nil)
    }

    @Test func closePrimaryPaneMigratesAnAbsentSplitOverrideAsAClear() {
        // migration replaces OUTRIGHT (like foregroundCommand): a survivor with no override must not
        // inherit the exited primary's pin, or the next launch would run a command in the wrong pane's shell.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        session.isSplit = true
        session.hasSplit = true
        session.restoreCommand = "claude --resume primary"
        session.pendingRestoreCommand = "claude --resume primary"

        store.closePrimaryPane(session.id)

        #expect(session.restoreCommand == nil)
        #expect(session.pendingRestoreCommand == nil)
    }

    @Test func closeSplitClearsBothRestoreOverrideHalves() {
        // the right pane is gone, so its override describes nothing — and a payload left armed would fire
        // on the next manual ⌘D instead of the launch it was seeded for.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        session.isSplit = true
        session.hasSplit = true
        session.restoreCommand = "claude --resume main"
        session.pendingRestoreCommand = "claude --resume main"
        session.splitRestoreCommand = "tail -f /var/log/x"
        session.pendingSplitRestoreCommand = "tail -f /var/log/x"

        store.closeSplit(session.id)

        #expect(session.splitRestoreCommand == nil)
        #expect(session.pendingSplitRestoreCommand == nil)
        // the surviving main pane keeps both of its halves
        #expect(session.restoreCommand == "claude --resume main")
        #expect(session.pendingRestoreCommand == "claude --resume main")
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

    @Test func resizeOverlaySwitchesFullAndFloatingAndClamps() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        // no overlay open → no-op, leaves size untouched.
        #expect(store.resizeOverlay(session.id, sizePercent: 50) == false)
        #expect(session.overlaySizePercent == nil)
        // open full, then resize it to a floating percent (nil → 60).
        store.openOverlay(session.id, command: "htop")
        #expect(session.overlaySizePercent == nil)
        #expect(store.resizeOverlay(session.id, sizePercent: 60) == true)
        #expect(session.overlaySizePercent == 60)
        #expect(session.floatingOverlayActive)
        // resize back to full (nil).
        #expect(store.resizeOverlay(session.id, sizePercent: nil) == true)
        #expect(session.overlaySizePercent == nil)
        #expect(session.fullOverlayActive)
        // out-of-range percents clamp to 1...100.
        store.resizeOverlay(session.id, sizePercent: 250)
        #expect(session.overlaySizePercent == 100)
        store.resizeOverlay(session.id, sizePercent: 0)
        #expect(session.overlaySizePercent == 1)
        // the overlay program keeps running across every resize (no re-spawn).
        #expect(session.overlayActive)
    }

    @Test func controlTreeReportsCommandWait() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        // a held --command session reports the flag so a script can record and restore it.
        store.addSession(toWorkspace: ws.id, cwd: "/a", command: "make test", wait: true)
        var node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.commandWait == true)
        // a non-holding command session omits it (nil).
        let plain = store.addSession(toWorkspace: ws.id, cwd: "/b", command: "make test")!
        node = try #require(store.controlTree().workspaces[0].sessions.first { $0.id == plain.id.uuidString })
        #expect(node.commandWait == nil)
        // a plain session (no command) omits it even when the flag IS set — gated on initialCommand, so a
        // mutant that drops the `initialCommand != nil` term would report true here and fail.
        let shell = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        shell.commandWait = true
        node = try #require(store.controlTree().workspaces[0].sessions.first { $0.id == shell.id.uuidString })
        #expect(node.commandWait == nil)
    }

    @Test func controlTreeReportsOverlaySizePercent() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        // no overlay: the field is omitted (nil).
        var node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.overlay == false)
        #expect(node.overlaySizePercent == nil)
        // floating overlay: the percent rides the node so a script can record it before zooming.
        store.openOverlay(session.id, command: "htop", sizePercent: 95)
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.overlay == true)
        #expect(node.overlaySizePercent == 95)
        // full-pane overlay: open but no size (nil = full).
        store.resizeOverlay(session.id, sizePercent: nil)
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.overlay == true)
        #expect(node.overlaySizePercent == nil)
    }

    @Test func controlTreeReportsSplitRatio() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        // no split: the field is omitted (nil).
        var node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.split == false)
        #expect(node.splitRatio == nil)
        // a split with the divider still at the default (never moved): still nil.
        store.toggleSplit(session.id)
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.split == true)
        #expect(node.splitRatio == nil)
        // moving the divider surfaces the ratio so a script can record and restore it.
        _ = store.applySplitRatio(0.3, forSession: session.id)
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.splitRatio == 0.3)
        // a hidden split keeps its ratio readable (gated on hasSplit, not isSplit).
        store.toggleSplit(session.id)
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.split == false)
        #expect(node.splitRatio == 0.3)
    }

    @Test func controlTreeReportsRestoreCommand() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.toggleSplit(session.id)
        // no override: both fields are omitted (nil).
        var node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.restoreCommand == nil)
        #expect(node.splitRestoreCommand == nil)
        // both panes pinned, the split one to nothing — "" must read back as an empty string, not as nil.
        store.setRestoreCommand("claude --resume abc", pane: .left, forSession: session.id)
        store.setRestoreCommand("", pane: .right, forSession: session.id)
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.restoreCommand == "claude --resume abc")
        #expect(node.splitRestoreCommand == "")
        // the override is STICKY: consuming this launch's pending payloads (what the surface factories do
        // at bootstrap) must not change the read-back — a builder wired to the pending slots reports nil here.
        session.pendingRestoreCommand = session.restoreCommand
        session.pendingSplitRestoreCommand = session.splitRestoreCommand
        #expect(session.takePendingRestoreOverride(pane: .left) == "claude --resume abc")
        #expect(session.takePendingRestoreOverride(pane: .right) == "")
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.restoreCommand == "claude --resume abc")
        #expect(node.splitRestoreCommand == "")
        // unpinning drops the fields back to omitted.
        store.setRestoreCommand(nil, pane: .left, forSession: session.id)
        store.setRestoreCommand(nil, pane: .right, forSession: session.id)
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.restoreCommand == nil)
        #expect(node.splitRestoreCommand == nil)
    }

    @Test func controlTreeThreadsFontSizesFromClosures() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        // default closures: the font-size fields are omitted (nil), like foreground.
        var node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.fontSize == nil)
        #expect(node.splitFontSize == nil)
        #expect(node.scratchFontSize == nil)
        // the host supplies live per-pane sizes via closures (the app reads them off the surfaces).
        node = try #require(store.controlTree(fontSize: { _ in 13 }, splitFontSize: { _ in 9.5 },
                                              scratchFontSize: { _ in 11 }).workspaces[0].sessions.first)
        #expect(node.fontSize == 13)
        #expect(node.splitFontSize == 9.5)
        #expect(node.scratchFontSize == 11)
    }

    @Test func controlTreeFontSizeReadsPromotedSurvivorViaAddressableSurface() throws {
        // regression: after the primary pane exits, the fontSize read-back must resolve through
        // addressableSurface — the same surface the font default/left WRITE path targets. With true
        // promotion the survivor MOVES into `surface`, so addressableSurface === surface and the
        // read-back keeps reporting the live shell across the collapse.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()
        let survivor = SpySurface()
        session.splitSurface = survivor
        session.isSplit = true
        session.hasSplit = true
        store.closePrimaryPane(session.id)                 // primary exits -> survivor promoted into `surface`
        #expect(session.surface === survivor)
        #expect(session.addressableSurface === survivor)
        let promoted = store.controlTree(fontSize: { $0.addressableSurface != nil ? 13 : nil })
        #expect(promoted.workspaces[0].sessions.first?.fontSize == 13)
        // the `?? splitSurface` term is a defensive fallback now — hand-build the surface-less state it
        // covers and keep the addressable-vs-bare-`surface` distinction guarded: a closure over bare
        // `surface` reports nothing there, the addressable one still finds the live split shell.
        let fallback = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        fallback.hasSplit = true
        fallback.splitSurface = SpySurface()
        let viaAddressable = store.controlTree(fontSize: { $0.addressableSurface != nil ? 13 : nil })
        #expect(viaAddressable.workspaces[0].sessions.last?.fontSize == 13)
        let viaSurface = store.controlTree(fontSize: { $0.surface != nil ? 13 : nil })
        #expect(viaSurface.workspaces[0].sessions.last?.fontSize == nil)
    }

    @Test func controlTreeReportsSplitFocused() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        // no split: the field is omitted (nil).
        var node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.splitFocused == nil)
        // opening a split focuses the new (right) pane.
        store.toggleSplit(session.id)
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.splitFocused == true)
        // focusing the main (left) pane surfaces false — distinct from nil (= no split).
        session.splitFocused = false
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.splitFocused == false)
        // a hidden split keeps the focus readable (gated on hasSplit, not isSplit).
        store.toggleSplit(session.id)
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.split == false)
        #expect(node.splitFocused == false)
    }

    @Test func controlTreeReportsStatusModifiers() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        // idle: no status, so blink/color are omitted.
        var node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.statusBlink == nil)
        #expect(node.statusColor == nil)
        // a blocked status with blink + a color override surfaces both modifiers.
        store.setAgentIndicator(AgentIndicator(status: .blocked, blink: true, color: "#ff8800"), forSession: session.id)
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.status == "blocked")
        #expect(node.statusBlink == true)
        #expect(node.statusColor == "#ff8800")
        // a status without blink omits statusBlink (false -> nil); without a color override omits statusColor.
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.status == "active")
        #expect(node.statusBlink == nil)
        #expect(node.statusColor == nil)
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

    @Test func closePrimaryPaneMigratesRightTaggedStatusToLeft() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface(); session.splitSurface = SpySurface()
        session.isSplit = true; session.hasSplit = true
        // the `.right` block is owned by the split, which is PROMOTED into the main slot — its status follows,
        // re-tagged to `.left` (like the cwd/title migration) so `tree` (now split:false) and the survivor's
        // left-role-aware keystroke-clear agree, instead of a self-contradictory split:false + statusPane:right.
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)
        store.closePrimaryPane(session.id)
        #expect(session.agentIndicator.status == .blocked)   // the survivor's block persists across promotion
        #expect(session.agentIndicator.statusPane == .left)  // re-tagged to the (now sole) main pane
    }

    @Test func setAgentIndicatorCoercesRightToLeftWithoutLiveSplit() {
        // a promoted survivor's shell keeps its baked `AGTERM_PANE=right`, so the agent-status hook re-emits
        // `--pane right` on every status AFTER promotion — but there is no right pane. `setAgentIndicator`
        // coerces `.right` to `.left` when the session has no split (`hasSplit` false), so a post-promotion
        // status can't re-create the `split:false` + `statusPane:"right"` contradiction and the sole
        // `.left`-role-aware pane can still keystroke-clear it. (Drives what the agent-status wrapper does;
        // host-free, CI-covered.)
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        // an actual PROMOTED SURVIVOR: split, exit the primary (survivor promotes), then the still-.right-baked
        // hook fires the next status — the reviewer's exact scenario.
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface(); session.splitSurface = SpySurface()
        session.isSplit = true; session.hasSplit = true
        store.closePrimaryPane(session.id) // primary exits → survivor promoted, hasSplit/splitSurface cleared
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)
        #expect(session.agentIndicator.statusPane == .left)                      // coerced — no live split
        #expect(session.agentIndicator.clearedBy(pane: .left, isInterrupt: false))  // the sole (left) pane clears it
        // and the tree agrees: split:false with statusPane "left", never the contradictory "right".
        let node = store.controlTree().workspaces[0].sessions.first
        #expect(node?.split == false)
        #expect(node?.statusPane == "left")
        // a session with a LIVE split keeps `.right` — the right pane really exists (incl. a hidden-but-live split).
        let split = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        split.hasSplit = true; split.splitSurface = SpySurface()
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: split.id)
        #expect(split.agentIndicator.statusPane == .right)                    // kept — a live split owns it
    }

    @Test func setAgentIndicatorKeepsRightDuringSplitRealization() {
        // the realization window: `toggleSplit` sets `hasSplit` synchronously while the deck creates
        // `splitSurface` a render pass later — so a scripted `session.split` + immediate
        // `session.status --pane right` arrives with `hasSplit == true` but `splitSurface == nil`.
        // `.right` is the correct forward tag there and must NOT be coerced to `.left`, or the realized
        // split reports `split:true` + `statusPane:"left"` and only the LEFT pane could clear a block the
        // RIGHT pane owns — the mirror of the promoted-survivor bug. Guards the `!hasSplit` predicate:
        // the old `splitSurface == nil` gate rewrites this tag and fails the test.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()
        store.toggleSplit(session.id) // hasSplit set synchronously; splitSurface not yet realized
        #expect(session.hasSplit == true)
        #expect(session.splitSurface == nil)
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)
        #expect(session.agentIndicator.statusPane == .right)                  // kept — the split is coming up
        // once the deck realizes the surface, the block is exactly where the right pane can clear it.
        session.splitSurface = SpySurface()
        #expect(session.agentIndicator.clearedBy(pane: .right, isInterrupt: false))
        let node = store.controlTree().workspaces[0].sessions.first
        #expect(node?.split == true)
        #expect(node?.statusPane == "right")
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
