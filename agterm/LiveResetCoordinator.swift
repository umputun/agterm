import AppKit
import agtermCore

/// The one confirm path for Help ▸ Reset Live Sessions… and `zmx.reset`: refuses in a fixed order, shows
/// the dialog unless already confirmed, and holds the selection for the quit. The caller decides when to
/// terminate, the menu right away and the control server after its reply is written; `AppDelegate` reads
/// `armablePending` to skip the quit alert and to arm the marker.
@MainActor
final class LiveResetCoordinator {
    enum Refusal: Equatable {
        case notLive
        case listingFailed
        case inventoryIncomplete
        case nothingToReset

        var message: String {
            switch self {
            case .notLive: "zmx.reset requires Live sessions mode both configured and active for this launch"
            case .listingFailed: "zmx.reset could not read the live session list"
            case .inventoryIncomplete: "zmx.reset refused: the pane inventory is incomplete"
            case .nothingToReset: "zmx.reset found no live session to reset"
            }
        }

        var userMessage: String {
            switch self {
            case .notLive: "Reset Live Sessions needs Live sessions mode for this launch and the next."
            case .listingFailed: "The live session list could not be read. Nothing was reset."
            case .inventoryIncomplete: "Not every saved window could be read, so nothing was reset."
            case .nothingToReset: "Every live session is already supervised. There is nothing to reset."
            }
        }
    }

    enum Request: Equatable {
        case refused(Refusal)
        case cancelled
        case confirmed(LiveReset.Selection)
    }

    private let settingsModel: SettingsModel
    /// The control server's join of claims and daemons; nil refuses as a failed listing.
    var selection: () -> LiveReset.Selection?
    /// The mode this process launched with; injectable so a hosted test can stage the Live gate.
    var activeMode: () -> RestoreMode
    /// How a confirmed reset ends the process; injectable so a hosted test can count it instead.
    var terminate: () -> Void
    /// The dialog, given the session count; injectable so a hosted test can answer it.
    var confirm: @MainActor (Int) -> Bool = LiveResetCoordinator.confirmAlert
    /// How a menu refusal reaches the user; injectable so a hosted test can read it.
    var presentRefusal: @MainActor (Refusal) -> Void = LiveResetCoordinator.refusalAlert
    private(set) var pending: LiveReset.Selection?

    init(settingsModel: SettingsModel, selection: @escaping () -> LiveReset.Selection?,
         activeMode: @escaping () -> RestoreMode = { GhosttyApp.shared.launchRestoreMode },
         terminate: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.settingsModel = settingsModel
        self.selection = selection
        self.activeMode = activeMode
        self.terminate = terminate
    }

    var menuVisible: Bool {
        LiveReset.menuVisible(configured: settingsModel.settings.effectiveRestoreMode, active: activeMode())
    }

    /// The confirmed selection while Live is still both the configured and the launched mode. A mode
    /// change after confirmation makes the next launch unable to suppress survivors, so the reset is
    /// neither armed nor allowed to skip the quit alert.
    var armablePending: LiveReset.Selection? {
        menuVisible ? pending : nil
    }

    func request(confirmed: Bool) -> Request {
        guard menuVisible else { return .refused(.notLive) }
        guard let selection = selection() else { return .refused(.listingFailed) }
        guard selection.inventoryComplete else { return .refused(.inventoryIncomplete) }
        guard !selection.targets.isEmpty else { return .refused(.nothingToReset) }
        if !confirmed, !confirm(selection.sessionCount) { return .cancelled }
        pending = selection
        return .confirmed(selection)
    }

    /// The Help item: a refusal is shown, a cancel is silent, a confirmation quits.
    func runFromMenu() {
        switch request(confirmed: false) {
        case .refused(let refusal): presentRefusal(refusal)
        case .cancelled: break
        case .confirmed: terminateIfPending()
        }
    }

    func terminateIfPending() {
        guard armablePending != nil else { return }
        terminate()
    }

    private static func confirmAlert(sessionCount: Int) -> Bool {
        let text = LiveReset.dialogText(sessionCount: sessionCount)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.body
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func refusalAlert(_ refusal: Refusal) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Reset Live Sessions"
        alert.informativeText = refusal.userMessage
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
