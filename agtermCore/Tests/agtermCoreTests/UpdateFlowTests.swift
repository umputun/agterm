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
}
