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
        #expect(session.hasSplit == true)
        #expect(session.splitFocused == true)
    }

    @Test func controlTreeReportsHasSplitAcrossHide() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        func node() -> ControlSessionNode? { store.controlTree().workspaces.first?.sessions.first }
        // bind before asserting: `node()?.hasSplit == nil` also holds when the session is gone from the
        // tree, so a closeSplit that tore down the whole session would pass every omission check here.
        var n = try #require(node())
        #expect(n.split == false)
        #expect(n.hasSplit == nil)
        store.toggleSplit(session.id)
        n = try #require(node())
        #expect(n.split == true)
        #expect(n.hasSplit == true)
        store.toggleSplit(session.id)
        n = try #require(node())
        #expect(n.split == false)
        #expect(n.hasSplit == true)
        #expect(n.splitFocused != nil, "a hidden split still reports its focused pane")
        store.closeSplit(session.id)
        n = try #require(node())
        #expect(n.hasSplit == nil)
        #expect(n.splitFocused == nil)
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

    @Test func axisSpecificSplitFollowsCreateHideTransposeAndReshowMatrix() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        store.toggleSplit(session.id, axis: .topBottom)
        #expect(session.isSplit && session.hasSplit)
        #expect(session.splitAxis == .topBottom)
        #expect(session.splitFocused)

        session.splitFocused = false
        store.toggleSplit(session.id, axis: .leftRight)
        #expect(session.isSplit)
        #expect(session.splitAxis == .leftRight)
        #expect(!session.splitFocused, "transposition preserves the focused pane")

        store.toggleSplit(session.id, axis: .leftRight)
        #expect(!session.isSplit)
        #expect(session.hasSplit)
        #expect(session.splitAxis == .leftRight)

        store.toggleSplit(session.id, axis: .topBottom)
        #expect(session.isSplit)
        #expect(session.splitAxis == .topBottom)
        #expect(!session.splitFocused, "reshowing a hidden split preserves the focused pane")
    }

    @Test func genericSplitPreservesLegacyBehaviorAndCurrentAxis() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.splitAxis = .topBottom

        store.toggleSplit(session.id)
        #expect(session.isSplit)
        #expect(session.splitAxis == .topBottom)
        store.toggleSplit(session.id)
        #expect(!session.isSplit)
        #expect(session.splitAxis == .topBottom)
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
        session.splitAxis = .topBottom
        store.closeSplit(session.id)
        #expect(session.isSplit == false)
        #expect(session.hasSplit == false)
        #expect(session.splitFocused == false)
        #expect(session.splitSurface == nil)
        #expect(session.splitCwd == nil)
        #expect(session.initialSplitCwd == nil)
        #expect(session.splitRatio == nil) // teardown clears geometry too, so a fresh re-split opens even
        #expect(session.splitAxis == .leftRight)
        #expect(split.teardownCount == 1)
    }

    @Test func clampSplitRatioBoundsValue() {
        #expect(AppStore.clampSplitRatio(0.7) == 0.7)
        #expect(AppStore.clampSplitRatio(2.0) == AppStore.splitRatioMax)
        #expect(AppStore.clampSplitRatio(-1.0) == AppStore.splitRatioMin)
        #expect(AppStore.clampSplitRatio(AppStore.splitRatioMin) == AppStore.splitRatioMin)
        #expect(AppStore.clampSplitRatio(AppStore.splitRatioMax) == AppStore.splitRatioMax)
    }

    @Test func applySplitRatioClampsSetsAndReturns() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(store.applySplitRatio(0.7, forSession: session.id) == 0.7)
        #expect(session.splitRatio == 0.7)
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
        #expect(store.session(withID: session.id) != nil)
        #expect(primary.teardownCount == 1)
        #expect(split.teardownCount == 0)
        #expect(split.promotedCount == 1)                 // the survivor is promoted to the primary role
        #expect(session.surface === split)
        #expect(session.splitSurface == nil)
        #expect(session.isSplit == false)
        #expect(session.hasSplit == false)
        #expect(session.splitFocused == false)            // no split anymore; the survivor is the main pane
        #expect(session.splitRatio == nil)                // promoted to single, so a later split opens even
        #expect(session.initialCommand == nil)            // the command pane is gone; a restart must NOT resurrect it
        #expect(session.currentCwd == "/var/log")
        #expect(session.oscTitle == "remote-host")
        #expect(session.foregroundCommand == ["ssh", "host"])
        #expect(session.splitCwd == nil)
        #expect(session.splitTitle == nil)
        #expect(session.splitForegroundCommand == nil)
        // the `?? splitSurface` fallback is for a shown split pre-collapse, not for a promoted survivor.
        #expect(session.addressableSurface === split)
    }

    // #416: `session.new` answers ok for a model insert, and libghostty refuses to build a surface while
    // the display sleeps, so this is the field that separates a working session from an empty one.
    @Test func controlTreeReportsMainPaneRealization() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!

        func realized() -> Bool? { store.controlTree().workspaces.first?.sessions.first?.realized }

        #expect(realized() == false, "an empty surface slot has no terminal, so it is not realized")

        let parked = SpySurface()
        parked.isRealized = false
        session.surface = parked
        #expect(realized() == false, "a parked view whose libghostty surface never came up is not realized")

        parked.isRealized = true
        #expect(realized() == true)
    }

    @Test func addressableSurfaceIsTheMainPaneUntilThePrimaryExits() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        #expect(session.addressableSurface === primary)

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
        // a RESTORED split has `initialSplitCwd` seeded while the live `splitCwd`/`splitTitle` are nil.
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
        #expect(session.initialSplitCwd == nil)
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
        #expect(session.searchActive)
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

    // the promoted surface still carries the split pane's `onExit`, so it lands in `closeSplitPane` even
    // though it is now the sole pane.
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
        #expect(session.surface === split)
        #expect(session.splitSurface == nil)
        store.closeSplitPane(session.id)                   // the survivor's stale split `onExit` fires
        #expect(store.session(withID: session.id) == nil)  // last pane → session closed, no zombie
        #expect(split.teardownCount == 1)                  // the promoted surface is torn down exactly once
    }

    // the survivor's role is primary now, so its exit runs `closePrimaryPane` and must collapse onto the
    // FRESH right pane rather than tearing it down.
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
        #expect(session.surface === firstSplit)
        #expect(session.splitSurface == nil)
        let secondSplit = SpySurface(); session.splitSurface = secondSplit
        session.isSplit = true
        session.hasSplit = true
        session.splitFocused = true
        store.closePrimaryPane(session.id)                 // the promoted MAIN pane's own exit routes here
        #expect(store.session(withID: session.id) != nil)  // session survives — the split is promoted, not lost
        #expect(session.surface === secondSplit)           // the FRESH right pane took over the main slot
        #expect(session.splitSurface == nil)
        #expect(secondSplit.promotedCount == 1)
        #expect(secondSplit.teardownCount == 0)
        #expect(firstSplit.teardownCount == 1)             // the exited (promoted) main pane is torn down
    }

    @Test func closePrimaryPaneWithoutSplitClosesSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let primary = SpySurface(); session.surface = primary
        store.closePrimaryPane(session.id)
        #expect(store.session(withID: session.id) == nil)
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
        #expect(store.session(withID: session.id) != nil)
        #expect(split.teardownCount == 1)
        #expect(primary.teardownCount == 0)
        #expect(session.splitSurface == nil)
        #expect(session.isSplit == false)
        #expect(session.splitRatio == nil)                // delegates to closeSplit, which clears the ratio
    }

    @Test func closeSplitPaneWithoutPrimaryClosesSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let split = SpySurface(); session.splitSurface = split
        store.closeSplitPane(session.id)
        #expect(store.session(withID: session.id) == nil)
        #expect(split.teardownCount == 1)
    }

    @Test func closePrimaryPaneMigratesBothRestoreOverrideHalvesUp() {
        // both legs follow the survivor: the persisted pin AND any payload still armed for this launch.
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
        #expect(session.programOverlayActive)
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

    // MARK: - hud

    @Test func openHudOccupiesTheSlotAndMarksItAHud() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let spec = HudSpec(message: "gathering options", detail: "scanning", backgroundColor: "#101820")
        #expect(store.openHud(session.id, command: "hud.sh", spec: spec, file: "/tmp/h", size: HudPanelSize(widthPercent: 30, heightPercent: 9)) == true)
        #expect(session.overlayActive == true)
        #expect(session.hudActive == true)
        #expect(session.overlayCommand == "hud.sh")
        #expect(session.hudSpec == spec)
        #expect(session.hudFile == "/tmp/h")
        #expect(session.overlaySizePercent == 30)
        // the height arrives measured and is stored as given: only the width takes the caller-facing clamp
        #expect(session.hudHeightPercent == 9)
        // the spec's color reaches the slot the factory reads, and a HUD is never a PROGRAM overlay.
        #expect(session.overlayBackgroundColor == "#101820")
        #expect(session.fullOverlayActive == false)
        #expect(session.programOverlayActive == false)
        // a HUD's own clamp, not the overlay's 1...100: 100 would cover the session the message is about,
        // which is the invariant `overlay.resize --full` is refused for.
        store.closeHud(session.id)
        store.openHud(session.id, command: "hud.sh", spec: spec, file: "/tmp/h", size: HudPanelSize(widthPercent: 400, heightPercent: 9))
        #expect(session.overlaySizePercent == HudLayout.maxSizePercent)
        store.closeHud(session.id)
        store.openHud(session.id, command: "hud.sh", spec: spec, file: "/tmp/h", size: HudPanelSize(widthPercent: 100, heightPercent: 9))
        #expect(session.overlaySizePercent == HudLayout.maxSizePercent)
        store.closeHud(session.id)
        store.openHud(session.id, command: "hud.sh", spec: spec, file: "/tmp/h", size: HudPanelSize(widthPercent: 1, heightPercent: 9))
        #expect(session.overlaySizePercent == HudLayout.minSizePercent)
    }

    @Test func updateHudRewritesInPlaceWithoutRespawning() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        let surface = SpySurface()
        session.overlaySurface = surface
        let generation = session.overlaySlotGeneration
        let next = HudSpec(message: "two", detail: "still working", spinner: .braille, position: .topCenter)
        #expect(store.updateHud(session.id, spec: next, size: HudPanelSize(widthPercent: 44, heightPercent: 15)) == true)
        #expect(session.hudSpec == next)
        // an update cannot move the file: the running helper opened the path `openHud` gave it.
        #expect(session.hudFile == "/tmp/a")
        #expect(session.overlaySizePercent == 44)
        // a longer message is a taller panel, so both axes move with the text
        #expect(session.hudHeightPercent == 15)
        // the helper re-reads the file, so nothing re-spawns: same surface, same view identity.
        #expect(surface.teardownCount == 0)
        #expect(session.overlaySurface === surface)
        #expect(session.overlaySlotGeneration == generation)
        // an update takes the HUD's clamp too, at both ends, so no resize path can grow it into a cover.
        #expect(store.updateHud(session.id, spec: next, size: HudPanelSize(widthPercent: 0, heightPercent: 9)) == true)
        #expect(session.overlaySizePercent == HudLayout.minSizePercent)
        #expect(store.updateHud(session.id, spec: next, size: HudPanelSize(widthPercent: 100, heightPercent: 9)) == true)
        #expect(session.overlaySizePercent == HudLayout.maxSizePercent)
    }

    @Test func resizingAHudLeavesItsMeasuredHeightAlone() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))

        #expect(store.resizeOverlay(session.id, sizePercent: 60) == true)

        #expect(session.overlaySizePercent == 60)
        // the text wraps at maxColumns rather than at the panel, so a wider panel needs no more rows
        #expect(session.hudHeightPercent == 9)
    }

    @Test func closingAHudClearsItsMeasuredHeight() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))

        #expect(store.closeHud(session.id) == true)

        #expect(session.hudHeightPercent == nil)
    }

    @Test func updateHudRefusesWithoutAHud() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let spec = HudSpec(message: "hello")
        #expect(store.updateHud(session.id, spec: spec, size: HudPanelSize(widthPercent: 20, heightPercent: 9)) == false)
        // a caller's program in the slot is not a HUD's to rewrite.
        store.openOverlay(session.id, command: "htop", sizePercent: 60)
        #expect(store.updateHud(session.id, spec: spec, size: HudPanelSize(widthPercent: 20, heightPercent: 9)) == false)
        #expect(session.hudSpec == nil)
        #expect(session.overlaySizePercent == 60)
    }

    @Test func updateHudKeepsTheColorTheSurfaceWasCreatedWith() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one", backgroundColor: "#101820"),
                      file: "/tmp/a", size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        // the CLI's update carries no color, and the panel still paints the one it was created with
        #expect(store.updateHud(session.id, spec: HudSpec(message: "two"), size: HudPanelSize(widthPercent: 30, heightPercent: 9)) == true)
        #expect(session.hudSpec?.backgroundColor == "#101820")
        #expect(session.overlayBackgroundColor == "#101820")
        // nor may a color the factory will never read reach the stored spec
        let recolor = HudSpec(message: "three", backgroundColor: "#ff0000")
        #expect(store.updateHud(session.id, spec: recolor, size: HudPanelSize(widthPercent: 30, heightPercent: 9)) == true)
        #expect(session.hudSpec?.backgroundColor == "#101820")
        #expect(session.overlayBackgroundColor == "#101820")
        #expect(session.hudSpec?.message == "three")
    }

    /// The two colors have opposite update lifetimes, and both halves are asserted here so a change making
    /// them symmetric cannot pass: the background is held forward because the surface read it once, while
    /// the text color rides the header and so drops with every other omitted field.
    @Test func updateHudDropsAnOmittedTextColorWhileHoldingTheBackground() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openHud(session.id, command: "hud.sh",
                      spec: HudSpec(message: "one", backgroundColor: "#101820", textColor: "#e0e0e0"),
                      file: "/tmp/a", size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        #expect(session.hudSpec?.textColor == "#e0e0e0")

        #expect(store.updateHud(session.id, spec: HudSpec(message: "two"),
                                size: HudPanelSize(widthPercent: 20, heightPercent: 9)) == true)

        #expect(session.hudSpec?.textColor == nil)
        #expect(session.hudSpec?.backgroundColor == "#101820")
    }

    /// Every store-only HUD teardown, none of which runs a surface teardown: a HUD closed before its panel
    /// realized would otherwise leave its message text in `/tmp` forever.
    @Test(arguments: HudTeardownPath.allCases)
    func storeTeardownRemovesAnUnrealizedHudBodyFile(_ path: HudTeardownPath) throws {
        let store = makeStore()
        _ = store.addWorkspace(name: "keep") // removeWorkspace keeps the last workspace
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let file = try Self.makeBodyFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        #expect(store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "gathering options"),
                              file: file, size: HudPanelSize(widthPercent: 20, heightPercent: 9)) == true)
        #expect(session.overlaySurface == nil)

        switch path {
        case .overlayClose: #expect(store.closeOverlay(session.id) == true)
        case .hudClose: #expect(store.closeHud(session.id) == true)
        case .sessionClose: store.closeSession(session.id)
        case .workspaceRemove: store.removeWorkspace(ws.id)
        case .pendingFinalize:
            #expect(store.softCloseSession(session.id) == true)
            store.finalizeAllPendingCloses()
        }

        #expect(!FileManager.default.fileExists(atPath: file))
    }

    enum HudTeardownPath: CaseIterable, Sendable {
        case overlayClose, hudClose, sessionClose, workspaceRemove, pendingFinalize
    }

    private static func makeBodyFile() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-hud-test-\(UUID().uuidString).txt")
        try Data("20 4 0 1\ngathering options".utf8).write(to: url)
        return url.path
    }

    @Test func closeHudTearsDownAndClearsTheSlot() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a", size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        let surface = SpySurface()
        session.overlaySurface = surface
        #expect(store.closeHud(session.id) == true)
        #expect(surface.teardownCount == 1)
        #expect(session.overlayActive == false)
        #expect(session.hudActive == false)
        #expect(session.hudSpec == nil)
        #expect(session.hudFile == nil)
        #expect(session.overlaySizePercent == nil)
        #expect(store.closeHud(session.id) == false)
    }

    @Test func closeHudRefusesAProgramOverlay() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openOverlay(session.id, command: "htop", sizePercent: 60)
        #expect(store.closeHud(session.id) == false)
        #expect(session.overlayActive == true)
        #expect(session.overlayCommand == "htop")
    }

    @Test func closeOverlayClearsHudState() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a", size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        // the courtesy path (`session.overlay.close`, ⌘W) clears the HUD as thoroughly as `closeHud` does.
        #expect(store.closeOverlay(session.id) == true)
        #expect(session.hudSpec == nil)
        #expect(session.hudFile == nil)
        #expect(session.hudActive == false)
    }

    @Test func secondOpenHudReplacesTheFirst() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a", size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        let first = SpySurface()
        session.overlaySurface = first
        let generation = session.overlaySlotGeneration
        let next = HudSpec(message: "two", position: .bottomCenter)
        #expect(store.openHud(session.id, command: "hud.sh", spec: next, file: "/tmp/b", size: HudPanelSize(widthPercent: 35, heightPercent: 9)) == true)
        #expect(session.hudSpec == next)
        #expect(session.hudFile == "/tmp/b")
        #expect(session.overlaySizePercent == 35)
        // an open is a fresh panel: the old surface is gone and the identity moves, so the deck re-mounts.
        #expect(first.teardownCount == 1)
        #expect(session.overlaySurface == nil)
        #expect(session.overlaySlotGeneration > generation)
    }

    @Test func openOverlayReplacesAHudButRefusesAProgram() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a", size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        let hud = SpySurface()
        session.overlaySurface = hud
        let generation = session.overlaySlotGeneration
        #expect(store.openOverlay(session.id, command: "htop") == true)
        #expect(session.hudSpec == nil)
        #expect(session.hudFile == nil)
        #expect(session.hudActive == false)
        #expect(session.overlayCommand == "htop")
        #expect(session.fullOverlayActive == true)
        // the HUD's surface is torn down and the identity moves, so the program actually mounts.
        #expect(hud.teardownCount == 1)
        #expect(session.overlaySurface == nil)
        #expect(session.overlaySlotGeneration > generation)
        // a RUNNING program still owns the slot against everything.
        #expect(store.openOverlay(session.id, command: "other") == false)
        #expect(store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "x"), file: "/tmp/c",
                              size: HudPanelSize(widthPercent: 20, heightPercent: 9)) == false)
        #expect(session.overlayCommand == "htop")
        #expect(session.hudSpec == nil)
    }

    @Test func overlaySlotGenerationTracksOpensOnly() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(session.overlaySlotGeneration == 0)
        store.openOverlay(session.id, command: "htop", sizePercent: 60)
        #expect(session.overlaySlotGeneration == 1)
        // a resize keeps the same surface mounted, so the identity must hold still.
        store.resizeOverlay(session.id, sizePercent: 30)
        #expect(session.overlaySlotGeneration == 1)
        // a refused open must not move it either, or the deck re-mounts the running program.
        #expect(store.openOverlay(session.id, command: "other") == false)
        #expect(session.overlaySlotGeneration == 1)
        store.closeOverlay(session.id)
        #expect(session.overlaySlotGeneration == 1)
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one"), file: "/tmp/a", size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        #expect(session.overlaySlotGeneration == 2)
    }

    @Test func openHudUnknownSessionFails() {
        let store = makeStore()
        #expect(store.openHud(UUID(), command: "hud.sh", spec: HudSpec(message: "x"), file: "/tmp/a",
                              size: HudPanelSize(widthPercent: 20, heightPercent: 9)) == false)
        #expect(store.updateHud(UUID(), spec: HudSpec(message: "x"), size: HudPanelSize(widthPercent: 20, heightPercent: 9)) == false)
        #expect(store.closeHud(UUID()) == false)
    }

    // MARK: - pane overlays

    @Test func openPaneOverlayStoresSlotAndClearsStaleExitCode() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.leftOverlayExitCode = 7
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "revdiff", cwd: "/b") == nil)
        #expect(session.leftOverlay == PaneOverlay(command: "revdiff", cwd: "/b"))
        #expect(session.leftOverlayExitCode == nil)
        #expect(session.rightOverlay == nil)
        #expect(session.openPaneOverlays == [.left])
    }

    @Test func openPaneOverlayRoundTripsWait() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "make test", wait: true) == nil)
        #expect(session.leftOverlay?.wait == true)
        store.closePaneOverlay(session.id, pane: .left)
        // omitting it must not leave the previous overlay's flag behind.
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "make test") == nil)
        #expect(session.leftOverlay?.wait == false)
    }

    @Test func openPaneOverlayOnBothPanesKeepsSlotsIndependent() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "revdiff", cwd: "/l",
                                      backgroundColor: "#111111") == nil)
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "htop", cwd: "/r", wait: true,
                                      backgroundColor: "#222222") == nil)
        #expect(session.leftOverlay == PaneOverlay(command: "revdiff", cwd: "/l", backgroundColor: "#111111"))
        #expect(session.rightOverlay == PaneOverlay(command: "htop", cwd: "/r", backgroundColor: "#222222",
                                                    wait: true))
        #expect(session.openPaneOverlays == [.left, .right])
        // a session-wide overlay is a separate slot: opening one leaves both pane slots untouched.
        #expect(store.openOverlay(session.id, command: "less") == true)
        #expect(session.openPaneOverlays == [.left, .right])
        // and closing one pane leaves the sibling and the session-wide overlay alone.
        #expect(store.closePaneOverlay(session.id, pane: .left) == true)
        #expect(session.openPaneOverlays == [.right])
        #expect(session.overlayActive == true)
    }

    @Test func openPaneOverlayRejectsASecondOnTheSamePane() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "revdiff") == nil)
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "htop") == .alreadyOpen)
        #expect(session.leftOverlay?.command == "revdiff")
    }

    @Test func openPaneOverlayRejectsAnUnrenderedPane() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        // no split shown: the right pane is not laid out, so its surface would never be created.
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "htop") == .paneNotVisible)
        #expect(session.rightOverlay == nil)
        // hidden split with the right pane maximized: now the LEFT pane is the unrendered one.
        session.hasSplit = true
        session.splitFocused = true
        session.splitSurface = SpySurface()
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "revdiff") == .paneNotVisible)
        #expect(session.leftOverlay == nil)
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "htop") == nil)
    }

    // the open guard only proves the pane renders at REQUEST time; the deck realizes the surface later, so a
    // hide in between leaves the slot active with no surface and no program — `overlay result --pane right`
    // would answer "overlay still running" forever and `--block` would never return.
    @Test func hidingTheSplitRetiresAPaneOverlayThatNeverRealized() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "revdiff") == nil)
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "htop") == nil)
        store.toggleSplit(session.id) // hidden with the LEFT pane focused: the right pane stops rendering
        #expect(session.rightOverlay == nil)
        #expect(session.openPaneOverlays == [.left]) // the pane still laid out keeps its unrealized slot
        #expect(session.rightOverlayExitCode == nil)
    }

    @Test func hidingTheSplitKeepsARealizedPaneOverlayRunning() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        store.openPaneOverlay(session.id, pane: .right, command: "htop")
        let right = SpySurface()
        session.rightOverlaySurface = right
        store.toggleSplit(session.id)
        #expect(session.rightOverlay?.command == "htop")
        #expect(session.rightOverlaySurface === right)
        #expect(right.teardownCount == 0)
        // and showing the split again leaves it exactly as it was.
        store.toggleSplit(session.id)
        #expect(session.openPaneOverlays == [.right])
    }

    // `surface zoom show --target surface:<id>:overlay-right` claims the slot the deck hands over, so hiding
    // the split must not retire it just because the deck stopped laying that pane out.
    @Test func hidingTheSplitKeepsAPaneOverlayTerminalZoomIsHosting() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let windowID = UUID()
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "htop") == nil)
        zoom.set(.on, target: .session(session.id, .overlayRight))

        store.toggleSplit(session.id)
        #expect(session.rightOverlay?.command == "htop")
        #expect(TerminalZoomSurface.overlayRight.isAvailable(in: session))
    }

    @Test func openPaneOverlayUnknownSessionFails() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(store.openPaneOverlay(UUID(), pane: .left, command: "revdiff") == .unknownSession)
        #expect(session.leftOverlay == nil)
    }

    @Test func closePaneOverlayTearsDownAndKeepsTheExitCode() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openPaneOverlay(session.id, pane: .left, command: "revdiff")
        let surface = SpySurface()
        session.leftOverlaySurface = surface
        store.recordPaneOverlayExit(session.id, pane: .left, code: 3)
        #expect(store.closePaneOverlay(session.id, pane: .left) == true)
        #expect(session.leftOverlay == nil)
        #expect(session.leftOverlaySurface == nil)
        #expect(surface.teardownCount == 1)
        // the exit code survives close (session.overlay.result reads it after the slot goes nil)...
        #expect(session.leftOverlayExitCode == 3)
        // ...and only the next open on that pane resets it.
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "revdiff") == nil)
        #expect(session.leftOverlayExitCode == nil)
        // closing again is a no-op.
        store.closePaneOverlay(session.id, pane: .left)
        #expect(store.closePaneOverlay(session.id, pane: .left) == false)
    }

    @Test func recordPaneOverlayExitTargetsOnlyItsOwnPane() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.splitSurface = SpySurface()
        store.openPaneOverlay(session.id, pane: .left, command: "revdiff")
        store.openPaneOverlay(session.id, pane: .right, command: "htop")
        store.recordPaneOverlayExit(session.id, pane: .right, code: 12)
        #expect(session.rightOverlayExitCode == 12)
        #expect(session.leftOverlayExitCode == nil)
        // a bogus id must be a no-op, not a crash.
        store.recordPaneOverlayExit(UUID(), pane: .left, code: 5)
        #expect(session.leftOverlayExitCode == nil)
    }

    @Test func closeSplitFreesOnlyTheRightPaneOverlay() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        store.openPaneOverlay(session.id, pane: .left, command: "revdiff")
        store.openPaneOverlay(session.id, pane: .right, command: "htop")
        let left = SpySurface(), right = SpySurface()
        session.leftOverlaySurface = left
        session.rightOverlaySurface = right
        store.recordPaneOverlayExit(session.id, pane: .right, code: 4)
        store.closeSplit(session.id)
        #expect(right.teardownCount == 1)
        #expect(session.rightOverlay == nil)
        #expect(session.rightOverlaySurface == nil)
        #expect(session.rightOverlayExitCode == nil)
        #expect(left.teardownCount == 0)
        #expect(session.leftOverlay?.command == "revdiff")
        #expect(session.leftOverlaySurface === left)
    }

    @Test func closeSplitPaneFreesTheRightPaneOverlay() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        store.openPaneOverlay(session.id, pane: .right, command: "htop")
        let right = SpySurface()
        session.rightOverlaySurface = right
        store.closeSplitPane(session.id)
        #expect(right.teardownCount == 1)
        #expect(session.openPaneOverlays.isEmpty)
    }

    @Test func closePrimaryPaneMigratesTheRightPaneOverlayWithItsExitCode() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        store.openPaneOverlay(session.id, pane: .left, command: "revdiff")
        store.openPaneOverlay(session.id, pane: .right, command: "htop", cwd: "/r", backgroundColor: "#222222")
        let left = SpySurface(), right = SpySurface()
        session.leftOverlaySurface = left
        session.rightOverlaySurface = right
        store.recordPaneOverlayExit(session.id, pane: .right, code: 9)
        store.closePrimaryPane(session.id)
        #expect(left.teardownCount == 1)
        #expect(right.teardownCount == 0)
        #expect(session.leftOverlay == PaneOverlay(command: "htop", cwd: "/r", backgroundColor: "#222222"))
        #expect(session.leftOverlaySurface === right)
        #expect(session.leftOverlayExitCode == 9)
        #expect(session.rightOverlay == nil)
        #expect(session.rightOverlaySurface == nil)
        #expect(session.rightOverlayExitCode == nil)
        #expect(session.openPaneOverlays == [.left])
    }

    @Test func closePrimaryPaneWithNoRightOverlayLeavesBothSlotsEmpty() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.surface = SpySurface()
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        store.openPaneOverlay(session.id, pane: .left, command: "revdiff")
        let left = SpySurface()
        session.leftOverlaySurface = left
        store.recordPaneOverlayExit(session.id, pane: .left, code: 2)
        store.closePrimaryPane(session.id)
        #expect(left.teardownCount == 1)
        #expect(session.openPaneOverlays.isEmpty)
        #expect(session.leftOverlaySurface == nil)
        #expect(session.leftOverlayExitCode == nil)
    }

    @Test func controlTreeReportsOpenPaneOverlays() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        #expect(store.controlTree().workspaces[0].sessions[0].paneOverlays == nil)
        store.openPaneOverlay(session.id, pane: .right, command: "htop")
        #expect(store.controlTree().workspaces[0].sessions[0].paneOverlays == ["right"])
        store.openPaneOverlay(session.id, pane: .left, command: "revdiff")
        #expect(store.controlTree().workspaces[0].sessions[0].paneOverlays == ["left", "right"])
        store.closePaneOverlay(session.id, pane: .left)
        store.closePaneOverlay(session.id, pane: .right)
        #expect(store.controlTree().workspaces[0].sessions[0].paneOverlays == nil)
    }

    @Test func closeSessionFreesBothPaneOverlays() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let (left, right) = openBothPaneOverlays(store: store, session: session)
        store.closeSession(session.id)
        #expect(left.teardownCount == 1)
        #expect(right.teardownCount == 1)
        #expect(session.openPaneOverlays.isEmpty)
        #expect(session.leftOverlaySurface == nil)
        #expect(session.rightOverlaySurface == nil)
    }

    @Test func removeWorkspaceFreesBothPaneOverlays() {
        let store = makeStore()
        let keep = store.addWorkspace(name: "keep")
        _ = store.addSession(toWorkspace: keep.id, cwd: "/k")
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let (left, right) = openBothPaneOverlays(store: store, session: session)
        store.removeWorkspace(ws.id)
        #expect(left.teardownCount == 1)
        #expect(right.teardownCount == 1)
        #expect(session.openPaneOverlays.isEmpty)
    }

    @Test func pendingCloseFinalizationFreesBothPaneOverlays() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let (left, right) = openBothPaneOverlays(store: store, session: session)
        #expect(store.softCloseSession(session.id, grace: 60) == true)
        #expect(left.teardownCount == 0) // the undo window keeps the surfaces alive
        store.finalizeAllPendingCloses()
        #expect(left.teardownCount == 1)
        #expect(right.teardownCount == 1)
        #expect(session.openPaneOverlays.isEmpty)
        #expect(session.leftOverlayExitCode == nil)
    }

    private func openBothPaneOverlays(store: AppStore, session: Session) -> (SpySurface, SpySurface) {
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = SpySurface()
        store.openPaneOverlay(session.id, pane: .left, command: "revdiff")
        store.openPaneOverlay(session.id, pane: .right, command: "htop")
        let left = SpySurface(), right = SpySurface()
        session.leftOverlaySurface = left
        session.rightOverlaySurface = right
        store.recordPaneOverlayExit(session.id, pane: .left, code: 1)
        return (left, right)
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
