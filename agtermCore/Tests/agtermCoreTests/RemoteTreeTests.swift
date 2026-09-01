import Foundation
import Testing
@testable import agtermCore

struct RemoteTreeTests {
    private static let left = ZmxSupport.daemonName(for: UUID())
    private static let right = ZmxSupport.daemonName(for: UUID())
    private static let other = ZmxSupport.daemonName(for: UUID())

    private let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/zmx",
                                              socketDirectory: "/tmp/agterm-zmx-abc")

    // MARK: - building the candidate list

    @Test func aPlainSessionResolvesToOneLeftDaemon() throws {
        let windows = [window(name: "main", workspace: "work",
                              sessions: [node(id: "s1", name: "build", cwd: "/repo")])]

        let tree = try RemoteTreeMerger.candidates(windows: windows,
                                                   inventory: inventory(entries: [
                                                       entry(session: "s1", pane: "left", daemon: Self.left),
                                                   ]))

        #expect(tree.host == nil, "the local form sshed nowhere, so it names no destination")
        #expect(tree.endpoint == endpoint)
        #expect(tree.sessions.count == 1)
        #expect(tree.sessions[0].panes == [ControlRemotePane(pane: "left", daemon: Self.left)])
        #expect(tree.sessions[0].splitAxis == nil)
        #expect(tree.sessions[0].windowName == "main")
        #expect(tree.sessions[0].workspaceName == "work")
    }

    @Test func everyOpenWindowIsOffered() throws {
        let windows = [window(id: "w-1", name: "main", workspace: "umputun.dev",
                              sessions: [node(id: "s1", name: "build", cwd: "/repo")]),
                       window(id: "w-2", name: "second", workspace: "ops",
                              sessions: [node(id: "s2", name: "logs", cwd: "/var")])]

        let tree = try RemoteTreeMerger.candidates(windows: windows,
                                                   inventory: inventory(entries: [
                                                       entry(session: "s1", pane: "left", daemon: Self.left),
                                                       entry(session: "s2", pane: "left", daemon: Self.right),
                                                   ]))

        #expect(tree.sessions.map(\.id) == ["s1", "s2"])
        #expect(tree.sessions.map(\.windowID) == ["w-1", "w-2"])
        #expect(tree.sessions.map(\.windowName) == ["main", "second"])
    }

    // neither rename path enforces uniqueness, so a caller grouping by name would merge these two
    @Test func sameNamedWindowsAndWorkspacesStayApartByID() throws {
        let windows = [window(id: "w-1", name: "main", workspaceID: "ws-1", workspace: "dev",
                              sessions: [node(id: "s1", name: "build", cwd: "/a")]),
                       window(id: "w-2", name: "main", workspaceID: "ws-2", workspace: "dev",
                              sessions: [node(id: "s2", name: "build", cwd: "/b")])]

        let tree = try RemoteTreeMerger.candidates(windows: windows,
                                                   inventory: inventory(entries: [
                                                       entry(session: "s1", pane: "left", daemon: Self.left),
                                                       entry(session: "s2", pane: "left", daemon: Self.right),
                                                   ]))

        #expect(Set(tree.sessions.map(\.windowName)) == ["main"])
        #expect(tree.sessions.map(\.windowID) == ["w-1", "w-2"])
        #expect(tree.sessions.map(\.workspaceID) == ["ws-1", "ws-2"])
    }

    @Test func eachSessionCarriesItsOwnWorkspaceRatherThanTheFirstOne() throws {
        let left = ControlWorkspaceNode(id: "ws-1", name: "umputun.dev", active: true,
                                        sessions: [node(id: "s1", name: "build", cwd: "/repo")])
        let right = ControlWorkspaceNode(id: "ws-2", name: "ops", active: false,
                                         sessions: [node(id: "s2", name: "logs", cwd: "/var")])
        let windows = [RemoteWindowProjection(id: "w-1", name: "main",
                                              tree: ControlTree(workspaces: [left, right]))]

        let tree = try RemoteTreeMerger.candidates(windows: windows,
                                                   inventory: inventory(entries: [
                                                       entry(session: "s1", pane: "left", daemon: Self.left),
                                                       entry(session: "s2", pane: "left", daemon: Self.right),
                                                   ]))

        #expect(tree.sessions.map(\.workspaceName) == ["umputun.dev", "ops"])
    }

    @Test func aPaneCarriesWhatIsRunningInItAndTheSessionItsContext() throws {
        let running = ControlSessionNode(id: "s1", name: "build", cwd: "/repo", active: false, split: false,
                                         backedByZmx: true, foreground: ["/usr/bin/tail", "-f"],
                                         context: "release prep")
        let windows = [window(name: "main", workspace: "work", sessions: [running])]

        let tree = try RemoteTreeMerger.candidates(windows: windows,
                                                   inventory: inventory(entries: [
                                                       entry(session: "s1", pane: "left", daemon: Self.left),
                                                   ]))

        #expect(tree.sessions[0].context == "release prep")
        #expect(tree.sessions[0].panes[0].foreground == ["/usr/bin/tail", "-f"])
    }

    @Test func aSplitSessionCarriesBothDaemonsAndItsAxis() throws {
        let windows = [window(name: "main", workspace: "work",
                              sessions: [node(id: "s1", name: "build", cwd: "/repo", hasSplit: true)])]

        let tree = try RemoteTreeMerger.candidates(windows: windows,
                                                   inventory: inventory(entries: [
                                                       entry(session: "s1", pane: "left", daemon: Self.left),
                                                       entry(session: "s1", pane: "right", daemon: Self.right),
                                                   ]))

        #expect(tree.sessions[0].panes.map(\.pane) == ["left", "right"])
        #expect(tree.sessions[0].panes.map(\.daemon) == [Self.left, Self.right])
        #expect(tree.sessions[0].splitAxis == "vertical")
    }

    @Test func aSplitMissingItsSecondDaemonIsDroppedRatherThanOfferedHalfWay() throws {
        let windows = [window(name: "main", workspace: "work",
                              sessions: [node(id: "s1", name: "build", cwd: "/repo", hasSplit: true)])]

        let tree = try RemoteTreeMerger.candidates(windows: windows,
                                                   inventory: inventory(entries: [
                                                       entry(session: "s1", pane: "left", daemon: Self.left),
                                                   ]))

        #expect(tree.sessions.isEmpty)
    }

    @Test(arguments: [("orphan", "running"), ("claimed", "absent"), ("claimed", "unreadable")])
    func onlyAClaimedAndRunningDaemonIsOffered(_ pair: (state: String, observation: String)) throws {
        let windows = [window(name: "main", workspace: "work",
                              sessions: [node(id: "s1", name: "build", cwd: "/repo")])]

        let tree = try RemoteTreeMerger.candidates(
            windows: windows,
            inventory: inventory(entries: [entry(session: "s1", pane: "left", daemon: Self.left,
                                                 state: pair.state, observation: pair.observation)]))

        #expect(tree.sessions.isEmpty)
    }

    // a launch that asked for live and fell back keeps its daemons while showing plain shells
    @Test func aSessionThatIsNotBackedByZmxIsNotOffered() throws {
        let windows = [window(name: "main", workspace: "work",
                              sessions: [node(id: "s1", name: "build", cwd: "/repo", backedByZmx: false)])]

        let tree = try RemoteTreeMerger.candidates(windows: windows,
                                                   inventory: inventory(entries: [
                                                       entry(session: "s1", pane: "left", daemon: Self.left),
                                                   ]))

        #expect(tree.sessions.isEmpty)
    }

    @Test func aDaemonNamedOutsideAgtermsSchemeIsNotOffered() throws {
        let windows = [window(name: "main", workspace: "work",
                              sessions: [node(id: "s1", name: "build", cwd: "/repo")])]

        let tree = try RemoteTreeMerger.candidates(windows: windows,
                                                   inventory: inventory(entries: [
                                                       entry(session: "s1", pane: "left", daemon: "notes"),
                                                   ]))

        #expect(tree.sessions.isEmpty)
    }

    @Test func rowsNamingNoListedSessionAreIgnored() throws {
        let windows = [window(name: "main", workspace: "work",
                              sessions: [node(id: "s1", name: "build", cwd: "/repo")])]

        let tree = try RemoteTreeMerger.candidates(windows: windows,
                                                   inventory: inventory(entries: [
                                                       entry(session: "s1", pane: "left", daemon: Self.left),
                                                       entry(session: "gone", pane: "left", daemon: Self.other),
                                                   ]))

        #expect(tree.sessions.map(\.id) == ["s1"])
    }

    @Test func anInventoryWithNoEndpointIsRefusedByName() {
        #expect(throws: RemoteTreeMerger.MergeError.missingEndpoint) {
            try RemoteTreeMerger.candidates(windows: [], inventory: inventory(entries: [],
                                                                              includeEndpoint: false))
        }
    }

    @Test func noWindowsIsAnEmptyAnswerRatherThanAFailure() throws {
        let tree = try RemoteTreeMerger.candidates(windows: [], inventory: inventory(entries: []))

        #expect(tree.sessions.isEmpty)
        #expect(tree.endpoint == endpoint)
    }

    // MARK: - reading the far side's answer back

    @Test func theFarSidesAnswerIsDecodedWhole() throws {
        let session = ControlRemoteSession(id: "s1", name: "build", windowID: "w-1", windowName: "main",
                                           workspaceID: "ws-1", workspaceName: "work", cwd: "/repo",
                                           splitAxis: nil,
                                           panes: [ControlRemotePane(pane: "left", daemon: Self.left)])
        let payload = ControlRemoteTree(host: nil, endpoint: endpoint, sessions: [session])
        let stdout = String(decoding: try JSONEncoder().encode(
            ControlResponse(ok: true, result: ControlResult(remote: payload))), as: UTF8.self)

        #expect(try RemoteTreeMerger.decode(stdout: stdout) == payload)
    }

    @Test func theRemotesOwnRefusalIsReadFromStdoutWhereAgtermctlPutsIt() {
        let stdout = #"{"ok":false,"error":"could not read the zmx session list"}"#

        #expect(RemoteTreeMerger.remoteError(stdout: stdout) == "could not read the zmx session list")
    }

    @Test func anOkAnswerCarriesNoRemoteErrorToReport() {
        let stdout = #"{"ok":true,"result":{"remote":{"endpoint":{"executable":"/z","socketDirectory":"/t"},"sessions":[]}}}"#

        #expect(RemoteTreeMerger.remoteError(stdout: stdout) == nil)
    }

    @Test func unreadableOutputIsMalformedRatherThanEmpty() {
        #expect(throws: RemoteTreeMerger.MergeError.malformedProjection) {
            try RemoteTreeMerger.decode(stdout: "command not found: agtermctl")
        }
    }

    // an older far side knows `zmx tree` but answers ok with nothing in it
    @Test func anOkAnswerWithNoRemoteResultIsMalformed() {
        #expect(throws: RemoteTreeMerger.MergeError.malformedProjection) {
            try RemoteTreeMerger.decode(stdout: #"{"ok":true}"#)
        }
    }

    @Test func aFailedRemoteReadCarriesItsOwnReason() {
        #expect(throws: RemoteTreeMerger.MergeError.remoteFailed("zmx is not available")) {
            try RemoteTreeMerger.decode(stdout: #"{"ok":false,"error":"zmx is not available"}"#)
        }
    }

    // MARK: - fixtures

    private func node(id: String, name: String, cwd: String, hasSplit: Bool = false,
                      axis: String = "vertical", backedByZmx: Bool? = true) -> ControlSessionNode {
        ControlSessionNode(id: id, name: name, cwd: cwd, active: false, split: hasSplit,
                           hasSplit: hasSplit ? true : nil, backedByZmx: backedByZmx,
                           splitAxis: hasSplit ? axis : nil)
    }

    private func window(id: String = "w-1", name: String, workspaceID: String = "ws-1", workspace: String,
                        sessions: [ControlSessionNode]) -> RemoteWindowProjection {
        let node = ControlWorkspaceNode(id: workspaceID, name: workspace, active: true, sessions: sessions)
        return RemoteWindowProjection(id: id, name: name, tree: ControlTree(workspaces: [node]))
    }

    private func entry(session: String, pane: String, daemon: String,
                       state: String = "claimed", observation: String = "running") -> [String: Any] {
        ["daemon": daemon, "state": state, "observation": observation, "sessionID": session, "pane": pane]
    }

    /// Built as raw JSON and decoded, so the fixture pins the wire shape rather than whatever the current
    /// encoder happens to emit. `ControlZmxEntry` has no memberwise init of its own.
    private func inventory(entries: [[String: Any]], includeEndpoint: Bool = true) -> ControlZmxInventory {
        var payload: [String: Any] = [
            "restore": ["configured": "live", "requestedAtLaunch": "live", "active": "live",
                        "restartRequired": false],
            "inventoryComplete": true,
            "entries": entries,
        ]
        if includeEndpoint {
            payload["endpoint"] = ["executable": endpoint.executable,
                                   "socketDirectory": endpoint.socketDirectory]
        }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(ControlZmxInventory.self, from: data)
    }
}
