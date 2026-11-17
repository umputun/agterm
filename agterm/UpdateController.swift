import Foundation
import Observation
import Sparkle
import agtermCore

/// UpdateController owns Sparkle's updater. Only a build with `SUFeedURL` gets one, so a local build never
/// replaces itself with a published release.
@MainActor
@Observable
final class UpdateController: NSObject {
    static let shared = UpdateController()

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    private(set) var flow = UpdateFlow()

    init(feed: String? = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) {
        super.init()
        guard let feed, !feed.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private var iconShown: Bool {
        UpdateFlow.iconCanShow(elementShown: !GhosttyApp.shared.hiddenInterfaceElements.contains(.updates),
                               toolbarMode: GhosttyApp.shared.toolbarMode)
    }
}

extension UpdateController: SPUUpdaterDelegate {
    func updaterWillRelaunchApplication(_: SPUUpdater) {
        flow.installerWillRelaunch()
    }

    func updater(_: SPUUpdater, didFinishUpdateCycleFor _: SPUUpdateCheck, error _: (any Error)?) {
        flow.updateCycleEnded()
    }

    func updater(_: SPUUpdater, didAbortWithError _: any Error) {
        flow.updateCycleEnded()
    }
}

// Sparkle's standard user driver calls its delegate on the main thread.
extension UpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        UpdateFlow.sparkleShowsScheduledUpdate(iconShown: iconShown, immediateFocus: immediateFocus)
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate _: SUAppcastItem,
                                                   state _: SPUUserUpdateState) {
        flow.updateFound(sparkleShows: handleShowingUpdate)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate _: SUAppcastItem) {
        flow.reminderEnded()
    }

    func standardUserDriverWillFinishUpdateSession() {
        flow.reminderEnded()
    }
}
