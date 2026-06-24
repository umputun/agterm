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
}

private final class FakeSurface: TerminalSurface {
    func teardown() {}
}
