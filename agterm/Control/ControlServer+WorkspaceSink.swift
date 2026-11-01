import Foundation
import agtermCore

/// IdleWorkspaceSinking runs the sink pass, which needs the pane foreground reads only the control server
/// can make for Live panes.
@MainActor
protocol IdleWorkspaceSinking: AnyObject {
    func sinkIdleWorkspaces(in store: AppStore)
}

extension AppActions {
    /// Runs the sink one main-queue turn later, after the selection that asked for it has settled, so the
    /// row a click landed on is not moved under the click's own handling.
    func scheduleIdleWorkspaceSink(in store: AppStore) {
        DispatchQueue.main.async { [weak self, weak store] in
            guard let self, let store, store.sinksIdleWorkspaces else { return }
            workspaceSinker?.sinkIdleWorkspaces(in: store)
        }
    }
}

extension ControlServer: IdleWorkspaceSinking {
    /// Reads each local pane's foreground the way `buildTree` does, so a Live pane is judged by its daemon's
    /// leader rather than the attach client.
    func sinkIdleWorkspaces(in store: AppStore) {
        let shellBasename = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        let local = store.workspaces.flatMap(\.sessions).filter { $0.remoteHost == nil }
        if ZmxForegroundRefreshPolicy.hasWrappedPane(in: local) {
            if let zmxClient {
                zmxForegroundResolver?.acceptLeaderSnapshot(zmxClient.sessionLeaderPIDs())
            } else {
                zmxForegroundResolver?.refreshIfNeeded()
            }
        }
        store.sinkIdleWorkspaces { session in
            guard session.remoteHost == nil else { return false }
            return [session.surface, session.splitSurface].contains { surface in
                guard let view = surface as? GhosttySurfaceView,
                      case .program(let argv) = ForegroundProcess.running(for: view, shellBasename: shellBasename,
                                                                          zmxResolver: zmxForegroundResolver)
                else { return false }
                return AgentProgram.isClaudeCode(argv: argv)
            }
        }
    }
}
