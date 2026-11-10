import agtermCore
import Foundation

extension ControlServer {
    /// Clear every open session's captured foreground command and persist, so the next launch restores plain
    /// shells. The live fields are usually already nil (consumed at restore); the SAVE is what wipes the
    /// on-disk copy from the last quit, closing the force-quit re-fire window. App-global like
    /// `keymap.reload`: no `--window` selector, every open window is cleared.
    ///
    /// Also disarms the PENDING capture slots, where a launch restore parks the argv until each surface
    /// mounts: the socket binds before the later windows' decks do, so a clear arriving in that gap would
    /// answer ok and then watch those windows run the commands anyway. The `session.restore` pins are
    /// deliberately untouched — they are sticky, and this command clears captures.
    func clearRestoreCommands() -> ControlResponse {
        for session in library.allOpenSessions() { session.clearCapturedForegroundCommands() }
        // the ack waits on the write for the same reason `restore.capture`'s does: the save IS the clear, and
        // the slots are not readable, so an ok over a failed write leaves a stale capture nothing can detect.
        guard library.saveAllOpenChecked() else {
            return ControlResponse(ok: false, error: "cleared every open pane but at least one window's save "
                + "failed; those windows keep their captured commands on disk until they save successfully")
        }
        return ControlResponse(ok: true)
    }

    /// The restore-mode policy: settings, this launch's request, and what it got.
    func readRestoreMode() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(restore: restoreStatus()))
    }

    /// Persist the mode for the NEXT launch; a pane is wrapped or not at creation, so this process keeps
    /// the mode it started with.
    func setRestoreMode(_ mode: RestoreMode) -> ControlResponse {
        guard settingsModel.setRestoreMode(mode) else {
            return ControlResponse(ok: false, error: "could not save the restore mode; settings keep "
                + settingsModel.settings.effectiveRestoreMode.rawValue)
        }
        return ControlResponse(ok: true, result: ControlResult(restore: restoreStatus()))
    }

    func restoreStatus() -> ControlRestoreStatus {
        let decision = GhosttyApp.shared.restoreLaunchDecision
        return ControlRestoreStatus(configured: settingsModel.settings.effectiveRestoreMode,
                                    requestedAtLaunch: decision.requested, active: decision.active,
                                    unavailableReason: decision.liveUnavailableReason)
    }

    /// Capture every open pane's live foreground command NOW, filling the same slots the quit-time capture
    /// fills, then persist them. The point is the exit that never runs `applicationWillTerminate`: a crash, a
    /// SIGKILL, a hard reset, or a restart that outruns the app's termination window. Run this from a
    /// scheduled job or a keybind and such an exit restores like a ⌘Q.
    ///
    /// App-global like `clearRestoreCommands`, its inverse over the same slots: no `--window` selector, every
    /// open window. Consumption stays one-shot and launch-only, so nothing here changes replay.
    ///
    /// Available only when rerun is configured for the next launch. It refuses in the other two modes,
    /// unlike `session.restore`, which saves future rerun policy with a note.
    func captureRestoreCommands() -> ControlResponse {
        let configuredMode = settingsModel.settings.effectiveRestoreMode
        guard configuredMode == .rerun else {
            return ControlResponse(ok: false, error: "restore.capture requires rerun mode; configured restore mode is "
                + configuredMode.rawValue)
        }
        let sessions = library.allOpenSessions()
        let captured = AppDelegate.captureForegroundCommands(
            sessions: sessions, zmxResolver: zmxForegroundResolver)
        // this command's whole claim is that the argv reached disk, so the ack waits on the write and not on
        // the assignment: `saveAllOpen` swallows the result, `saveAllOpenChecked` reports it.
        guard library.saveAllOpenChecked() else {
            return ControlResponse(ok: false, error: "captured \(captured) pane\(captured == 1 ? "" : "s") "
                + "but at least one window's save failed; failed windows keep their argv in memory until they "
                + "save successfully")
        }
        var result = ControlResult(count: captured)
        result.text = "captured \(captured) pane\(captured == 1 ? "" : "s")"
        return ControlResponse(ok: true, result: result)
    }
}
