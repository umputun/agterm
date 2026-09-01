import Foundation
import Testing
@testable import agtermCore

/// Dispatcher coverage for `restore.mode` and the zmx group, kept out of the general dispatcher suite
/// because these turn on policy and inventory state rather than on target resolution.
@MainActor
struct ControlDispatcherZmxTests {
    private func dispatch(_ request: ControlRequest, _ actions: MockControlActions) async -> ControlResponse? {
        await ControlDispatcher(actions: actions).dispatch(request)
    }

    @Test func restoreModeWithNoArgumentReadsRatherThanWrites() async throws {
        let actions = MockControlActions()
        actions.nextRestoreModeResponse = ControlResponse(
            ok: true,
            result: ControlResult(restore: ControlRestoreStatus(configured: .live, requestedAtLaunch: .rerun,
                                                                active: .rerun, unavailableReason: nil)))

        let response = try #require(await dispatch(ControlRequest(cmd: .restoreMode), actions))
        #expect(response.ok)
        #expect(actions.calls == [.restoreModeRead])

        let status = try #require(response.result?.restore)
        #expect(status.configured == "live")
        #expect(status.requestedAtLaunch == "rerun")
        #expect(status.active == "rerun")
        #expect(status.restartRequired)
    }

    @Test(arguments: [RestoreMode.none, .rerun, .live])
    func restoreModeSetsEachKnownMode(mode: RestoreMode) async throws {
        let actions = MockControlActions()
        let request = ControlRequest(cmd: .restoreMode, args: ControlArgs(mode: mode.rawValue))

        let response = try #require(await dispatch(request, actions))
        #expect(response.ok)
        #expect(actions.calls == [.restoreModeSet(mode)])
    }

    @Test func restoreModeRefusesAModeItDoesNotKnow() async throws {
        let actions = MockControlActions()
        let request = ControlRequest(cmd: .restoreMode, args: ControlArgs(mode: "sideways"))

        let response = try #require(await dispatch(request, actions))
        #expect(!response.ok)
        #expect(response.error?.contains("sideways") == true)
        // RestoreMode's own decoder would take this to `none`, whose next launch reaps every daemon
        #expect(actions.calls.isEmpty)
    }

    @Test func zmxListRoutesWithNoArgumentsToParse() async throws {
        let actions = MockControlActions()
        let response = try #require(await dispatch(ControlRequest(cmd: .zmxList), actions))
        #expect(response.ok)
        #expect(actions.calls == [.zmxList])
    }

    @Test func zmxPruneRoutesWithNoArgumentsToParse() async throws {
        let actions = MockControlActions()
        let response = try #require(await dispatch(ControlRequest(cmd: .zmxPrune), actions))
        #expect(response.ok)
        #expect(actions.calls == [.zmxPrune])
    }

    @Test(arguments: [Command.zmxList, .zmxPrune])
    func zmxCommandsKeepTheirWireNames(command: Command) throws {
        let request = ControlRequest(cmd: command)
        let json = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(json["cmd"] as? String == command.rawValue)
        #expect(command.rawValue.hasPrefix("zmx."))

        let decoded = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.cmd == command)
    }

    /// One refusal case: the request shape and the exact error it must produce before the host is called.
    struct KillRefusal {
        let target: String?
        let pane: String?
        let force: Bool
        let error: String
    }

    @Test(arguments: [
        KillRefusal(target: nil, pane: "left", force: true, error: "zmx.kill requires an explicit --target"),
        KillRefusal(target: "abc", pane: nil, force: true, error: "zmx.kill requires --pane left|right"),
        KillRefusal(target: "abc", pane: "scratch", force: true, error: "zmx.kill requires --pane left|right"),
        KillRefusal(target: "abc", pane: "left", force: false, error: "zmx.kill requires --force"),
    ])
    func zmxKillRefusesBeforeTheHostIsCalled(refusal: KillRefusal) async throws {
        let actions = MockControlActions()
        let args = ControlArgs(force: refusal.force ? true : nil, pane: refusal.pane)
        let request = ControlRequest(cmd: .zmxKill, target: refusal.target, args: args)

        let response = try #require(await dispatch(request, actions))
        #expect(!response.ok)
        #expect(response.error == refusal.error)
        // the refusal names no owner: the dispatcher cannot resolve one, the inventory can
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [("left", ZmxPaneRole.left), ("primary", .left), ("right", .right), ("split", .right)])
    func zmxKillPassesTheResolvedPaneToTheHost(spelling: String, role: ZmxPaneRole) async throws {
        let actions = MockControlActions()
        let args = ControlArgs(force: true, window: "w1", pane: spelling)
        let request = ControlRequest(cmd: .zmxKill, target: "abc", args: args)

        let response = try #require(await dispatch(request, actions))
        #expect(response.ok)
        #expect(actions.calls == [.zmxKill(target: "abc", window: "w1", pane: role)])
    }

    @Test func theKillRequestAndItsAnswerBothSurviveTheWire() throws {
        let request = ControlRequest(cmd: .zmxKill, target: "3f2a",
                                     args: ControlArgs(force: true, window: "w1", pane: "right"))
        let encoded = try JSONEncoder().encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["cmd"] as? String == "zmx.kill")
        #expect(json["target"] as? String == "3f2a")
        let args = try #require(json["args"] as? [String: Any])
        #expect(args["force"] as? Bool == true)
        #expect(args["pane"] as? String == "right")

        let decoded = try JSONDecoder().decode(ControlRequest.self, from: encoded)
        #expect(decoded.args?.force == true)
        #expect(decoded.args?.pane == "right")
        #expect(decoded.args?.window == "w1")

        let answer = ControlResponse(ok: true, result: ControlResult(id: "session-1",
                                                                     text: "killed agterm-3f2a",
                                                                     pane: "right"))
        let back = try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(answer))
        #expect(back.result?.id == "session-1")
        #expect(back.result?.pane == "right", "the pane it acted on is the read-back a caller checks")
        #expect(back.result?.text == "killed agterm-3f2a")
    }

    @Test func zmxInventoryReachesACallerThroughTheWholeResponse() throws {
        let pane = UUID()
        let claim = ZmxPaneClaim(paneIdentity: pane, pane: .right, pendingClose: true, windowID: UUID(),
                                 windowName: nil, windowState: .unindexed, workspaceID: UUID(),
                                 workspaceName: "workspace 1", sessionID: UUID(), sessionName: "build")
        let result = ZmxInventory.join(
            observed: [ZmxSessionRecord(name: ZmxSupport.daemonName(for: pane), clients: 2, leaderPID: 9),
                       ZmxSessionRecord(name: "notes", clients: 0, leaderPID: 7)],
            claims: [claim], inventoryComplete: false)
        let status = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .live,
                                          unavailableReason: nil)

        let payload = ControlZmxInventory(restore: status, result: result)
        // through the whole response, which is the boundary a caller actually reads `result.zmx` from
        let response = ControlResponse(ok: true, result: ControlResult(zmx: payload))
        let encoded = try JSONEncoder().encode(response)
        let decoded = try #require(try JSONDecoder().decode(ControlResponse.self, from: encoded).result?.zmx)

        #expect(decoded == payload)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rows = try #require((json["result"] as? [String: Any])?["zmx"] as? [String: Any])
        let entries = try #require(rows["entries"] as? [[String: Any]])
        let foreignRow = try #require(entries.first { $0["daemon"] as? String == "notes" })
        #expect(foreignRow["sessionID"] == nil, "an unclaimed row omits its owner fields, never nulls them")
        #expect(foreignRow["clients"] as? Int == 0)
        #expect(!decoded.inventoryComplete)
        let claimed = try #require(decoded.entries.first { $0.state == "pendingClose" })
        #expect(claimed.observation == "running")
        #expect(claimed.clients == 2)
        #expect(claimed.pane == "right")
        #expect(claimed.windowName == nil)
        #expect(claimed.windowState == "unindexed")
        #expect(claimed.sessionName == "build")

        let foreign = try #require(decoded.entries.first { $0.daemon == "notes" })
        #expect(foreign.state == "foreign")
        #expect(foreign.sessionID == nil)
    }

    @Test func zmxTreeReachesTheHostItWasGiven() async {
        let actions = MockControlActions()
        let request = ControlRequest(cmd: .zmxTree, args: ControlArgs(host: "buildbox"))

        _ = await ControlDispatcher(actions: actions).dispatch(request)

        #expect(actions.calls == [.zmxTree(host: "buildbox")])
    }

    // a blank host is not a host, and must reach the action as the LOCAL form rather than as an ssh
    // destination made of whitespace
    @Test(arguments: [nil, "", "   "])
    func zmxTreeWithNoUsableHostAsksAboutThisApp(_ host: String?) async {
        let actions = MockControlActions()
        let request = ControlRequest(cmd: .zmxTree, args: ControlArgs(host: host))

        let response = await ControlDispatcher(actions: actions).dispatch(request)

        #expect(response?.ok == true)
        #expect(actions.calls == [.zmxTree(host: nil)])
    }

    @Test func zmxAttachCarriesBothTheHostAndTheRemoteSession() async {
        let actions = MockControlActions()
        let request = ControlRequest(cmd: .zmxAttach, target: "s1", args: ControlArgs(host: "buildbox"))

        _ = await ControlDispatcher(actions: actions).dispatch(request)

        #expect(actions.calls == [.zmxAttach(host: "buildbox", session: "s1")])
    }

    @Test func zmxAttachRefusesWithoutAHostOrASessionBeforeTheHostIsCalled() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let noHost = await dispatcher.dispatch(ControlRequest(cmd: .zmxAttach, target: "s1"))
        #expect(noHost?.error == "zmx.attach requires a host")

        let noSession = await dispatcher.dispatch(ControlRequest(cmd: .zmxAttach,
                                                                 args: ControlArgs(host: "buildbox")))
        #expect(noSession?.error == "zmx.attach requires a remote session")
        #expect(actions.calls.isEmpty)
    }

    // the unresolved-session message names the id, so a control character reaching it would be printed
    // to a terminal by agtermctl after JSON decoding
    @Test(arguments: ["s1\nrm -rf /", "s1\u{1B}[31m", "s1\u{7F}", "s 1"])
    func zmxAttachRefusesASessionCarryingControlCharactersOrEmbeddedWhitespace(_ session: String) async {
        let actions = MockControlActions()

        let response = await ControlDispatcher(actions: actions).dispatch(
            ControlRequest(cmd: .zmxAttach, target: session, args: ControlArgs(host: "buildbox")))

        #expect(response?.error == "invalid remote session")
        #expect(actions.calls.isEmpty, "it must refuse before the host is reached")
    }

    @Test func theRemoteTreeSurvivesTheWire() throws {
        let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/zmx",
                                          socketDirectory: "/tmp/agterm-zmx-abc")
        let session = ControlRemoteSession(
            id: "s1", name: "build", windowID: "w-1", windowName: "main", workspaceID: "ws-1",
            workspaceName: "umputun.dev", context: "release prep", cwd: "/repo", splitAxis: "vertical",
            panes: [ControlRemotePane(pane: "left", daemon: "agterm-1", foreground: ["/bin/zsh"]),
                    ControlRemotePane(pane: "right", daemon: "agterm-2", foreground: nil)])
        let payload = ControlRemoteTree(host: "buildbox", endpoint: endpoint, sessions: [session])

        let encoded = try JSONEncoder().encode(ControlResponse(ok: true, result: ControlResult(remote: payload)))
        let decoded = try #require(try JSONDecoder().decode(ControlResponse.self, from: encoded).result?.remote)

        #expect(decoded == payload)
    }

    @Test func zmxInventoryCarriesTheEndpointARemoteAttachNeeds() throws {
        let status = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .live,
                                          unavailableReason: nil)
        let result = ZmxInventory.join(observed: [], claims: [], inventoryComplete: true)
        let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/Contents/Resources/zmx/zmx",
                                          socketDirectory: "/tmp/agterm-zmx-abc123")

        let payload = ControlZmxInventory(restore: status, result: result, endpoint: endpoint)
        let response = ControlResponse(ok: true, result: ControlResult(zmx: payload))
        let encoded = try JSONEncoder().encode(response)
        let decoded = try #require(try JSONDecoder().decode(ControlResponse.self, from: encoded).result?.zmx)

        #expect(decoded.endpoint == endpoint)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let zmx = try #require((json["result"] as? [String: Any])?["zmx"] as? [String: Any])
        let wire = try #require(zmx["endpoint"] as? [String: Any])
        #expect(wire["socketDirectory"] as? String == "/tmp/agterm-zmx-abc123")
    }

    @Test func zmxInventoryOmitsTheEndpointRatherThanNullingIt() throws {
        let status = ControlRestoreStatus(configured: .none, requestedAtLaunch: .none, active: .none,
                                          unavailableReason: nil)
        let result = ZmxInventory.join(observed: [], claims: [], inventoryComplete: true)

        let payload = ControlZmxInventory(restore: status, result: result)
        let encoded = try JSONEncoder().encode(ControlResponse(ok: true, result: ControlResult(zmx: payload)))
        let decoded = try #require(try JSONDecoder().decode(ControlResponse.self, from: encoded).result?.zmx)

        #expect(decoded.endpoint == nil)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let zmx = try #require((json["result"] as? [String: Any])?["zmx"] as? [String: Any])
        #expect(zmx["endpoint"] == nil, "a remote reader tells an older server apart by absence")
    }

    @Test func restoreStatusHidesAProbedReasonUnlessLiveActuallyFellBack() {
        let asked = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .none,
                                         unavailableReason: "the password-database login shell is not zsh")
        #expect(asked.unavailableReason != nil)
        #expect(asked.active == "none")

        let neverAsked = ControlRestoreStatus(configured: .rerun, requestedAtLaunch: .rerun, active: .rerun,
                                              unavailableReason: "the password-database login shell is not zsh")
        #expect(neverAsked.unavailableReason == nil)
        #expect(!neverAsked.restartRequired)
    }

    @Test(arguments: [nil, "live"])
    func restoreModeRequestsSurviveTheWire(mode: String?) throws {
        let request = ControlRequest(cmd: .restoreMode, args: mode.map { ControlArgs(mode: $0) })
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request))

        #expect(decoded.cmd == .restoreMode)
        #expect(decoded.args?.mode == mode)

        let json = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(json["cmd"] as? String == "restore.mode")
    }

    @Test func theWholeResponseCarriesTheStatusAndKeepsAFutureModeIntact() throws {
        let status = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .live,
                                          unavailableReason: nil)
        let response = ControlResponse(ok: true, result: ControlResult(restore: status))
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response))
        #expect(decoded.result?.restore == status)

        let json = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        let result = try #require(json["result"] as? [String: Any])
        let restore = try #require(result["restore"] as? [String: Any])
        #expect(restore["configured"] as? String == "live")
        #expect(restore["unavailableReason"] == nil, "an absent reason must be omitted, not null")

        // a future server's mode must reach a stale CLI intact, nested where a caller actually reads it,
        // rather than collapsing to `none` the way RestoreMode's own lossy decoder would
        let future = Data("""
        {"ok":true,"result":{"restore":{"configured":"mirrored","requestedAtLaunch":"live",\
        "active":"live","restartRequired":true}}}
        """.utf8)
        let fromFuture = try JSONDecoder().decode(ControlResponse.self, from: future)
        #expect(fromFuture.result?.restore?.configured == "mirrored")
    }

    @Test func theUnsupportedRefusalNamesTheCommand() {
        // agtermCore is a library the agterm-linux fork consumes, so every Mac-only ControlActions
        // requirement ships a default returning this rather than breaking that build
        #expect(ControlActionsUnsupported.message("zmx.list") == "zmx.list is not supported on this platform")
    }
}
