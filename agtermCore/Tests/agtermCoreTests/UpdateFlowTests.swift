import Testing
@testable import agtermCore

struct UpdateFlowTests {
    @Test(arguments: [
        (UpdateFlow.Phase.idle, true, UpdateCheck.Decision.probe),
        (.idle, false, .busy),
        (.checking, true, .busy),
        (.checking, false, .busy),
        (.offering, true, .focus),
        (.offering, false, .focus),
    ])
    func updateCheckDecidesFromThePhaseAndSparkle(phase: UpdateFlow.Phase, sparkleCanCheck: Bool, expected: UpdateCheck.Decision) {
        #expect(UpdateCheck.decide(phase: phase, sparkleCanCheck: sparkleCanCheck) == expected)
    }

    @Test func updateCheckOutcomePrefersAFindThenANoUpdateAnswer() {
        #expect(UpdateCheck.outcome(found: "9.9.9", notFound: false, error: "x") == .found(version: "9.9.9"))
        #expect(UpdateCheck.outcome(found: nil, notFound: true, error: "no update") == .none)
        #expect(UpdateCheck.outcome(found: nil, notFound: false, error: "offline") == .failed("offline"))
        #expect(UpdateCheck.outcome(found: nil, notFound: false, error: nil) == .none)
    }

    @Test func updateCheckRepliesNameTheMacThatChecks() {
        #expect(UpdateCheck.reply(.found(version: "9.9.9"), host: "umbp")
            == ControlResponse(ok: true, result: ControlResult(text: "agterm 9.9.9 is available on umbp; opening the update window")))
        #expect(UpdateCheck.reply(.none, host: "umbp")
            == ControlResponse(ok: true, result: ControlResult(text: "no update offered on umbp")))
        #expect(UpdateCheck.reply(.failed("offline"), host: "umbp")
            == ControlResponse(ok: false, error: "update check failed on umbp: offline"))
        #expect(UpdateCheck.focusReply(host: "umbp")
            == ControlResponse(ok: true, result: ControlResult(text: "update window opened on umbp")))
        #expect(UpdateCheck.refusal(UpdateCheck.noFeed)
            == ControlResponse(ok: false, error: "update checks are off: this build has no update feed"))
        #expect(!UpdateCheck.hostName.isEmpty)
        #expect(!UpdateCheck.hostName.hasSuffix(".local"))
    }

    @Test func aReservedCheckStaysBusyUntilItsCycleEnds() {
        var flow = UpdateFlow()
        flow.reserveCheck()
        flow.sessionStarted()
        #expect(flow.phase == .checking)
        flow.updateCycleEnded()
        #expect(flow.phase == .idle)
    }

    @Test func aBackgroundDownloadStaysBusyWithoutAnOffer() {
        var flow = UpdateFlow()
        flow.sessionStarted()
        #expect(flow.phase == .checking)
    }

    @Test func anOfferShownBySparkleOrTheIconIsOffering() {
        var shown = UpdateFlow()
        shown.sessionStarted()
        shown.updateFound(sparkleShows: true)
        #expect(shown.phase == .offering)
        #expect(!shown.reminderPending)

        var reminded = UpdateFlow()
        reminded.updateFound(sparkleShows: false)
        reminded.sessionStarted()
        #expect(reminded.phase == .offering)
        #expect(reminded.reminderPending)
    }

    @Test func quitWithoutAnUpdateGetsTheQuitAlert() {
        #expect(UpdateFlow().quitAlert(openWindows: 2) == .quit)
    }

    @Test func quitWithNoWindowsTerminatesWithoutAnAlert() {
        var flow = UpdateFlow()
        #expect(flow.quitAlert(openWindows: 0) == .none)
        flow.installerWillRelaunch()
        #expect(flow.quitAlert(openWindows: 0) == .none)
    }

    @Test func updateQuitGetsTheRestartAlert() {
        var flow = UpdateFlow()
        flow.installerWillRelaunch()
        #expect(flow.quitAlert(openWindows: 1) == .restart)
    }

    @Test func retryAfterLaterGetsTheRestartAlertAgain() {
        var flow = UpdateFlow()
        flow.installerWillRelaunch()
        #expect(flow.quitAlert(openWindows: 1) == .restart)
        #expect(flow.quitAlert(openWindows: 1) == .restart)
        #expect(flow.relaunchPending)
    }

    @Test func ordinaryQuitAfterTheUpdateCycleEndsGetsTheQuitAlert() {
        var flow = UpdateFlow()
        flow.installerWillRelaunch()
        flow.updateCycleEnded()
        #expect(flow.quitAlert(openWindows: 1) == .quit)
        #expect(!flow.relaunchPending)
    }

    @Test func scheduledFindLeftToTheIconSetsTheReminder() {
        var flow = UpdateFlow()
        flow.updateFound(sparkleShows: false)
        #expect(flow.reminderPending)
        #expect(flow.showsIcon(elementShown: true))
    }

    @Test func findSparkleShowsSetsNoReminder() {
        var flow = UpdateFlow()
        flow.updateFound(sparkleShows: true)
        #expect(!flow.reminderPending)
        #expect(!flow.showsIcon(elementShown: true))
    }

    @Test func attentionOrSessionEndClearsTheReminder() {
        var flow = UpdateFlow()
        flow.updateFound(sparkleShows: false)
        flow.reminderEnded()
        #expect(!flow.showsIcon(elementShown: true))
        flow.updateFound(sparkleShows: false)
        flow.updateCycleEnded()
        #expect(!flow.showsIcon(elementShown: true))
    }

    @Test func hiddenElementHidesTheIconWhileTheReminderWaits() {
        var flow = UpdateFlow()
        flow.updateFound(sparkleShows: false)
        #expect(!flow.showsIcon(elementShown: false))
        #expect(flow.reminderPending)
    }

    @Test(arguments: [
        (true, ToolbarMode.compact, true),
        (true, .normal, true),
        (true, .hidden, false),
        (false, .compact, false),
    ])
    func iconCanShowOnlyWithTheElementAndATitleBar(elementShown: Bool, toolbarMode: ToolbarMode, canShow: Bool) {
        #expect(UpdateFlow.iconCanShow(elementShown: elementShown, toolbarMode: toolbarMode) == canShow)
    }

    @Test func hiddenTitleBarLeavesAScheduledFindToSparkle() {
        let iconShown = UpdateFlow.iconCanShow(elementShown: true, toolbarMode: .hidden)
        #expect(UpdateFlow.sparkleShowsScheduledUpdate(iconShown: iconShown, immediateFocus: false))
    }

    @Test(arguments: [
        (true, false, false),
        (true, true, true),
        (false, false, true),
        (false, true, true),
    ])
    func sparkleShowsAScheduledFindOnlyWithoutTheIconOrInImmediateFocus(iconShown: Bool, immediateFocus: Bool, sparkleShows: Bool) {
        #expect(UpdateFlow.sparkleShowsScheduledUpdate(iconShown: iconShown, immediateFocus: immediateFocus) == sparkleShows)
    }
}
