import AppKit
import agtermCore

/// The one confirm path for Help ▸ Reset Live Sessions… and `zmx.reset`: refuses in a fixed order, shows
/// the dialog unless already confirmed, and holds the selection for the quit. The caller decides when to
/// terminate, the menu right away and the control server after its reply is written; `AppDelegate` reads
/// `pending` to skip the quit alert and to arm the marker.
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

    func request(confirmed: Bool) -> Request {
        guard menuVisible else { return .refused(.notLive) }
        guard let selection = selection() else { return .refused(.listingFailed) }
        guard selection.inventoryComplete else { return .refused(.inventoryIncomplete) }
        guard !selection.targets.isEmpty else { return .refused(.nothingToReset) }
        if !confirmed, !confirm(sessionCount: selection.sessionCount) { return .cancelled }
        pending = selection
        return .confirmed(selection)
    }

    func terminateIfPending() {
        guard pending != nil else { return }
        terminate()
    }

    private func confirm(sessionCount: Int) -> Bool {
        let text = LiveReset.dialogText(sessionCount: sessionCount)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.body
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
