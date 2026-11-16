import Foundation
import Sparkle

/// UpdateController owns Sparkle's updater. Only a build with `SUFeedURL` gets one, so a local build never
/// replaces itself with a published release.
@MainActor
final class UpdateController {
    private let controller: SPUStandardUpdaterController?

    init(feed: String? = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) {
        guard let feed, !feed.isEmpty else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
