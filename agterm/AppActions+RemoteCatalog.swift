import agtermCore
import AppKit

extension AppActions {
    /// performRemote sends `operation` to `store`'s server when `store` is a remote window, and answers whether it
    /// did; a local window answers false and the caller changes its store as usual. What the operation acts on is
    /// captured now, so a change arriving before the send cannot retarget it.
    @discardableResult
    func performRemote(_ operation: RemoteOperation, in store: AppStore, select: Bool = false) -> Bool {
        guard let remote = store.remoteActions else { return false }
        switch remote.prepare(operation) {
        case .refused(let response):
            reportRemoteRefusal(response, of: operation, in: store)
        case .ready(let prepared):
            Task { @MainActor [weak self] in
                let response = await remote.send(prepared, selectingCreated: select)
                guard response.ok else { return self?.reportRemoteRefusal(response, of: operation, in: store) ?? () }
                if select { store.noteUserActivity() }
            }
        }
        return true
    }

    /// setScratchShown shows or hides `session`'s scratch: in a remote window the server's, which the window shows
    /// once the catalog says so, otherwise this Mac's.
    func setScratchShown(_ shown: Bool, of session: Session, in store: AppStore) {
        if store.isRemoteWindow {
            performRemote(.setScratch(session.id, shown: shown), in: store)
            return
        }
        if session.scratchActive != shown { store.toggleScratch(session.id) }
    }

    /// newRemoteSession is New Session in a remote window: the placement setting decides whether it lands after the
    /// selected row, and the directory setting whether it starts in that row's directory or the server's default.
    func newRemoteSession(inWorkspace workspaceID: UUID, of store: AppStore) {
        let shell = RemoteShellOptions(cwd: settingsModel?.settings.remoteNewSessionCwd(currentSessionCwd: store.activeSession?.focusedCwd))
        let afterCurrent = settingsModel?.settings.effectiveNewSessionPlacement == .afterCurrent
        let anchor = store.selectedSessionID.flatMap { id in
            afterCurrent && store.sessionLocation(ofSession: id)?.workspace == workspaceID ? RemoteSessionPlacement.after(id) : nil
        }
        performRemote(.newSession(workspace: workspaceID, anchor: anchor, shell: shell), in: store, select: true)
    }

    /// reportRemoteRefusal shows why the server did not take an action, over the row it named or the selected one.
    private func reportRemoteRefusal(_ response: ControlResponse, of operation: RemoteOperation, in store: AppStore) {
        let detail = response.error ?? "\(operation.label) was not done"
        let row: UUID? = switch operation.target {
        case .session(let id)?: store.session(withID: id) != nil ? id : store.selectedSessionID
        default: store.selectedSessionID
        }
        guard let remoteAttacher, let windowID = library.windowID(for: store) else {
            return NotificationManager.shared.notifyCommandFailure(name: operation.label, detail: detail)
        }
        RemoteAttachHud(attacher: remoteAttacher, session: row?.uuidString, window: windowID.uuidString, action: operation.label).fail(detail)
    }

    /// closeRemote closes rows of a remote window: while connected, an ended group with nothing running has its records
    /// removed on the server with no question; otherwise the user picks Detach (hide here, keep running), Terminate (end
    /// on the server) or Cancel. Answers false for a local window, whose close is the caller's.
    @discardableResult
    func closeRemote(_ ids: [UUID], in store: AppStore, choose: RemoteCloseChooser? = nil) -> Bool {
        guard let remote = store.remoteActions else { return false }
        // a companion closing with its parent goes with the parent's close on the server
        let roots = ids.filter { id in store.session(withID: id)?.parentID.map { !ids.contains($0) } ?? true }
        guard !roots.isEmpty else { return true }
        let scopes = roots.compactMap(remote.mirror.closeScope(session:))
        let connected = store.catalogState == .connected
        if connected, !scopes.contains(where: \.live) {
            for id in roots { performRemote(.closeSession(id), in: store) }
            return true
        }
        let name = roots.count == 1 ? "“\(store.session(withID: roots[0])?.displayName ?? "the session")”" : "\(roots.count) sessions"
        let blocked = connected ? nil : "Terminate needs a connection to \(remote.mirror.host)."
        switch (choose ?? Self.askDetachOrTerminate)(name, remote.mirror.host, blocked) {
        case .detach: remote.mirror.detach(sessions: roots)
        case .terminate: for id in roots { performRemote(.closeSession(id), in: store) }
        case .cancel: break
        }
        return true
    }

    /// closeRemoteWorkspace is Delete Workspace in a remote window: Detach hides the workspace here, Terminate deletes
    /// it on the server with every session in it.
    @discardableResult
    func closeRemoteWorkspace(_ id: UUID, in store: AppStore, choose: RemoteCloseChooser? = nil) -> Bool {
        guard let remote = store.remoteActions else { return false }
        let name = store.workspaces.first { $0.id == id }.map { "“\($0.name)”" } ?? "the workspace"
        let host = remote.mirror.host
        let blocked: String? = if store.catalogState != .connected {
            "Terminate needs a connection to \(host)."
        } else if !remote.mirror.canTerminateWorkspace {
            "\(host) keeps at least one workspace, so its only one cannot be terminated."
        } else {
            nil
        }
        switch (choose ?? Self.askDetachOrTerminate)(name, host, blocked) {
        case .detach: remote.mirror.detach(workspace: id)
        case .terminate: performRemote(.deleteWorkspace(id), in: store)
        case .cancel: break
        }
        return true
    }

    /// openDetachedSessions lists the window's detached workspaces and sessions in its picker; a live one is shown
    /// again, an ended one has its record removed under the Ended close rule.
    func openDetachedSessions() {
        guard let windowID = library.activeWindowID, uiActionsEnabled(for: windowID), let store, let remote = store.remoteActions,
              let controller = PickRegistry.shared.controller(for: windowID) else { return }
        let detached = remote.mirror.detachedItems
        guard !detached.isEmpty else { return }
        let items = detached.map { item in
            ControlPickItem(id: item.id.uuidString, label: item.name,
                            subtitle: item.kind == .workspace ? "Workspace" : item.ended ? "Ended" : nil)
        }
        Task { [weak self] in
            let pick = PendingPick(id: UUID().uuidString, items: items, prompt: "Reattach which?")
            guard let picked = await controller.pick(pick), picked.result == .picked else { return }
            // the catalog may have moved while the picker was open, an ended session or a removed record included
            guard let item = store.remoteActions?.mirror.detachedItems.first(where: { $0.id.uuidString == picked.id }) else {
                return NotificationManager.shared.notifyCommandFailure(name: "Detached Sessions", detail: "\(picked.label ?? "it") is no longer detached")
            }
            self?.reattach(item, in: store)
        }
    }

    private func reattach(_ item: RemoteDetachedItem, in store: AppStore) {
        guard let remote = store.remoteActions else { return }
        let refusal: String?
        switch item.kind {
        case .workspace: refusal = remote.mirror.reattach(workspace: item.id)
        case .session where item.ended:
            guard store.catalogState == .connected else {
                return NotificationManager.shared.notifyCommandFailure(name: "Detached Sessions", detail: "\(remote.mirror.host) is not connected")
            }
            refusal = nil
            closeRemote([item.id], in: store)
        case .session: refusal = remote.mirror.reattach(session: item.id)
        }
        if let refusal { NotificationManager.shared.notifyCommandFailure(name: "Detached Sessions", detail: refusal) }
    }

    /// RemoteCloseChoice is the answer to a remote close: hide it here, end it on the server, or leave it.
    enum RemoteCloseChoice {
        case detach, terminate, cancel
    }

    /// RemoteCloseChooser asks about closing `name` on `host`; a non-nil `terminateBlocked` says why Terminate is off.
    typealias RemoteCloseChooser = @MainActor (_ name: String, _ host: String, _ terminateBlocked: String?) -> RemoteCloseChoice

    private static func askDetachOrTerminate(_ name: String, host: String, terminateBlocked: String?) -> RemoteCloseChoice {
        guard !ContentView.shouldBypassCloseConfirmation else { return .detach }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(name) on \(host)?"
        alert.informativeText = "Detach hides it on this Mac and leaves it running on \(host); File > Detached Sessions brings it back. "
            + (terminateBlocked ?? "Terminate ends it on \(host) for every Mac showing it, with no undo.")
        alert.addButton(withTitle: "Detach")
        let terminate = alert.addButton(withTitle: "Terminate")
        terminate.hasDestructiveAction = true
        terminate.isEnabled = terminateBlocked == nil
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .detach
        case .alertSecondButtonReturn: return .terminate
        default: return .cancel
        }
    }
}
