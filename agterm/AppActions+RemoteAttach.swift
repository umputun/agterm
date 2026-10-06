import Foundation
import agtermCore

/// RemoteAttaching is the part of the control server File ▸ Attach Remote drives. `AppActions` holds it
/// weakly: the server already owns the actions.
@MainActor
protocol RemoteAttaching: AnyObject {
    func remoteTree(host: String?) async -> ControlResponse
    func attachRemoteSession(host: String, session: String, window: String?) async -> ControlResponse
    func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse
    func closeHud(_ target: String?, window: String?) -> ControlResponse
    /// hudGeneration identifies the HUD now showing over `session`, nil when it shows none.
    func hudGeneration(session: String) -> Int?
}

extension ControlServer: RemoteAttaching {
    func hudGeneration(session: String) -> Int? {
        library.allOpenSessions().first { $0.id.uuidString == session && $0.hudActive }?.overlaySlotGeneration
    }
}

extension AppActions {
    static let remoteAttachErrorSeconds: Double = 5
    /// remoteAttachProgressSeconds makes a progress panel timed, so a soft-closed session drops it.
    static let remoteAttachProgressSeconds: Double = 30

    /// configuredRemotes is what `remotes.conf` lists; an unreadable file reads as none.
    var configuredRemotes: [RemoteEntry] { settingsModel?.remotes.entries ?? [] }

    /// attachRemote asks which configured machine to attach from, in the window's picker; a single entry
    /// needs no question.
    func attachRemote() {
        let remotes = configuredRemotes
        guard let windowID = library.activeWindowID, uiActionsEnabled(for: windowID), let first = remotes.first,
              let controller = PickRegistry.shared.controller(for: windowID) else { return }
        guard remotes.count > 1 else { return attachRemote(first.destination, in: windowID) }
        let items = remotes.map {
            ControlPickItem(id: $0.destination, label: $0.label, subtitle: $0.label == $0.destination ? nil : $0.destination)
        }
        Task {
            let pick = PendingPick(id: UUID().uuidString, items: items, prompt: "Attach from which Mac?")
            guard let picked = await controller.pick(pick), picked.result == .picked, let destination = picked.id else { return }
            attachRemote(destination, in: windowID)
        }
    }

    /// attachRemote lets the user pick one of `destination`'s sessions and attaches it in `windowID`,
    /// whichever window is frontmost by then.
    func attachRemote(_ destination: String, in windowID: WindowInfo.ID) {
        guard uiActionsEnabled(for: windowID), let remoteAttacher else { return }
        let hud = RemoteAttachHud(attacher: remoteAttacher,
                                  session: library.store(for: windowID)?.selectedSessionID?.uuidString,
                                  window: windowID.uuidString)
        Task {
            hud.progress("listing sessions on \(destination)…")
            let listing = await remoteAttacher.remoteTree(host: destination)
            guard listing.ok, let sessions = listing.result?.remote?.sessions else {
                hud.fail("\(destination): \(listing.error ?? "no answer")")
                return
            }
            guard !sessions.isEmpty, sessions.count <= ControlPickItem.maxItems else {
                hud.fail(sessions.isEmpty ? "nothing to attach on \(destination)" : "\(destination) offers too many sessions")
                return
            }
            hud.close()
            // the window may have closed during the ssh wait, and a controller no window renders would
            // never resolve the pick
            guard let controller = PickRegistry.shared.controller(for: windowID) else { return }
            let pick = PendingPick(id: UUID().uuidString, items: sessions.map(Self.remotePickItem),
                                   prompt: "Attach from \(destination)")
            guard let picked = await controller.pick(pick), picked.result == .picked, let session = picked.id else { return }
            hud.progress("attaching \(picked.label ?? session)…")
            let attached = await remoteAttacher.attachRemoteSession(host: destination, session: session,
                                                                    window: windowID.uuidString)
            if attached.ok {
                hud.close()
            } else {
                hud.fail(attached.error ?? "attach failed")
            }
        }
    }

    static func remotePickItem(_ session: ControlRemoteSession) -> ControlPickItem {
        let programs = session.panes.compactMap { $0.foreground?.first.map { ($0 as NSString).lastPathComponent } }
        let parts = ["\(session.windowName)/\(session.workspaceName)", session.context ?? "", session.cwd,
                     programs.joined(separator: " | ")]
        return ControlPickItem(id: session.id, label: session.name,
                               subtitle: parts.filter { !$0.isEmpty }.joined(separator: "  ·  "))
    }
}

/// RemoteAttachHud is the HUD an attach posts over the session it started from. A window with no session
/// has nowhere to put one, so a failure there falls back to the notification banner.
@MainActor
private final class RemoteAttachHud {
    private let attacher: any RemoteAttaching
    private let session: String?
    private let window: String
    /// owned is the HUD this attach opened; one another caller posted meanwhile is not its to close.
    private var owned: Int?

    init(attacher: any RemoteAttaching, session: String?, window: String) {
        self.attacher = attacher
        self.session = session
        self.window = window
    }

    func progress(_ text: String) {
        open(HudSpec(message: Self.message(text), spinner: .bar, hideAfter: AppActions.remoteAttachProgressSeconds))
    }

    func close() {
        guard let session, let owned, attacher.hudGeneration(session: session) == owned else { return }
        _ = attacher.closeHud(session, window: window)
        self.owned = nil
    }

    func fail(_ text: String) {
        if open(HudSpec(message: Self.message(text), hideAfter: AppActions.remoteAttachErrorSeconds)) { return }
        close()
        NotificationManager.shared.notifyCommandFailure(name: "Attach Remote", detail: text)
    }

    @discardableResult
    private func open(_ spec: HudSpec) -> Bool {
        guard let session, attacher.openHud(session, window: window, spec: spec).ok else { return false }
        owned = attacher.hudGeneration(session: session)
        return true
    }

    /// a direct `openHud` skips the dispatcher's validation, so remote text is cleaned and capped here.
    private static func message(_ text: String) -> String {
        CommandFailure.message(name: "Attach Remote", reason: text)
    }
}
