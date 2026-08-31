import Foundation
import Testing
@testable import agtermCore

@MainActor
struct SessionTests {
    @Test(arguments: [
        ("/Users/user/dev/foo", "foo"),
        ("/", "/"),
        ("/a/b/", "b"),
        ("/Users/user", "user"),
        ("", "~"),
    ])
    func basenameDerivation(input: String, expected: String) {
        let session = Session(initialCwd: input)
        #expect(session.displayName == expected)
    }

    @Test func currentCwdOverridesInitialForDisplay() {
        let session = Session(initialCwd: "/start")
        #expect(session.displayName == "start")
        session.currentCwd = "/Users/user/dev/bar"
        #expect(session.displayName == "bar")
    }

    @Test func customNameOverridesAuto() {
        let session = Session(initialCwd: "/Users/user/dev/foo")
        #expect(session.displayName == "foo")
        session.customName = "build"
        #expect(session.displayName == "build")
    }

    @Test func clearingCustomNameRestoresAuto() {
        let session = Session(initialCwd: "/Users/user/dev/foo", customName: "build")
        #expect(session.displayName == "build")
        session.customName = nil
        #expect(session.displayName == "foo")
    }

    @Test func emptyCustomNameFallsBackToAuto() {
        let session = Session(initialCwd: "/Users/user/dev/foo", customName: "")
        #expect(session.displayName == "foo")
    }

    @Test func whitespaceOnlyCustomNameFallsBackToAuto() {
        // a whitespace-only customName can only arrive via a hand-edited snapshot — renameSession clears
        // blanks to nil.
        let session = Session(initialCwd: "/Users/user/dev/foo", customName: "   \t")
        #expect(session.displayName == "foo")
    }

    @Test func paddedCustomNameDisplaysTrimmed() {
        let session = Session(initialCwd: "/Users/user/dev/foo", customName: "  build  ")
        #expect(session.displayName == "build")
    }

    @Test func oscTitleOverridesCwd() {
        let session = Session(initialCwd: "/Users/user/dev/foo")
        #expect(session.displayName == "foo")
        session.oscTitle = "user@web1: ~/srv"
        #expect(session.displayName == "user@web1: ~/srv")
    }

    @Test func customNameOverridesOscTitle() {
        let session = Session(initialCwd: "/Users/user/dev/foo", customName: "build")
        session.oscTitle = "user@web1: ~/srv"
        #expect(session.displayName == "build")
    }

    @Test func blankOscTitleFallsBackToCwd() {
        let session = Session(initialCwd: "/Users/user/dev/foo")
        session.oscTitle = "   \t"
        #expect(session.displayName == "foo")
        session.oscTitle = ""
        #expect(session.displayName == "foo")
    }

    @Test func paddedOscTitleDisplaysTrimmed() {
        let session = Session(initialCwd: "/Users/user/dev/foo")
        session.oscTitle = "  web1  "
        #expect(session.displayName == "web1")
    }

    @Test func subtitleDetailPrefersTitleForNamedSession() {
        // on an SSH session the local cwd is stale, so the second line shows the title, not the path.
        let session = Session(initialCwd: "/Users/user", customName: "web1")
        session.currentCwd = "/Users/user"
        session.oscTitle = "user@web1: ~"
        #expect(session.subtitleDetail == "user@web1: ~")
    }

    @Test func promotedSurvivorTitleNotMaskedByStaleSplitFocused() {
        // a promoted survivor can momentarily carry `splitFocused == true` while it is the session's SOLE
        // pane — the split factory's focus callback keeps firing on it.
        let session = Session(initialCwd: "/Users/user", customName: "web1")
        session.currentCwd = "/Users/user"
        session.oscTitle = "user@web1: ~"
        session.splitFocused = true
        session.splitSurface = nil
        session.splitTitle = nil
        session.splitCwd = nil
        #expect(session.subtitleDetail == "user@web1: ~")
        #expect(session.focusedCwd == "/Users/user")
    }

    @Test func primarySurfaceHostRevisionChangesOnlyForLiveReplacement() {
        let session = Session(initialCwd: "/Users/user")
        let original = FakeSurface()
        let replacement = FakeSurface()

        #expect(session.primarySurfaceHostRevision == 0)
        session.surface = original
        #expect(session.primarySurfaceHostRevision == 0) // lazy creation must not force a second mount
        session.surface = original
        #expect(session.primarySurfaceHostRevision == 0) // assigning the same instance is still stable
        session.surface = replacement
        #expect(session.primarySurfaceHostRevision == 1) // promotion replaces the hosted AppKit view
    }

    @Test func subtitleDetailUsesCwdForNamedSessionWithoutTitle() {
        // a local session's auto-title is suppressed, so oscTitle is nil here.
        let session = Session(initialCwd: "/Users/user/dev/foo", customName: "build")
        #expect(session.subtitleDetail == "/Users/user/dev/foo")
    }

    @Test func subtitleDetailUsesCwdWhenTitleIsAlreadyDisplayName() {
        let session = Session(initialCwd: "/Users/user")
        session.currentCwd = "/Users/user"
        session.oscTitle = "user@web1: ~"
        #expect(session.displayName == "user@web1: ~")
        #expect(session.subtitleDetail == "/Users/user")
    }

    @Test func subtitleDetailUsesCwdForPlainLocalSession() {
        let session = Session(initialCwd: "/Users/user/dev/foo")
        #expect(session.subtitleDetail == "/Users/user/dev/foo")
    }

    @Test func subtitleDetailBlankTitleFallsBackToCwd() {
        let session = Session(initialCwd: "/Users/user/dev/foo", customName: "build")
        session.oscTitle = "  \t"
        #expect(session.subtitleDetail == "/Users/user/dev/foo")
    }

    @Test func subtitleDetailTitleEqualToCustomNameFallsBackToCwd() {
        // the remote titles the tab exactly what the user named the session, so the title repeats line 1.
        let session = Session(initialCwd: "/Users/user", customName: "web1")
        session.currentCwd = "/Users/user"
        session.oscTitle = "web1"
        #expect(session.subtitleDetail == "/Users/user")
    }

    @Test func subtitleDetailFollowsFocusedPane() {
        let session = Session(initialCwd: "/repo", customName: "build")
        session.isSplit = true
        session.splitSurface = FakeSurface() // a focused split always has a live split surface
        session.oscTitle = "primary-title"
        session.splitTitle = "split-title"
        #expect(session.subtitleDetail == "primary-title")
        session.splitFocused = true
        #expect(session.subtitleDetail == "split-title")
    }

    @Test func effectiveCwdFallsBackToInitialUntilPwdReport() {
        // a restored session has no currentCwd until OSC 7 arrives, and the fallback is what lets git
        // status refresh at launch.
        let session = Session(initialCwd: "/repo")
        #expect(session.effectiveCwd == "/repo")
    }

    @Test func effectiveCwdPrefersCurrentCwdOnceReported() {
        let session = Session(initialCwd: "/repo")
        session.currentCwd = "/repo/sub"
        #expect(session.effectiveCwd == "/repo/sub")
    }

    @Test func focusedPaneDrivesDisplayNameAndCwd() {
        let session = Session(initialCwd: "/Users/user/dev/foo")
        session.currentCwd = "/Users/user/dev/foo"
        session.isSplit = true
        session.splitSurface = FakeSurface() // a focused split always has a live split surface
        session.splitCwd = "/var/log"
        #expect(session.displayName == "foo")
        #expect(session.focusedCwd == "/Users/user/dev/foo")
        session.splitFocused = true
        #expect(session.displayName == "log")
        #expect(session.focusedCwd == "/var/log")
    }

    @Test func focusedPaneTitleWins() {
        let session = Session(initialCwd: "/repo")
        session.isSplit = true
        session.splitSurface = FakeSurface() // a focused split always has a live split surface
        session.oscTitle = "primary-title"
        session.splitTitle = "split-title"
        #expect(session.displayName == "primary-title")
        session.splitFocused = true
        #expect(session.displayName == "split-title")
    }

    @Test func customNameWinsOverFocusedSplitPane() {
        let session = Session(initialCwd: "/repo", customName: "build")
        session.isSplit = true
        session.splitFocused = true
        session.splitTitle = "split-title"
        session.splitCwd = "/var/log"
        #expect(session.displayName == "build")
    }

    @Test func hiddenSplitStillShowsFocusedSplitPane() {
        // split hidden but the right pane is shown maximized + focused. The guard is splitFocused, not
        // isSplit — closeSplit resets the flag, so it is true only while the pane exists.
        let session = Session(initialCwd: "/repo")
        session.currentCwd = "/repo/sub"
        session.splitSurface = FakeSurface()
        session.splitFocused = true
        session.splitCwd = "/var/log"
        #expect(session.focusedCwd == "/var/log")
        #expect(session.displayName == "log")
    }

    @Test func focusedCwdFallsBackUntilSplitReports() {
        // splitSurface must be set, else the split-existence guard short-circuits and this exercises the
        // missing-surface branch instead of the `let cwd = splitCwd` nil fallback.
        let session = Session(initialCwd: "/repo")
        session.currentCwd = "/repo/primary"
        session.isSplit = true
        session.splitSurface = FakeSurface()
        session.splitFocused = true
        #expect(session.focusedCwd == "/repo/primary")
        #expect(session.displayName == "primary")
    }

    @Test func effectiveCwdStaysPrimaryWhileSplitFocused() {
        let session = Session(initialCwd: "/repo")
        session.currentCwd = "/repo/primary"
        session.isSplit = true
        session.splitFocused = true
        session.splitCwd = "/var/log"
        #expect(session.effectiveCwd == "/repo/primary")
    }

    @Test func cwdForPaneResolvesPaneSpecificDirectory() {
        let session = Session(initialCwd: "/repo")
        session.currentCwd = "/repo/primary"
        session.splitCwd = "/var/log"
        #expect(session.cwd(for: .left) == "/repo/primary")
        #expect(session.cwd(for: .scratch) == "/repo/primary")
        #expect(session.cwd(for: .right) == "/var/log")

        session.splitCwd = nil
        session.initialSplitCwd = "/var/restored"
        #expect(session.cwd(for: .right) == "/var/restored")

        session.initialSplitCwd = nil
        #expect(session.cwd(for: .right) == "/repo/primary")
    }

    @Test func agentIndicatorDefaultsToIdle() {
        let session = Session(initialCwd: "/repo")
        #expect(session.agentIndicator == AgentIndicator())
        #expect(session.agentIndicator.status == .idle)
        #expect(session.agentIndicator.blink == false)
    }

    @Test func activeSurfacePicksFocusedPane() {
        let session = Session(initialCwd: "/repo")
        let primary = FakeSurface(), split = FakeSurface()
        session.surface = primary
        #expect(session.activeSurface === primary)
        session.splitSurface = split
        session.splitFocused = false
        #expect(session.activeSurface === primary)
        session.splitFocused = true
        #expect(session.activeSurface === split)
        // split pane gone (e.g. its shell exited) but the focus flag is stale: fall back to primary.
        session.splitSurface = nil
        #expect(session.activeSurface === primary)
    }

    @Test func searchDisplayTextIsEmptyBeforeAnyQuery() {
        let session = Session(initialCwd: "/repo")
        #expect(session.searchDisplayText == "")
    }

    @Test func searchDisplayTextReportsNoMatches() {
        let session = Session(initialCwd: "/repo")
        session.searchTotal = 0
        #expect(session.searchDisplayText == "no matches")
        // a selected index is meaningless at zero matches; still "no matches".
        session.searchSelected = 1
        #expect(session.searchDisplayText == "no matches")
    }

    @Test func searchDisplayTextReportsTotalWhenNoneSelected() {
        let session = Session(initialCwd: "/repo")
        session.searchTotal = 5
        #expect(session.searchDisplayText == "5 matches")
    }

    @Test func searchDisplayTextReportsSelectedOfTotal() {
        let session = Session(initialCwd: "/repo")
        session.searchTotal = 5
        session.searchSelected = 2
        #expect(session.searchDisplayText == "2 of 5")
    }

    @Test func searchDisplayTextClampsStaleSelectedToTotal() {
        // the count can shrink before the next SEARCH_SELECTED lands, so selected is clamped to total.
        let session = Session(initialCwd: "/repo")
        session.searchTotal = 2
        session.searchSelected = 3
        #expect(session.searchDisplayText == "2 of 2")
    }

    @Test func searchFieldsAreNotPersistedAcrossSnapshot() {
        let store = AppStore(persistence: PersistenceStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")))
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.searchActive = true
        session.searchNeedle = "todo"
        session.searchTotal = 3
        session.searchSelected = 1
        let restored = AppStore(persistence: PersistenceStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")))
        restored.restore(from: store.snapshot())
        let r = restored.workspaces[0].sessions[0]
        #expect(r.searchActive == false)
        #expect(r.searchNeedle == "")
        #expect(r.searchTotal == nil)
        #expect(r.searchSelected == nil)
    }

    @Test func searchSurfacePinsTheOwnerAndIsWeak() {
        // weak on purpose: the session strongly owns its panes, so the pin must not retain a surface.
        let session = Session(initialCwd: "/repo")
        var owner: FakeSurface? = FakeSurface()
        session.searchSurface = owner
        #expect(session.searchSurface === owner)
        owner = nil
        #expect(session.searchSurface == nil)
    }

    @Test func clearSearchResetsAllSearchState() {
        let session = Session(initialCwd: "/repo")
        let owner = FakeSurface()
        session.searchActive = true
        session.searchNeedle = "needle"
        session.searchTotal = 4
        session.searchSelected = 2
        session.searchSurface = owner
        session.clearSearch()
        #expect(session.searchActive == false)
        #expect(session.searchNeedle == "")
        #expect(session.searchTotal == nil)
        #expect(session.searchSelected == nil)
        #expect(session.searchSurface == nil)
    }

    @Test func topmostSurfacePrefersOverlayThenScratchThenPane() {
        let session = Session(initialCwd: "/repo")
        let primary = FakeSurface(), scratch = FakeSurface(), overlay = FakeSurface()
        session.surface = primary
        session.scratchSurface = scratch
        session.overlaySurface = overlay
        #expect(session.topmostSurface === primary)
        session.scratchActive = true
        #expect(session.topmostSurface === scratch)
        session.overlayActive = true
        #expect(session.topmostSurface === overlay)
        session.overlayActive = false
        #expect(session.topmostSurface === scratch)
        session.scratchActive = false
        #expect(session.topmostSurface === primary)
    }

    @Test func onScreenSurfaceIsCoveringScratchElseFocusedPane() {
        // an overlay falls back to the pane — search/text don't target the ephemeral overlay, matching
        // AppActions.searchTarget.
        let session = Session(initialCwd: "/repo")
        let primary = FakeSurface(), split = FakeSurface(), scratch = FakeSurface(), overlay = FakeSurface()
        session.surface = primary
        session.splitSurface = split
        session.scratchSurface = scratch
        session.overlaySurface = overlay
        #expect(session.onScreenSurface === primary)
        session.splitFocused = true
        #expect(session.onScreenSurface === split)
        session.splitFocused = false
        session.scratchActive = true
        #expect(session.onScreenSurface === scratch)
        session.overlayActive = true
        #expect(session.onScreenSurface === primary)
    }

    @Test func fullOverlayActiveOnlyForFullCoverageOverlay() {
        // only the full-coverage overlay hides the panes AND scratch, so its translucent background
        // reveals the window backing rather than the covered surfaces.
        let session = Session(initialCwd: "/repo")
        #expect(session.fullOverlayActive == false)
        session.overlayActive = true
        #expect(session.fullOverlayActive == true)
        session.overlaySizePercent = 80
        #expect(session.fullOverlayActive == false)
        session.overlayActive = false
        #expect(session.fullOverlayActive == false)
    }

    @Test func coverFlagsAcrossTheFourOverlaySlotStates() {
        let session = Session(initialCwd: "/repo")
        #expect(session.hudActive == false)
        #expect(session.fullOverlayActive == false)
        #expect(session.programOverlayActive == false)

        session.overlayActive = true
        session.overlaySizePercent = 40
        #expect(session.hudActive == false)
        #expect(session.fullOverlayActive == false)
        #expect(session.programOverlayActive == true)

        session.hudSpec = HudSpec(message: "gathering options")
        #expect(session.hudActive == true)
        #expect(session.fullOverlayActive == false)
        #expect(session.programOverlayActive == false)

        session.hudSpec = nil
        session.overlaySizePercent = nil
        #expect(session.hudActive == false)
        #expect(session.fullOverlayActive == true)
        #expect(session.programOverlayActive == true)
    }

    @Test func hudFlagsNeedTheSlotOccupied() {
        let session = Session(initialCwd: "/repo")
        session.hudSpec = HudSpec(message: "stale")
        #expect(session.hudActive == false)
        #expect(session.fullOverlayActive == false)
    }

    @Test func aSizelessHudStillCoversNothing() {
        // openHud always sets a percent; the defensive term keeps a HUD out of the full-cover path anyway,
        // since hiding the panes behind a message would defeat the passivity the whole feature is for.
        let session = Session(initialCwd: "/repo")
        session.overlayActive = true
        session.hudSpec = HudSpec(message: "working")
        #expect(session.hudActive == true)
        #expect(session.fullOverlayActive == false)
        #expect(session.programOverlayActive == false)
    }

    @Test func programOverlayActiveSpansBothCoverageVariantsButNeverAHud() {
        let session = Session(initialCwd: "/repo")
        #expect(session.programOverlayActive == false)
        session.overlayActive = true
        #expect(session.programOverlayActive == true)
        session.overlaySizePercent = 40
        #expect(session.programOverlayActive == true)
        session.hudSpec = HudSpec(message: "gathering options")
        #expect(session.programOverlayActive == false)
        session.hudSpec = nil
        #expect(session.programOverlayActive == true)
        session.overlayActive = false
        #expect(session.programOverlayActive == false)
    }

    @Test func paneRoleResolvesTokenToItsCurrentSlot() {
        let session = Session(initialCwd: "/repo")
        session.surface = FakeSurface(paneToken: "main-tok")
        session.splitSurface = FakeSurface(paneToken: "split-tok")
        session.scratchSurface = FakeSurface(paneToken: "scratch-tok")

        #expect(session.paneRole(forToken: "main-tok") == .left)
        #expect(session.paneRole(forToken: "split-tok") == .right)
        #expect(session.paneRole(forToken: "scratch-tok") == .scratch)
        // no match — the caller then falls back to the baked --pane role.
        #expect(session.paneRole(forToken: "") == nil)
        #expect(session.paneRole(forToken: "no-such-tok") == nil)
    }

    @Test func paneRoleFollowsAPromotedSurvivorAndReSplit() {
        // #199: a promoted survivor and the fresh helper that re-splits it were both baked with the SAME
        // stale `right` role, so only the stable token disambiguates them.
        let session = Session(initialCwd: "/repo")
        let survivor = FakeSurface(paneToken: "agent-tok")
        session.surface = survivor
        session.splitSurface = FakeSurface(paneToken: "helper-tok")

        #expect(session.paneRole(forToken: "agent-tok") == .left)
        #expect(session.paneRole(forToken: "helper-tok") == .right)
    }

    @Test func takePendingRestoreOverrideReturnsEachPaneValueOnce() {
        let session = Session(initialCwd: "/repo")
        session.pendingRestoreCommand = "claude --resume main"
        session.pendingSplitRestoreCommand = "tail -f /var/log/x"

        #expect(session.takePendingRestoreOverride(pane: .left) == "claude --resume main")
        #expect(session.pendingSplitRestoreCommand == "tail -f /var/log/x")
        #expect(session.takePendingRestoreOverride(pane: .right) == "tail -f /var/log/x")
        #expect(session.takePendingRestoreOverride(pane: .left) == nil)
        #expect(session.takePendingRestoreOverride(pane: .right) == nil)
    }

    @Test func takePendingRestoreOverrideIsNilWhenNothingPending() {
        let session = Session(initialCwd: "/repo")
        #expect(session.takePendingRestoreOverride(pane: .left) == nil)
        #expect(session.takePendingRestoreOverride(pane: .right) == nil)
    }

    @Test func takePendingRestoreOverrideReturnsEmptyStringAsAValue() {
        // "" is "pinned to nothing" — a real tri-state value the caller maps to a plain shell, so the
        // first take must return it rather than collapsing it to nil.
        let session = Session(initialCwd: "/repo")
        session.pendingRestoreCommand = ""
        session.pendingSplitRestoreCommand = ""
        #expect(session.takePendingRestoreOverride(pane: .left) == "")
        #expect(session.takePendingRestoreOverride(pane: .right) == "")
        #expect(session.takePendingRestoreOverride(pane: .left) == nil)
        #expect(session.takePendingRestoreOverride(pane: .right) == nil)
    }

    @Test func takePendingRestoreOverrideIgnoresTheScratchPane() {
        // the scratch terminal is never restored, so it has no override slot to take.
        let session = Session(initialCwd: "/repo")
        session.pendingRestoreCommand = "claude --resume main"
        #expect(session.takePendingRestoreOverride(pane: .scratch) == nil)
        #expect(session.takePendingRestoreOverride(pane: .left) == "claude --resume main")
    }

    @Test func clearPendingForegroundCommandsDropsBothCapturesAndKeepsTheRestorePins() {
        // what restore.clear needs: the launch parks captures in the pending slots until each surface
        // mounts, so clearing only the persisted fields would answer ok and still let them run. The
        // session.restore pins are sticky and must survive.
        let session = Session(initialCwd: "/repo")
        session.pendingForegroundCommand = ["tee", "/tmp/m"]
        session.pendingSplitForegroundCommand = ["tail", "-f", "/var/log/x"]
        session.restoreCommand = "claude --resume main"
        session.pendingRestoreCommand = session.restoreCommand

        session.clearPendingForegroundCommands()
        #expect(session.takePendingForegroundCommand(pane: .left) == nil)
        #expect(session.takePendingForegroundCommand(pane: .right) == nil)
        #expect(session.takePendingRestoreOverride(pane: .left) == "claude --resume main")
        #expect(session.restoreCommand == "claude --resume main")
    }

    @Test func clearCapturedForegroundCommandsDropsThePersistedAndPendingPairsTogether() {
        // what `restore.clear` and a non-last window close both need: the persisted pair is what a launch
        // reads, the pending pair is what an already-started launch is holding, so dropping one leaves the
        // other to replay. The session.restore pins are sticky and must survive.
        let session = Session(initialCwd: "/repo")
        session.foregroundCommand = ["tee", "/tmp/m"]
        session.splitForegroundCommand = ["tail", "-f", "/var/log/x"]
        session.pendingForegroundCommand = session.foregroundCommand
        session.pendingSplitForegroundCommand = session.splitForegroundCommand
        session.restoreCommand = "claude --resume main"
        session.pendingRestoreCommand = session.restoreCommand

        session.clearCapturedForegroundCommands()
        #expect(session.foregroundCommand == nil)
        #expect(session.splitForegroundCommand == nil)
        #expect(session.takePendingForegroundCommand(pane: .left) == nil)
        #expect(session.takePendingForegroundCommand(pane: .right) == nil)
        #expect(session.restoreCommand == "claude --resume main")
        #expect(session.takePendingRestoreOverride(pane: .left) == "claude --resume main")
    }

    @Test func clearPendingRestoreOverridesDropsBothPayloadsAndKeepsThePins() {
        // the same object comes back on undo, so an unconsumed payload must not survive the round trip —
        // while the persisted pins stay, to fire on the next launch.
        let session = Session(initialCwd: "/repo")
        session.restoreCommand = "claude --resume main"
        session.splitRestoreCommand = "tail -f /var/log/x"
        session.pendingRestoreCommand = session.restoreCommand
        session.pendingSplitRestoreCommand = session.splitRestoreCommand
        session.foregroundCommand = ["tee", "/tmp/m"]
        session.splitForegroundCommand = ["tail", "-f", "/var/log/x"]
        session.pendingForegroundCommand = session.foregroundCommand
        session.pendingSplitForegroundCommand = session.splitForegroundCommand

        session.clearPendingRestoreOverrides()
        #expect(session.takePendingRestoreOverride(pane: .left) == nil)
        #expect(session.takePendingRestoreOverride(pane: .right) == nil)
        #expect(session.takePendingForegroundCommand(pane: .left) == nil)
        #expect(session.takePendingForegroundCommand(pane: .right) == nil)
        #expect(session.restoreCommand == "claude --resume main")
        #expect(session.splitRestoreCommand == "tail -f /var/log/x")
        #expect(session.foregroundCommand == ["tee", "/tmp/m"])
        #expect(session.splitForegroundCommand == ["tail", "-f", "/var/log/x"])
    }

    @Test func takePendingRestoreOverrideLeavesThePersistedValueIntact() {
        // STICKY: consuming this launch's payload must not clear the persisted field, or it would fire
        // once and never again.
        let session = Session(initialCwd: "/repo")
        session.restoreCommand = "claude --resume main"
        session.splitRestoreCommand = "tail -f /var/log/x"
        session.pendingRestoreCommand = session.restoreCommand
        session.pendingSplitRestoreCommand = session.splitRestoreCommand

        _ = session.takePendingRestoreOverride(pane: .left)
        _ = session.takePendingRestoreOverride(pane: .right)
        #expect(session.restoreCommand == "claude --resume main")
        #expect(session.splitRestoreCommand == "tail -f /var/log/x")
    }

    @Test(arguments: [
        ("left", OverlayPane.left),
        ("primary", OverlayPane.left),
        ("right", OverlayPane.right),
        ("split", OverlayPane.right),
    ])
    func overlayPaneAcceptsBothSpellingsOfEachPane(name: String, expected: OverlayPane) {
        #expect(OverlayPane(controlName: name) == expected)
    }

    @Test(arguments: ["scratch", "overlay", "", "Left", "middle"])
    func overlayPaneRejectsAnythingButLeftOrRight(name: String) {
        #expect(OverlayPane(controlName: name) == nil)
    }

    @Test func rendersPaneCoversBothPanesWhileSplitIsShown() {
        let session = Session(initialCwd: "/repo")
        session.isSplit = true
        session.splitSurface = FakeSurface()
        #expect(session.rendersPane(.left))
        #expect(session.rendersPane(.right))
    }

    @Test func rendersPaneIsRightOnlyForAHiddenSplitWithFocus() {
        let session = Session(initialCwd: "/repo")
        session.hasSplit = true
        session.splitSurface = FakeSurface()
        session.splitFocused = true
        #expect(session.rendersPane(.left) == false)
        #expect(session.rendersPane(.right))
    }

    @Test func rendersPaneIsLeftOnlyWithoutASplitSurface() {
        // splitFocused without a split surface is the promoted-survivor window: the left pane is what
        // sessionDetail lays out, so a right overlay would never realize.
        let session = Session(initialCwd: "/repo")
        session.splitFocused = true
        #expect(session.rendersPane(.left))
        #expect(session.rendersPane(.right) == false)
    }

    @Test func rendersPaneIsLeftOnlyForAPlainSession() {
        let session = Session(initialCwd: "/repo")
        #expect(session.rendersPane(.left))
        #expect(session.rendersPane(.right) == false)
    }

    @Test func rendersPaneIsLeftOnlyForAHiddenSplitWithoutFocus() {
        let session = Session(initialCwd: "/repo")
        session.hasSplit = true
        session.splitSurface = FakeSurface()
        #expect(session.rendersPane(.left))
        #expect(session.rendersPane(.right) == false)
    }

    @Test func renderedPanesFollowsTheShapeTheDeckBranchesOn() {
        let session = Session(initialCwd: "/repo")
        #expect(session.renderedPanes == [.left])
        session.isSplit = true
        session.hasSplit = true
        session.splitSurface = FakeSurface()
        #expect(session.renderedPanes == [.left, .right])
        session.splitFocused = true
        session.isSplit = false
        #expect(session.renderedPanes == [.right])
    }

    @Test func dropUnrealizedPaneOverlaysRetiresOnlyTheStrandedSlot() {
        let session = Session(initialCwd: "/repo")
        let realized = FakeSurface()
        session.hasSplit = true
        session.splitSurface = FakeSurface()
        session.leftOverlay = PaneOverlay(command: "revdiff")   // its pane is rendered
        session.rightOverlay = PaneOverlay(command: "htop")     // un-rendered, never realized
        session.dropUnrealizedPaneOverlays()
        #expect(session.openPaneOverlays == [.left])

        // a REALIZED overlay on an un-rendered pane keeps its program: the surface unmounts and a re-show
        // remounts it.
        session.rightOverlay = PaneOverlay(command: "htop")
        session.rightOverlaySurface = realized
        session.dropUnrealizedPaneOverlays()
        #expect(session.openPaneOverlays == [.left, .right])
        #expect(realized.teardownCount == 0)
    }

    // the focus flip is the non-store way a pane stops being laid out: `session.focus left` on a hidden
    // split un-renders the right pane, and an overlay opened there before its surface realized would sit
    // active with no program forever.
    @Test func dropUnrealizedPaneOverlaysCoversAFocusFlipOnAHiddenSplit() {
        let session = Session(initialCwd: "/repo")
        session.hasSplit = true
        session.splitSurface = FakeSurface()
        session.splitFocused = true
        session.rightOverlay = PaneOverlay(command: "htop")
        session.dropUnrealizedPaneOverlays()
        #expect(session.rightOverlay?.command == "htop")

        session.splitFocused = false
        session.dropUnrealizedPaneOverlays()
        #expect(session.rightOverlay == nil)
    }

    // the deck parks its view in the surface slot BEFORE libghostty creates the terminal, so an occupied slot
    // is no proof a program started: that gap left `overlay result --pane` answering "overlay still running"
    // forever.
    @Test func dropUnrealizedPaneOverlaysRetiresASlotWhoseTerminalWasNeverCreated() {
        let session = Session(initialCwd: "/repo")
        let parked = FakeSurface()
        parked.isRealized = false
        session.hasSplit = true
        session.splitSurface = FakeSurface()
        session.splitFocused = true
        session.rightOverlay = PaneOverlay(command: "htop")
        session.rightOverlaySurface = parked

        session.splitFocused = false
        session.dropUnrealizedPaneOverlays()
        #expect(session.rightOverlay == nil)
        #expect(session.rightOverlaySurface == nil)
        #expect(parked.teardownCount == 1)
    }

    // the deck is not the only host: `overlay open --pane right` then `surface zoom show --target
    // surface:<id>:overlay-right` then focusing away tore the SELECTED zoom target down before the zoom
    // layer could mount and realize it, breaking the surfaces[]/surface zoom contract.
    @Test func dropUnrealizedPaneOverlaysSparesASlotTerminalZoomIsHosting() {
        let session = Session(initialCwd: "/repo")
        let windowID = UUID()
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        session.hasSplit = true
        session.splitSurface = FakeSurface()
        session.splitFocused = true
        session.rightOverlay = PaneOverlay(command: "htop")
        zoom.set(.on, target: .session(session.id, .overlayRight))

        session.splitFocused = false
        #expect(session.rendersPane(.right) == false)
        #expect(session.paneOverlayHosted(.right))
        session.dropUnrealizedPaneOverlays()
        #expect(session.rightOverlay?.command == "htop")

        // leaving zoom takes the last host away, so the still-unrealized slot is retired then.
        zoom.clear()
        #expect(session.paneOverlayHosted(.right) == false)
        session.dropUnrealizedPaneOverlays()
        #expect(session.rightOverlay == nil)
    }

    @Test func dropUnrealizedPaneOverlaysRetiresASlotZoomIsNotTargeting() {
        let session = Session(initialCwd: "/repo")
        let windowID = UUID()
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        session.hasSplit = true
        session.splitSurface = FakeSurface()
        session.splitFocused = true
        session.rightOverlay = PaneOverlay(command: "htop")
        // the PANE, not that pane's overlay, and another session's overlay slot: neither hosts this one.
        zoom.set(.on, target: .session(session.id, .split))
        session.splitFocused = false
        session.dropUnrealizedPaneOverlays()
        #expect(session.rightOverlay == nil)

        session.splitFocused = true
        session.rightOverlay = PaneOverlay(command: "htop")
        zoom.set(.on, target: .session(UUID(), .overlayRight))
        session.splitFocused = false
        session.dropUnrealizedPaneOverlays()
        #expect(session.rightOverlay == nil)
    }

    @Test func paneOverlayAccessorsReadEachSlotIndependently() {
        let session = Session(initialCwd: "/repo")
        let leftSurface = FakeSurface(), rightSurface = FakeSurface()
        #expect(session.paneOverlay(.left) == nil)
        #expect(session.openPaneOverlays.isEmpty)

        session.leftOverlay = PaneOverlay(command: "revdiff", cwd: "/a", backgroundColor: "#101010", wait: true)
        session.leftOverlaySurface = leftSurface
        #expect(session.paneOverlay(.left)?.command == "revdiff")
        #expect(session.paneOverlay(.left)?.wait == true)
        #expect(session.paneOverlay(.right) == nil)
        #expect(session.paneOverlaySurface(.left) === leftSurface)
        #expect(session.paneOverlaySurface(.right) == nil)
        #expect(session.openPaneOverlays == [.left])

        session.rightOverlay = PaneOverlay(command: "lazygit")
        session.rightOverlaySurface = rightSurface
        #expect(session.paneOverlay(.right)?.command == "lazygit")
        #expect(session.paneOverlaySurface(.right) === rightSurface)
        #expect(session.openPaneOverlays == [.left, .right])
    }

    @Test func focusedOverlayPaneIsNilWhenTheFocusedPaneHasNoOverlay() {
        let session = Session(initialCwd: "/repo")
        session.isSplit = true
        session.splitSurface = FakeSurface()
        session.rightOverlay = PaneOverlay(command: "revdiff")
        #expect(session.focusedOverlayPane == nil)
        session.splitFocused = true
        #expect(session.focusedOverlayPane == .right)
    }

    @Test func focusedOverlayPaneNeedsASplitSurfaceForRight() {
        let session = Session(initialCwd: "/repo")
        session.splitFocused = true
        session.leftOverlay = PaneOverlay(command: "revdiff")
        session.rightOverlay = PaneOverlay(command: "lazygit")
        #expect(session.focusedOverlayPane == .left)
        session.splitSurface = FakeSurface()
        #expect(session.focusedOverlayPane == .right)
    }

    // pins the shape `session.split --mode on` leaves before the lazy right surface exists: the right pane is
    // already laid out and focused, so the cover predicates must agree with what openPaneOverlay accepts.
    @Test func focusedOverlayPaneFollowsAShownSplitBeforeItsSurfaceRealizes() {
        let session = Session(initialCwd: "/repo")
        session.isSplit = true
        session.hasSplit = true
        session.splitFocused = true
        session.rightOverlay = PaneOverlay(command: "revdiff")

        #expect(session.focusedPane == .right)
        #expect(session.rendersPane(.right))
        #expect(session.focusedOverlayPane == .right)
        #expect(session.topmostSurface == nil, "an unrealized covering overlay leaves the retry to re-resolve")
    }

    @Test func focusedPaneAndRendersPaneNeverDisagreeAboutTheFocusedSide() {
        let session = Session(initialCwd: "/repo")
        for combination in 0..<8 {
            session.isSplit = combination & 1 != 0
            session.splitFocused = combination & 2 != 0
            session.splitSurface = combination & 4 != 0 ? FakeSurface() : nil
            #expect(session.rendersPane(session.focusedPane),
                    "the focused pane must always be one the deck lays out [\(combination)]")
        }
    }

    @Test func paneOverlayRoleResolvesTheSlotASurfaceCurrentlyOccupies() {
        let session = Session(initialCwd: "/repo")
        let left = FakeSurface(), right = FakeSurface(), stranger = FakeSurface()
        #expect(session.paneOverlayRole(of: left) == nil)

        session.leftOverlaySurface = left
        session.rightOverlaySurface = right
        #expect(session.paneOverlayRole(of: left) == .left)
        #expect(session.paneOverlayRole(of: right) == .right)
        #expect(session.paneOverlayRole(of: stranger) == nil)
    }

    // the promotion regression: the right pane overlay's surface MOVES into the left slot without being
    // rebuilt, so its callbacks must resolve `.left` from it or they act on a slot nothing occupies.
    @Test func promotePaneOverlayRetargetsTheMigratedSurfacesRole() {
        let session = Session(initialCwd: "/repo")
        let overlaySurface = FakeSurface()
        session.rightOverlay = PaneOverlay(command: "revdiff")
        session.rightOverlaySurface = overlaySurface
        session.rightOverlayExitCode = nil
        #expect(session.paneOverlayRole(of: overlaySurface) == .right)

        session.teardownPaneOverlay(.left)
        session.promotePaneOverlay()

        #expect(session.paneOverlayRole(of: overlaySurface) == .left)
        #expect(session.paneOverlay(.left)?.command == "revdiff")
        #expect(session.paneOverlaySurface(.left) === overlaySurface)
        #expect(session.openPaneOverlays == [.left])
        #expect(overlaySurface.teardownCount == 0, "promotion must not tear the migrating surface down")
    }

    @Test func focusedOverlayPaneIsLeftAfterAPromotion() {
        // the survivor moves into `surface` while `splitSurface` is nilled, so the migrated overlay reads
        // as the left pane's even before splitFocused settles.
        let session = Session(initialCwd: "/repo")
        session.splitFocused = true
        session.splitSurface = FakeSurface()
        session.rightOverlay = PaneOverlay(command: "revdiff")
        #expect(session.focusedOverlayPane == .right)

        session.surface = session.splitSurface
        session.splitSurface = nil
        session.leftOverlay = session.rightOverlay
        session.rightOverlay = nil
        #expect(session.focusedOverlayPane == .left)
    }

    @Test func topmostSurfaceRanksTheFocusedPaneOverlayBelowScratchAndTheSessionOverlay() {
        let session = Session(initialCwd: "/repo")
        let primary = FakeSurface(), scratch = FakeSurface(), overlay = FakeSurface(), leftOverlay = FakeSurface()
        session.surface = primary
        session.scratchSurface = scratch
        session.overlaySurface = overlay
        session.leftOverlay = PaneOverlay(command: "revdiff")
        session.leftOverlaySurface = leftOverlay
        #expect(session.topmostSurface === leftOverlay)
        session.scratchActive = true
        #expect(session.topmostSurface === scratch)
        session.overlayActive = true
        #expect(session.topmostSurface === overlay)
        session.overlayActive = false
        session.scratchActive = false
        session.leftOverlay = nil
        #expect(session.topmostSurface === primary)
    }

    @Test func topmostSurfaceIgnoresAnOverlayOnTheUnfocusedPane() {
        let session = Session(initialCwd: "/repo")
        let primary = FakeSurface(), split = FakeSurface(), rightOverlay = FakeSurface()
        session.surface = primary
        session.splitSurface = split
        session.isSplit = true
        session.rightOverlay = PaneOverlay(command: "lazygit")
        session.rightOverlaySurface = rightOverlay
        #expect(session.topmostSurface === primary)
        session.splitFocused = true
        #expect(session.topmostSurface === rightOverlay)
    }

    @Test func topmostSurfaceIsNilWhileACoveringPaneOverlayHasNotRealized() {
        let session = Session(initialCwd: "/repo")
        session.surface = FakeSurface()
        session.leftOverlay = PaneOverlay(command: "revdiff")
        #expect(session.topmostSurface == nil)
    }

    @Test func focusTargetRoutesThroughTheRequestedPanesOwnOverlay() {
        let session = Session(initialCwd: "/repo")
        let primary = FakeSurface(), split = FakeSurface(), rightOverlay = FakeSurface()
        session.surface = primary
        session.splitSurface = split
        session.isSplit = true
        session.rightOverlay = PaneOverlay(command: "lazygit")
        session.rightOverlaySurface = rightOverlay
        #expect(session.focusTarget(wantSplit: true) === rightOverlay)
        #expect(session.focusTarget(wantSplit: false) === primary)
    }

    @Test func focusTargetKeepsASessionWideCoverOverAPaneOverlay() {
        let session = Session(initialCwd: "/repo")
        let primary = FakeSurface(), split = FakeSurface(), scratch = FakeSurface(), leftOverlay = FakeSurface()
        session.surface = primary
        session.splitSurface = split
        session.isSplit = true
        session.scratchSurface = scratch
        session.leftOverlay = PaneOverlay(command: "revdiff")
        session.leftOverlaySurface = leftOverlay
        session.scratchActive = true
        #expect(session.focusTarget(wantSplit: false) === scratch)
        #expect(session.focusTarget(wantSplit: true) === scratch)
    }

    // the passivity property one layer below the deck's exemptions: every app focus-routing site reads
    // `topmostSurface`, so a HUD reachable through it takes first responder off the session it describes.
    @Test func topmostSurfaceSkipsAHudButNotTheProgramSharingItsSlot() {
        let session = Session(initialCwd: "/repo")
        let primary = FakeSurface(), scratch = FakeSurface(), overlay = FakeSurface()
        session.surface = primary
        session.scratchSurface = scratch
        session.overlaySurface = overlay
        session.overlayActive = true
        session.overlaySizePercent = 30
        session.hudSpec = HudSpec(message: "gathering options")

        #expect(session.topmostSurface === primary)
        session.scratchActive = true
        #expect(session.topmostSurface === scratch, "a HUD renders above the scratch but never owns focus")
        session.hudSpec = nil
        #expect(session.topmostSurface === overlay)
    }

    @Test func focusTargetReachesTheRequestedPaneUnderAHud() {
        let session = Session(initialCwd: "/repo")
        let primary = FakeSurface(), split = FakeSurface(), overlay = FakeSurface()
        session.surface = primary
        session.splitSurface = split
        session.isSplit = true
        session.overlaySurface = overlay
        session.overlayActive = true
        session.hudSpec = HudSpec(message: "gathering options")

        #expect(session.focusTarget(wantSplit: true) === split)
        #expect(session.focusTarget(wantSplit: false) === primary)
        session.hudSpec = nil
        #expect(session.focusTarget(wantSplit: true) === overlay, "a program overlay hides the requested pane")
    }

    @Test func onScreenSurfaceKeepsTheScratchUnderAHud() {
        let session = Session(initialCwd: "/repo")
        let primary = FakeSurface(), scratch = FakeSurface(), overlay = FakeSurface()
        session.surface = primary
        session.scratchSurface = scratch
        session.overlaySurface = overlay
        session.scratchActive = true
        session.overlayActive = true
        session.hudSpec = HudSpec(message: "gathering options")

        #expect(session.onScreenSurface === scratch, "session.text and ⌘F must not fall to the hidden pane")
        session.hudSpec = nil
        #expect(session.onScreenSurface === primary)
    }

    @Test func focusTargetIsNilWhileTheRequestedPanesOverlayHasNotRealized() {
        let session = Session(initialCwd: "/repo")
        session.surface = FakeSurface()
        session.splitSurface = FakeSurface()
        session.isSplit = true
        session.rightOverlay = PaneOverlay(command: "lazygit")
        #expect(session.focusTarget(wantSplit: true) == nil)
    }

    @Test func takePendingRestoreOverrideNeverReadsThePersistedValue() {
        // a persisted override with nothing armed (a mid-process window reload, a socket write during this
        // run) must not fire — the factory path can only reach the transient payload.
        let session = Session(initialCwd: "/repo")
        session.restoreCommand = "claude --resume main"
        session.splitRestoreCommand = "tail -f /var/log/x"
        #expect(session.takePendingRestoreOverride(pane: .left) == nil)
        #expect(session.takePendingRestoreOverride(pane: .right) == nil)
    }
}

private final class FakeSurface: TerminalSurface {
    var paneToken: String
    var teardownCount = 0
    /// Defaults to a live terminal, the state a surface parked in a session slot reaches a beat later; the
    /// stranded-slot cases set it false.
    var isRealized = true
    init(paneToken: String = "") { self.paneToken = paneToken }
    func teardown() { teardownCount += 1 }
    func promoteToPrimaryPane() {}
}
