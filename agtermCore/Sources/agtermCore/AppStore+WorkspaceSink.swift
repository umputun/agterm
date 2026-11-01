import Foundation

/// Recognizes a Claude Code process from its argv: the native `claude` binary, or the npm package's
/// `cli.js` run under node.
public enum AgentProgram {
    public static func isClaudeCode(argv: [String]) -> Bool {
        guard let first = argv.first else { return false }
        if CommandRestore.basename(first) == "claude" { return true }
        return argv.dropFirst().contains { $0.contains("@anthropic-ai/claude-code/") }
    }
}

extension AppStore {
    public func requestIdleWorkspaceSink() {
        guard sinksIdleWorkspaces else { return }
        idleWorkspaceSinker?(self)
    }
    /// Moves every workspace without a live agent session below those with one, keeping each group's own
    /// order, so a drag inside a group survives the next sink. An empty workspace is never live. A session is
    /// live when `runsAgent` says so or its agent status is not idle, which also covers a remote row whose
    /// processes cannot be read here. Returns whether the order changed; only then does it save.
    @discardableResult
    public func sinkIdleWorkspaces(runsAgent: (Session) -> Bool) -> Bool {
        let live = Set(workspaces.filter { workspace in
            workspace.sessions.contains { $0.agentIndicator.status != .idle || runsAgent($0) }
        }.map(\.id))
        let ordered = workspaces.filter { live.contains($0.id) } + workspaces.filter { !live.contains($0.id) }
        guard ordered.map(\.id) != workspaces.map(\.id) else { return false }
        workspaces = ordered
        scheduleTreeChanged()
        save()
        return true
    }
}
