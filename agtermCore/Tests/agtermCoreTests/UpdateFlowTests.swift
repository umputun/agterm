import Testing
@testable import agtermCore

struct UpdateFlowTests {
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
