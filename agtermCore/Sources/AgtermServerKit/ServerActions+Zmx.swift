import Foundation
import agtermCore

/// `zmx.list` and `zmx.screen` over the server's own daemon namespace, the same reads a Mac answers for its own.
extension ServerActions {
    public func listZmxDaemons() -> ControlResponse {
        guard let listed = try? panes.runner.list() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let result = ZmxInventory.join(observed: listed, claims: paneClaims(), inventoryComplete: true)
        let endpoint = ControlZmxEndpoint(executable: panes.configuration.zmxPath,
                                          socketDirectory: panes.configuration.zmxSocketDirectory)
        let restore = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .live, unavailableReason: nil)
        return ControlResponse(ok: true, result: ControlResult(zmx: ControlZmxInventory(restore: restore, result: result,
                                                                                        endpoint: endpoint)))
    }

    public func readZmxScreen(name: String, fullBuffer: Bool, lines: Int?) -> ControlResponse {
        guard let screen = panes.runner.screen(name, all: fullBuffer) else {
            return ControlResponse(ok: false, error: "could not read the zmx screen of \(name)")
        }
        return ControlResponse(ok: true, result: ControlResult(text: lines.map(screen.lastLines) ?? screen.text))
    }

    /// paneClaims is every daemon-backed main and split pane of the catalog. A scratch daemon's name is never a pane
    /// daemon's, so the inventory lists it as foreign rather than as an orphan.
    func paneClaims() -> [ZmxPaneClaim] {
        var claims: [ZmxPaneClaim] = []
        for workspace in store.workspaces {
            for session in workspace.sessions {
                var roles: [(UUID, ZmxPaneRole)] = [(session.paneIdentity, .left)]
                if session.hasSplit, let split = session.splitPaneIdentity { roles.append((split, .right)) }
                for (identity, role) in roles where session.daemonBackedPanes.contains(identity) {
                    claims.append(ZmxPaneClaim(paneIdentity: identity, pane: role, pendingClose: false, windowID: catalog.id,
                                               windowName: catalog.name, windowState: .open, workspaceID: workspace.id,
                                               workspaceName: workspace.name, sessionID: session.id,
                                               sessionName: session.displayName))
                }
            }
        }
        return claims
    }
}
