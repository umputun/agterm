import Foundation
import Sparkle
import agtermCore

/// UpdateController owns Sparkle's updater. Only a build with `SUFeedURL` gets one, so a local build never
/// replaces itself with a published release.
@MainActor
final class UpdateController: NSObject {
    private var controller: SPUStandardUpdaterController?
    private(set) var flow = UpdateFlow()

    init(feed: String? = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) {
        super.init()
        guard let feed, !feed.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
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
