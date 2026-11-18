import Foundation
import agtermCore

/// RemoteOrigin is what a host serves remote windows from, as its `version` and `window list` tell.
enum RemoteOrigin {
    case mac([ControlWindowNode])
    /// server is agterm-server, or an agterm that serves no window; its window opens and reports why.
    case server
    case unanswered
    case failed(String)
}

/// RemoteAttaching is the part of the control server File ▸ Attach Remote drives. `AppActions` holds it
/// weakly: the server already owns the actions.
@MainActor
protocol RemoteAttaching: AnyObject {
    func remoteTree(host: String?) async -> ControlResponse
    func remoteOrigin(host: String) async -> RemoteOrigin
    func attachRemoteSession(host: String, session: String, window: String?) async -> ControlResponse
    func attachRemoteGroup(host: String, session: String, window: String?) async -> ControlResponse
    func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse
    func closeHud(_ target: String?, window: String?) -> ControlResponse
    /// hudGeneration identifies the HUD now showing over `session`, nil when it shows none.
    func hudGeneration(session: String) -> Int?
    func createRemoteCompanion(_ request: RemoteCompanionRequest, of rowID: UUID, in store: AppStore, select: Bool,
                               progress: (String) -> Void) async -> ControlResponse
    func remoteSessionOrigin(host: String) async -> RemoteSessionOrigin
    func createRemoteSession(_ request: RemoteSessionCreate, origin: RemoteSessionCreate.Origin,
                             destination: RemoteSessionDestination, progress: (String) -> Void) async -> ControlResponse
    /// attachedRoute is how `request` runs on its row's origin when the row is attached from another host; nil otherwise.
    func attachedRoute(_ request: ControlRequest) -> RemoteRoute?
    func runRemoteRoute(_ route: RemoteRoute) async -> ControlResponse
    func reopenAttached(_ id: UUID, window: String?) async -> ControlResponse
    func undoOriginClose(_ undo: AttachedUndo, window: String) async -> ControlResponse
}

extension ControlServer: RemoteAttaching {
    func hudGeneration(session: String) -> Int? {
        library.allOpenSessions().first { $0.id.uuidString == session && $0.hudActive }?.overlaySlotGeneration
    }
}

extension AppActions {
    /// forwardAttached sends a GUI action on a row attached from another host to its origin, showing the ssh wait and a
    /// failure in a HUD over the row; false when `id` is not such a row, which then runs here as before.
    func forwardAttached(_ request: ControlRequest, row id: UUID, in store: AppStore, action: String) -> Bool {
        guard let remoteAttacher, let row = store.session(withID: id), let origin = AttachedOrigin(row),
              let route = remoteAttacher.attachedRoute(request) else { return false }
        guard let windowID = library.windowID(for: store) else { return true }
        let hud = RemoteAttachHud(attacher: remoteAttacher, session: id.uuidString, window: windowID.uuidString, action: action)
        if case .refused(let refusal) = route {
            hud.fail(refusal.error ?? "\(action) is not available here")
            return true
        }
        hud.progress("asking \(origin.host)…")
        Task {
            let reply = await remoteAttacher.runRemoteRoute(route)
            if reply.ok {
                hud.close()
                store.noteUserActivity()
            } else {
                hud.fail(reply.error ?? "\(action) did not reach \(origin.host)")
            }
        }
        return true
    }

    static let remoteAttachErrorSeconds: Double = 5
    /// remoteAttachProgressSeconds makes a progress panel timed, so a soft-closed session drops it.
    static let remoteAttachProgressSeconds: Double = 30

    /// configuredRemotes is what `remotes.conf` lists; an unreadable file reads as none.
    var configuredRemotes: [RemoteEntry] { settingsModel?.remotes.entries ?? [] }

    /// attachRemote asks which configured machine to attach from, in the window's picker; a single entry
    /// needs no question.
    func attachRemote() {
        guard let windowID = library.activeWindowID else { return }
        pickRemote(prompt: "Attach from which Mac?", in: windowID) { [weak self] in self?.attachRemote($0, in: windowID) }
    }

    /// openRemoteWindow asks which configured machine to show, then opens its window or raises the one already
    /// showing it; a Mac with several open windows is asked which.
    func openRemoteWindow() {
        guard let windowID = library.activeWindowID else { return }
        pickRemote(prompt: "Open a window for which host?", in: windowID) { [weak self] host in
            self?.openRemoteWindow(host, in: windowID)
        }
    }

    func openRemoteWindow(_ host: String, in windowID: WindowInfo.ID) {
        guard let remoteAttacher, let openWindow else { return }
        let hud = RemoteAttachHud(attacher: remoteAttacher, session: library.store(for: windowID)?.selectedSessionID?.uuidString,
                                  window: windowID.uuidString, action: "Open Remote Window")
        Task {
            hud.progress("asking \(host) for its windows…")
            let origin = await remoteAttacher.remoteOrigin(host: host)
            let windows: [ControlWindowNode]
            switch origin {
            case .failed(let reason):
                hud.fail(reason)
                return
            case .server, .unanswered:
                hud.close()
                openWindow(library.newRemoteWindow(host: host).id)
                return
            case .mac(let listed):
                windows = RemoteOriginWindow.offered(listed)
            }
            guard let first = windows.first else {
                hud.fail("\(host) has no open window")
                return
            }
            hud.close()
            guard let chosen = windows.count == 1
                    ? first : await pickOriginWindow(windows, prompt: "Open which window of \(host)?", in: windowID),
                  let id = UUID(uuidString: chosen.id) else { return }
            openWindow(library.newRemoteWindow(host: host, originWindow: id, originName: chosen.name).id)
        }
    }

    /// newRemoteSession asks which configured host to create a session on and attaches it into the workspace that was
    /// current when the action ran, whatever is selected by the time the picks and ssh waits end.
    func newRemoteSession() {
        guard let windowID = library.activeWindowID, let store = library.store(for: windowID),
              let workspace = store.currentWorkspaceID,
              let name = store.workspaces.first(where: { $0.id == workspace })?.name else { return }
        let destination = RemoteSessionDestination(store: store, workspace: workspace, name: name)
        pickRemote(prompt: "New session on which host?", in: windowID) { [weak self] host in
            self?.newRemoteSession(on: host, into: destination, in: windowID)
        }
    }

    func newRemoteSession(on host: String, into destination: RemoteSessionDestination, in windowID: WindowInfo.ID) {
        guard uiActionsEnabled(for: windowID), let remoteAttacher else { return }
        let hud = RemoteAttachHud(attacher: remoteAttacher, session: destination.store.selectedSessionID?.uuidString,
                                  window: windowID.uuidString, action: "New Remote Session")
        Task {
            hud.progress("asking \(host) what it runs…")
            let origin: RemoteSessionCreate.Origin
            switch await remoteAttacher.remoteSessionOrigin(host: host) {
            case .failed(let reason):
                hud.fail(reason)
                return
            case .server:
                origin = .server
            case .mac(let listed):
                let windows = RemoteOriginWindow.offered(listed)
                guard let first = windows.first else {
                    hud.fail("\(host) has no open window")
                    return
                }
                hud.close()
                guard let chosen = windows.count == 1
                        ? first : await pickOriginWindow(windows, prompt: "New session in which window of \(host)?", in: windowID)
                else { return }
                origin = .mac(window: chosen.id)
            }
            let reply = await remoteAttacher.createRemoteSession(RemoteSessionCreate(host: host), origin: origin,
                                                                 destination: destination) { hud.progress($0) }
            if reply.ok {
                hud.close()
                return
            }
            hud.fail(reply.error ?? "no session was created on \(host)")
        }
    }

    private func pickOriginWindow(_ windows: [ControlWindowNode], prompt: String, in windowID: WindowInfo.ID) async -> ControlWindowNode? {
        // the window may have closed during the ssh wait, and a controller no window renders would never resolve the pick
        guard let controller = PickRegistry.shared.controller(for: windowID) else { return nil }
        let items = windows.map { ControlPickItem(id: $0.id, label: $0.name) }
        let pick = PendingPick(id: UUID().uuidString, items: items, prompt: prompt)
        guard let picked = await controller.pick(pick), picked.result == .picked else { return nil }
        return windows.first { $0.id == picked.id }
    }

    /// pickRemote asks for one `remotes.conf` entry in `windowID`'s picker, skipping the question for one entry.
    private func pickRemote(prompt: String, in windowID: WindowInfo.ID, then use: @escaping (String) -> Void) {
        let remotes = configuredRemotes
        guard uiActionsEnabled(for: windowID), let first = remotes.first,
              let controller = PickRegistry.shared.controller(for: windowID) else { return }
        guard remotes.count > 1 else { return use(first.destination) }
        let items = remotes.map {
            ControlPickItem(id: $0.destination, label: $0.label, subtitle: $0.label == $0.destination ? nil : $0.destination)
        }
        Task {
            let pick = PendingPick(id: UUID().uuidString, items: items, prompt: prompt)
            guard let picked = await controller.pick(pick), picked.result == .picked, let destination = picked.id else { return }
            use(destination)
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
            // a page companion attaches only under its parent's row, which the picker has no place for
            guard listing.ok, let sessions = listing.result?.remote?.sessions.filter({ $0.content == nil || $0.parent == nil }) else {
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
            let names = Dictionary(sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let items = sessions.map { Self.remotePickItem($0, parentName: $0.parent.flatMap { names[$0] }) }
            let pick = PendingPick(id: UUID().uuidString, items: items, prompt: "Attach from \(destination)")
            guard let picked = await controller.pick(pick), picked.result == .picked, let session = picked.id else { return }
            hud.progress("attaching \(picked.label ?? session)…")
            // a top-level pick always asks for the group: the attach reads the origin again, so membership comes
            // from that fresh read rather than the listing the picker showed
            let topLevel = sessions.first { $0.id == session }?.parent == nil
            let attached = topLevel
                ? await remoteAttacher.attachRemoteGroup(host: destination, session: session, window: windowID.uuidString)
                : await remoteAttacher.attachRemoteSession(host: destination, session: session, window: windowID.uuidString)
            if attached.ok {
                hud.close()
                return
            }
            // a partial group attach selected its new parent row, so the report goes there
            if let parent = attached.result?.id { hud.move(to: parent) }
            hud.fail(attached.error ?? "attach failed")
        }
    }

    /// remotePickItem labels a companion `parent › name` as `AppStore.listLabel` does, or by its bare name when its
    /// parent is not in the listing.
    static func remotePickItem(_ session: ControlRemoteSession, parentName: String?) -> ControlPickItem {
        let programs = session.panes.compactMap { $0.foreground?.first.map { ($0 as NSString).lastPathComponent } }
        let parts = ["\(session.windowName)/\(session.workspaceName)", session.context ?? "", session.cwd,
                     programs.joined(separator: " | ")]
        return ControlPickItem(id: session.id, label: parentName.map { "\($0) › \(session.name)" } ?? session.name,
                               subtitle: parts.filter { !$0.isEmpty }.joined(separator: "  ·  "),
                               status: session.status, statusColor: session.statusColor,
                               statusShape: session.statusShape)
    }
}

/// RemoteAttachHud owns an attach's progress and error panels, with notification fallback. It opens a panel only into
/// a slot that is empty, holds its own panel, or holds an error panel an earlier one left; a running operation's
/// progress and a HUD a script or agent posted stay, and a failure then goes to the notification.
@MainActor
final class RemoteAttachHud {
    private let attacher: any RemoteAttaching
    private var session: String?
    private let window: String
    private let action: String
    /// owned is the HUD this attach opened; one another caller posted meanwhile is not its to close.
    private var owned: Int?
    /// failed is the error panel a RemoteAttachHud last opened over each session, which a later one may replace.
    private static var failed: [String: Int] = [:]

    init(attacher: any RemoteAttaching, session: String?, window: String, action: String = "Attach Remote") {
        self.attacher = attacher
        self.session = session
        self.window = window
        self.action = action
    }

    func progress(_ text: String) {
        open(HudSpec(message: message(text), spinner: .bar, hideAfter: AppActions.remoteAttachProgressSeconds), error: false)
    }

    func close() {
        guard let session, let owned, attacher.hudGeneration(session: session) == owned else { return }
        _ = attacher.closeHud(session, window: window)
        self.owned = nil
    }

    /// move closes the panel this attach owns and points later ones at `session`.
    func move(to session: String) {
        close()
        self.session = session
        owned = nil
    }

    func fail(_ text: String) {
        if open(HudSpec(message: message(text), hideAfter: AppActions.remoteAttachErrorSeconds), error: true) { return }
        close()
        NotificationManager.shared.notifyCommandFailure(name: action, detail: text)
    }

    @discardableResult
    private func open(_ spec: HudSpec, error: Bool) -> Bool {
        guard let session else { return false }
        if let showing = attacher.hudGeneration(session: session), showing != owned, showing != Self.failed[session] {
            return false
        }
        guard attacher.openHud(session, window: window, spec: spec).ok else { return false }
        owned = attacher.hudGeneration(session: session)
        Self.failed[session] = error ? owned : nil
        return true
    }

    /// a direct `openHud` skips the dispatcher's validation, so remote text is cleaned and capped here.
    private func message(_ text: String) -> String {
        CommandFailure.message(name: action, reason: text)
    }
}
