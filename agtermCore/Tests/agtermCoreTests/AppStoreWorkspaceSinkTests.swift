import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreWorkspaceSinkTests {
    /// alpha (claude), empty, beta (plain), gamma (claude), in that order.
    static func makeTree() -> (store: AppStore, ids: [String: UUID], agents: Set<UUID>) {
        let store = makeStore()
        var ids: [String: UUID] = [:]
        var agents: Set<UUID> = []
        for (name, agent) in [("alpha", true), ("empty", false), ("beta", false), ("gamma", true)] {
            let workspace = store.addWorkspace(name: name)
            ids[name] = workspace.id
            guard name != "empty", let session = store.addSession(toWorkspace: workspace.id, cwd: "/tmp") else { continue }
            if agent { agents.insert(session.id) }
        }
        return (store, ids, agents)
    }

    @Test func sinksWorkspacesWithoutAnAgentKeepingEachGroupsOrder() {
        let (store, ids, agents) = Self.makeTree()
        #expect(store.sinkIdleWorkspaces { agents.contains($0.id) })
        #expect(store.workspaces.map(\.name) == ["alpha", "gamma", "empty", "beta"])
        #expect(store.workspaces.map(\.id) == ["alpha", "gamma", "empty", "beta"].map { ids[$0]! })
        #expect(!store.sinkIdleWorkspaces { agents.contains($0.id) }, "an already sunk tree does not change")
    }

    @Test func aNonIdleStatusCountsAsALiveAgent() {
        let (store, _, _) = Self.makeTree()
        let beta = store.workspaces.first { $0.name == "beta" }!.sessions[0]
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: beta.id)
        store.sinkIdleWorkspaces { _ in false }
        #expect(store.workspaces.map(\.name) == ["beta", "alpha", "empty", "gamma"])
    }

    @Test func selectionChangesAskTheSinkerOnlyWhileEnabled() {
        let (store, _, _) = Self.makeTree()
        var asked = 0
        store.idleWorkspaceSinker = { _ in asked += 1 }
        let sessions = store.workspaces.flatMap(\.sessions)
        store.selectSession(sessions[0].id)
        #expect(asked == 0)
        store.sinksIdleWorkspaces = true
        store.selectSession(sessions[1].id)
        store.selectSession(sessions[1].id)
        #expect(asked == 1, "reselecting the same session is not switching away")
    }

    @Test func treeReadsBackTheModeAndSettingsOmitItWhenOff() throws {
        let store = makeStore()
        #expect(store.controlTree().sinkIdleWorkspaces == false)
        store.sinksIdleWorkspaces = true
        #expect(store.controlTree().sinkIdleWorkspaces == true)
        let json = String(decoding: try JSONEncoder().encode(AppSettings()), as: UTF8.self)
        #expect(!json.contains("sinkIdleWorkspaces"))
        let decoded = try JSONDecoder().decode(AppSettings.self,
                                               from: JSONEncoder().encode(AppSettings(sinkIdleWorkspaces: true)))
        #expect(decoded.sinkIdleWorkspaces == true)
    }

    @Test func recognizesClaudeCodeArgv() {
        #expect(AgentProgram.isClaudeCode(argv: ["claude", "--resume", "abc"]))
        #expect(AgentProgram.isClaudeCode(argv: ["/Users/me/.local/bin/claude"]))
        #expect(AgentProgram.isClaudeCode(argv: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]))
        #expect(!AgentProgram.isClaudeCode(argv: ["vim", "claude.md"]))
        #expect(!AgentProgram.isClaudeCode(argv: []))
    }
}
