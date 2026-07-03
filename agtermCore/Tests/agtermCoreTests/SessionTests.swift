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
        // a whitespace-only customName can only reach displayName via a hand-edited
        // snapshot (renameSession clears blanks to nil); it's trimmed and falls back
        // to the basename, matching renameSession's behavior.
        let session = Session(initialCwd: "/Users/user/dev/foo", customName: "   \t")
        #expect(session.displayName == "foo")
    }

    @Test func paddedCustomNameDisplaysTrimmed() {
        // a padded customName (e.g. from a hand-edited snapshot) displays trimmed,
        // matching the "trimmed before use" contract.
        let session = Session(initialCwd: "/Users/user/dev/foo", customName: "  build  ")
        #expect(session.displayName == "build")
    }

    @Test func oscTitleOverridesCwd() {
        // no manual rename: the terminal title (e.g. a remote host over SSH) wins over the cwd basename.
        let session = Session(initialCwd: "/Users/user/dev/foo")
        #expect(session.displayName == "foo")
        session.oscTitle = "user@web1: ~/srv"
        #expect(session.displayName == "user@web1: ~/srv")
    }

    @Test func customNameOverridesOscTitle() {
        // a manual rename outranks the terminal title.
        let session = Session(initialCwd: "/Users/user/dev/foo", customName: "build")
        session.oscTitle = "user@web1: ~/srv"
        #expect(session.displayName == "build")
    }

    @Test func blankOscTitleFallsBackToCwd() {
        // a whitespace-only or empty title is trimmed and falls through to the cwd basename.
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
        // named remote (SSH) session: the OSC title carries host/path the stale local cwd can't, and the
        // name occupies line 1, so the second line shows the title instead of the misleading local path.
        let session = Session(initialCwd: "/Users/user", customName: "web1")
        session.currentCwd = "/Users/user"
        session.oscTitle = "user@web1: ~"
        #expect(session.subtitleDetail == "user@web1: ~")
    }

    @Test func subtitleDetailUsesCwdForNamedSessionWithoutTitle() {
        // named local session: local auto-title is suppressed so oscTitle is nil; the second line is the cwd.
        let session = Session(initialCwd: "/Users/user/dev/foo", customName: "build")
        #expect(session.subtitleDetail == "/Users/user/dev/foo")
    }

    @Test func subtitleDetailUsesCwdWhenTitleIsAlreadyDisplayName() {
        // unnamed session: the OSC title is already line 1 (displayName), so the second line falls
        // through to the cwd rather than repeating it.
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
        // a whitespace-only title is trimmed away, so a named session with no real title shows the cwd.
        let session = Session(initialCwd: "/Users/user/dev/foo", customName: "build")
        session.oscTitle = "  \t"
        #expect(session.subtitleDetail == "/Users/user/dev/foo")
    }

    @Test func subtitleDetailTitleEqualToCustomNameFallsBackToCwd() {
        // edge: the remote titles the tab exactly what the user named the session, so the title would
        // just repeat line 1 — the second line falls through to the cwd.
        let session = Session(initialCwd: "/Users/user", customName: "web1")
        session.currentCwd = "/Users/user"
        session.oscTitle = "web1"
        #expect(session.subtitleDetail == "/Users/user")
    }

    @Test func subtitleDetailFollowsFocusedPane() {
        // focus-aware like displayName/focusedCwd: a named session's second line uses the focused pane's
        // title (the split pane's while it has focus, else the primary's).
        let session = Session(initialCwd: "/repo", customName: "build")
        session.isSplit = true
        session.oscTitle = "primary-title"
        session.splitTitle = "split-title"
        #expect(session.subtitleDetail == "primary-title")
        session.splitFocused = true
        #expect(session.subtitleDetail == "split-title")
    }

    @Test func effectiveCwdFallsBackToInitialUntilPwdReport() {
        // a restored session has no currentCwd until OSC 7 arrives; effectiveCwd is
        // initialCwd so git status refreshes immediately on launch/select.
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
        session.splitCwd = "/var/log"
        // split not focused: the primary pane drives name + cwd.
        #expect(session.displayName == "foo")
        #expect(session.focusedCwd == "/Users/user/dev/foo")
        session.splitFocused = true
        // split focused: the split pane drives name + cwd.
        #expect(session.displayName == "log")
        #expect(session.focusedCwd == "/var/log")
    }

    @Test func focusedPaneTitleWins() {
        let session = Session(initialCwd: "/repo")
        session.isSplit = true
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
        // split hidden (isSplit false) but the right pane is the one shown maximized + focused: the
        // title/sidebar follow the split pane, NOT the hidden primary. (guarded on splitFocused, not
        // isSplit — closeSplit resets the flag, so splitFocused is true only while the pane exists.)
        let session = Session(initialCwd: "/repo")
        session.currentCwd = "/repo/sub"
        session.splitSurface = FakeSurface()
        session.splitFocused = true
        session.splitCwd = "/var/log"
        #expect(session.focusedCwd == "/var/log")
        #expect(session.displayName == "log")
    }

    @Test func focusedCwdFallsBackUntilSplitReports() {
        // split focused but the split pane hasn't reported a cwd yet: fall back to the primary's.
        let session = Session(initialCwd: "/repo")
        session.currentCwd = "/repo/primary"
        session.isSplit = true
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
        // a fresh session shows no agent status (.idle, no blink) until the control channel sets one.
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
        // searchTotal nil (no query run yet): empty string, so the bar shows no counter.
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
        // the count can shrink under a stale selected index before the next SEARCH_SELECTED lands;
        // selected is clamped to total so it never reads "3 of 2".
        let session = Session(initialCwd: "/repo")
        session.searchTotal = 2
        session.searchSelected = 3
        #expect(session.searchDisplayText == "2 of 2")
    }

    @Test func searchFieldsAreNotPersistedAcrossSnapshot() {
        // the search state is ephemeral like overlay/scratch: a snapshot round-trip leaves it at
        // defaults on the restored session.
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
        // the pinned search owner is what the bar's needle/navigate/close drive, surviving a split focus
        // move (it is NOT re-resolved from `activeSurface`). it is weak: the session strongly owns its
        // panes, so it must not retain a surface.
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
        // no cover active: the active pane.
        #expect(session.topmostSurface === primary)
        // scratch shown: scratch is on top.
        session.scratchActive = true
        #expect(session.topmostSurface === scratch)
        // overlay over the scratch: the overlay wins (it renders above the scratch).
        session.overlayActive = true
        #expect(session.topmostSurface === overlay)
        // overlay closed, scratch still up: back to the scratch.
        session.overlayActive = false
        #expect(session.topmostSurface === scratch)
        // scratch hidden too: the active pane again.
        session.scratchActive = false
        #expect(session.topmostSurface === primary)
    }

    @Test func onScreenSurfaceIsCoveringScratchElseFocusedPane() {
        // the "what's visible" surface for session.text (no --pane) / session.search: the scratch when it
        // covers the panes (and no overlay is up), else the FOCUSED pane. An overlay falls back to the pane
        // (search/text don't target the ephemeral overlay), matching AppActions.searchTarget.
        let session = Session(initialCwd: "/repo")
        let primary = FakeSurface(), split = FakeSurface(), scratch = FakeSurface(), overlay = FakeSurface()
        session.surface = primary
        session.splitSurface = split
        session.scratchSurface = scratch
        session.overlaySurface = overlay
        // no cover, no split focus: the primary pane.
        #expect(session.onScreenSurface === primary)
        // split focused: the focused split pane, not the primary.
        session.splitFocused = true
        #expect(session.onScreenSurface === split)
        session.splitFocused = false
        // scratch shown (no overlay): the scratch is what's on screen.
        session.scratchActive = true
        #expect(session.onScreenSurface === scratch)
        // an overlay over the scratch falls back to the pane beneath, not the scratch or the overlay.
        session.overlayActive = true
        #expect(session.onScreenSurface === primary)
    }

    @Test func fullOverlayActiveOnlyForFullCoverageOverlay() {
        // the full-coverage overlay (no size) hides the session content beneath it — panes AND scratch —
        // so its translucent background reveals the window backing, never the covered surfaces.
        let session = Session(initialCwd: "/repo")
        // no overlay: nothing to hide behind.
        #expect(session.fullOverlayActive == false)
        // full-coverage overlay (no size percent): active.
        session.overlayActive = true
        #expect(session.fullOverlayActive == true)
        // floating (sized) overlay: draws an opaque panel over visible content, not a full cover.
        session.overlaySizePercent = 80
        #expect(session.fullOverlayActive == false)
        // overlay closed with a stale size percent lingering: still not a cover.
        session.overlayActive = false
        #expect(session.fullOverlayActive == false)
    }
}

private final class FakeSurface: TerminalSurface {
    func teardown() {}
}
