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
        // effectiveCwd (new-pane seeding + AGTERM_SESSION_PWD) is NOT focus-aware.
        let session = Session(initialCwd: "/repo")
        session.currentCwd = "/repo/primary"
        session.isSplit = true
        session.splitFocused = true
        session.splitCwd = "/var/log"
        #expect(session.effectiveCwd == "/repo/primary")
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

    @Test func clearPendingRestoreOverridesDropsBothPayloadsAndKeepsThePins() {
        // the same object comes back on undo, so an unconsumed payload must not survive the round trip —
        // while the persisted pins stay, to fire on the next launch.
        let session = Session(initialCwd: "/repo")
        session.restoreCommand = "claude --resume main"
        session.splitRestoreCommand = "tail -f /var/log/x"
        session.pendingRestoreCommand = session.restoreCommand
        session.pendingSplitRestoreCommand = session.splitRestoreCommand

        session.clearPendingRestoreOverrides()
        #expect(session.takePendingRestoreOverride(pane: .left) == nil)
        #expect(session.takePendingRestoreOverride(pane: .right) == nil)
        #expect(session.restoreCommand == "claude --resume main")
        #expect(session.splitRestoreCommand == "tail -f /var/log/x")
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
    init(paneToken: String = "") { self.paneToken = paneToken }
    func teardown() {}
    func promoteToPrimaryPane() {}
}
