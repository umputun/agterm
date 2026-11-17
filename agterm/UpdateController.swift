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
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    private(set) var flow = UpdateFlow()
    /// canCheck mirrors Sparkle's `canCheckForUpdates` for the menu item and the title-bar icon. Sparkle sets it
    /// again once a menu check shows its progress, so it does not mean no check is running.
    private(set) var canCheck = false
    @ObservationIgnored private var probe: Probe?
    /// windowPending holds the reservation from a silent find until Sparkle has rescheduled its next check, which
    /// briefly marks a session running; a window opened before that is refused.
    @ObservationIgnored private var windowPending = false

    private struct Probe {
        let continuation: CheckedContinuation<UpdateCheck.Outcome, Never>
        var found: String?
        var notFound = false
        var error: String?
    }

    init(feed: String? = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) {
        super.init()
        guard let feed, !feed.isEmpty else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor in self?.canCheck = canCheck }
        }
    }

    var isAvailable: Bool { controller != nil }

    var status: ControlUpdateStatus? {
        controller.map {
            ControlUpdateStatus(automaticChecks: $0.updater.automaticallyChecksForUpdates,
                                lastCheck: $0.updater.lastUpdateCheckDate?.timeIntervalSince1970)
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// checkFromControl answers `update.check`: it brings up an offer already shown, or asks the feed with no UI
    /// and opens Sparkle's window only for a find, so a script never raises Sparkle's modal no-update alert.
    func checkFromControl() async -> ControlResponse {
        let host = UpdateCheck.hostName
        guard let updater = controller?.updater else { return UpdateCheck.refusal(UpdateCheck.noFeed) }
        switch UpdateCheck.decide(phase: flow.phase, sparkleCanCheck: updater.canCheckForUpdates) {
        case .busy:
            return UpdateCheck.refusal(UpdateCheck.busy)
        case .focus:
            controller?.checkForUpdates(nil)
            return UpdateCheck.focusReply(host: host)
        case .probe:
            flow.reserveCheck()
            let outcome = await withCheckedContinuation { continuation in
                probe = Probe(continuation: continuation)
                updater.checkForUpdateInformation()
            }
            return UpdateCheck.reply(outcome, host: host)
        }
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

    func updater(_: SPUUpdater, mayPerform _: SPUUpdateCheck) throws {
        flow.sessionStarted()
    }

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        probe?.found = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_: SPUUpdater, error _: any Error) {
        probe?.notFound = true
    }

    func updater(_: SPUUpdater, didFinishUpdateCycleFor check: SPUUpdateCheck, error: (any Error)?) {
        guard check == .updateInformation, let finished = probe else {
            flow.updateCycleEnded()
            return
        }
        probe = nil
        let outcome = UpdateCheck.outcome(found: finished.found, notFound: finished.notFound,
                                          error: finished.error ?? error?.localizedDescription)
        if case .found = outcome {
            windowPending = true
        } else {
            flow.updateCycleEnded()
        }
        finished.continuation.resume(returning: outcome)
    }

    func updater(_: SPUUpdater, willScheduleUpdateCheckAfterDelay _: TimeInterval) {
        openPendingWindow()
    }

    func updaterWillNotScheduleUpdateCheck(_: SPUUpdater) {
        openPendingWindow()
    }

    private func openPendingWindow() {
        guard windowPending else { return }
        windowPending = false
        DispatchQueue.main.async { [weak self] in
            self?.controller?.checkForUpdates(nil)
        }
    }

    func updater(_: SPUUpdater, didAbortWithError error: any Error) {
        guard probe == nil else {
            probe?.error = error.localizedDescription
            return
        }
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
