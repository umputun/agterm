import Foundation
import Testing
@testable import agtermCore

@MainActor
struct RemoteSessionCreateTests {
    private func args(host: String? = "buildbox", originWindow: String? = nil) -> ControlArgs {
        var args = ControlArgs(host: host)
        args.originWindow = originWindow
        return args
    }

    @Test func parseTrimsTheHostAndKeepsWhatTheCallerNamed() throws {
        var request = ControlRequest(cmd: .sessionRemoteNew, args: ControlArgs(
            cwd: "/srv", workspaceName: " dev ", host: " buildbox ", command: "top", window: " w1 "))
        request.args?.originWindow = " 6f1c "

        let parsed = try RemoteSessionCreate.parse(request).get()

        #expect(parsed == RemoteSessionCreate(host: "buildbox", originWindow: "6f1c", workspaceName: "dev", cwd: "/srv",
                                              command: "top", window: "w1"))
    }

    @Test func parseDropsABlankOriginWindowAndLocalWindow() throws {
        var request = ControlRequest(cmd: .sessionRemoteNew, args: ControlArgs(host: "mac", window: " "))
        request.args?.originWindow = " "

        #expect(try RemoteSessionCreate.parse(request).get() == RemoteSessionCreate(host: "mac"))
    }

    @Test func parseRefusesABlankWorkspaceName() {
        let result = RemoteSessionCreate.parse(ControlRequest(cmd: .sessionRemoteNew, args: ControlArgs(workspaceName: " ", host: "mac")))

        #expect(result.failureMessage == "workspace name must not be blank")
    }

    @Test(arguments: [nil, " ", "-oProxyCommand=x", "a b"])
    func parseRefusesAMissingHostAndOneSshCannotTake(host: String?) {
        let result = RemoteSessionCreate.parse(ControlRequest(cmd: .sessionRemoteNew, args: args(host: host)))

        let expected = host?.trimmedOrNil == nil ? "session.remote.new requires a host" : "session.remote.new: not a host ssh can be given"
        #expect(result.failureMessage == expected)
    }

    @Test(arguments: [
        ControlArgs(workspace: "w", host: "mac"), ControlArgs(createWorkspace: true, host: "mac"),
        ControlArgs(host: "mac", after: "a"), ControlArgs(host: "mac", before: "b"),
        ControlArgs(targets: ["a"], host: "mac"),
    ])
    func parseRefusesPlacement(args: ControlArgs) {
        let result = RemoteSessionCreate.parse(ControlRequest(cmd: .sessionRemoteNew, args: args))

        #expect(result.failureMessage == "a remote session takes no target, workspace id or placement: it lands in the window's current workspace")
    }

    @Test func parseRefusesATargetAndAParent() {
        var parented = args()
        parented.parent = "p1"

        let targeted = RemoteSessionCreate.parse(ControlRequest(cmd: .sessionRemoteNew, target: "s1", args: args()))
        let parent = RemoteSessionCreate.parse(ControlRequest(cmd: .sessionRemoteNew, args: parented))

        #expect(targeted.failureMessage?.hasPrefix("a remote session takes no target") == true)
        #expect(parent.failureMessage?.hasPrefix("a remote session takes no target") == true)
    }

    @Test(arguments: [
        ControlArgs(host: "mac", wait: true), ControlArgs(name: "n", host: "mac"), ControlArgs(host: "mac", noSelect: true),
        ControlArgs(host: "mac", tint: "red"),
    ])
    func parseRefusesCreationFieldsTheRowCannotCarry(args: ControlArgs) {
        let result = RemoteSessionCreate.parse(ControlRequest(cmd: .sessionRemoteNew, args: args))

        #expect(result.failureMessage == "a remote session takes no --wait, --name, --no-select or tint")
    }

    @Test func parseRefusesTintPartsAndAnOperationID() {
        var parts = args()
        parts.tintOn = ["name"]
        var operation = args()
        operation.opID = "op-1"

        #expect(RemoteSessionCreate.parse(ControlRequest(cmd: .sessionRemoteNew, args: parts)).failureMessage
            == "a remote session takes no --wait, --name, --no-select or tint")
        #expect(RemoteSessionCreate.parse(ControlRequest(cmd: .sessionRemoteNew, args: operation)).failureMessage
            == "a remote session takes no operation id")
    }

    @Test func argumentsNameTheMacWindowAndKeepTheOriginsSelection() {
        let create = RemoteSessionCreate(host: "mac")

        #expect(create.arguments(origin: .mac(window: "6f1c"), workspaceName: "dev")
            == ["session", "new", "--window=6f1c", "--workspace-name=dev", "--create-workspace", "--no-select"])
    }

    @Test func argumentsWithNoWorkspaceNameCreateInTheOriginsRoot() {
        let create = RemoteSessionCreate(host: "mac")

        #expect(create.arguments(origin: .mac(window: "6f1c"), workspaceName: nil)
            == ["session", "new", "--window=6f1c", "--workspace=root", "--no-select"])
    }

    @Test func argumentsForAServerNameNoWindowAndCarryCwdAndCommand() {
        let create = RemoteSessionCreate(host: "srv", cwd: "/srv/app", command: "make run")

        #expect(create.arguments(origin: .server, workspaceName: "dev")
            == ["session", "new", "--workspace-name=dev", "--create-workspace", "--no-select",
                "--cwd=/srv/app", "--command=make run"])
    }

    // a bare `--cwd=` reached the origin as a missing value, and its CLI exited 64
    @Test func argumentsKeepAnEmptyValueAsItsOwnWordAndJoinADashLeadingOne() {
        let empty = RemoteSessionCreate(host: "srv", cwd: "", command: "")
        let dashed = RemoteSessionCreate(host: "srv", cwd: "-dir", command: "-v")

        #expect(empty.arguments(origin: .server, workspaceName: "dev")
            == ["session", "new", "--workspace-name=dev", "--create-workspace", "--no-select", "--cwd", "", "--command", ""])
        #expect(dashed.arguments(origin: .server, workspaceName: "dev")
            == ["session", "new", "--workspace-name=dev", "--create-workspace", "--no-select", "--cwd=-dir", "--command=-v"])
    }

    @Test func originKindTakesOnlyALiveMacOrAServer() {
        var mac = ControlResult()
        mac.macCatalog = CatalogVersions(server: "1", protocolVersion: 1, catalog: 1, live: true)
        var stopped = mac
        stopped.macCatalog?.live = false
        var unreported = mac
        unreported.macCatalog?.live = nil
        var server = ControlResult()
        server.headless = true
        var older = ControlResult()
        older.app = AppIdentity(version: "0.40.0", commit: "abc")

        #expect(RemoteSessionCreate.originKind(mac, host: "h") == .success(.mac))
        #expect(RemoteSessionCreate.originKind(server, host: "h") == .success(.server))
        for reply in [stopped, unreported] {
            #expect(RemoteSessionCreate.originKind(reply, host: "h")
                == .failure(.init(message: "h does not run Live sessions, which a remote session needs")))
        }
        for reply in [older, ControlResult(), nil] {
            #expect(RemoteSessionCreate.originKind(reply, host: "h")
                == .failure(.init(message: "the agterm on h is too old to create sessions for another Mac")))
        }
    }

    @Test func theDispatcherRefusesBeforeTheActionAndAHostWithoutItRefusesByName() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let refused = await dispatcher.dispatch(ControlRequest(cmd: .sessionRemoteNew, args: ControlArgs(host: "mac", noSelect: true)))
        let reached = await dispatcher.dispatch(ControlRequest(cmd: .sessionRemoteNew, args: ControlArgs(host: "mac")))

        #expect(refused?.error == "a remote session takes no --wait, --name, --no-select or tint")
        #expect(reached == ControlResponse(ok: false, error: "session.remote.new is not supported on this platform"))
        #expect(actions.calls.isEmpty)
    }

    @Test func theCommandRoundTripsOnTheWire() throws {
        let data = try JSONEncoder().encode(ControlRequest(cmd: .sessionRemoteNew, args: ControlArgs(host: "mac")))

        #expect(try JSONDecoder().decode(ControlRequest.self, from: data).cmd == .sessionRemoteNew)
        #expect(String(decoding: data, as: UTF8.self).contains(#""cmd":"session.remote.new""#))
    }
}

private extension Result where Failure == ArgumentRejection {
    var failureMessage: String? {
        if case .failure(let rejection) = self { return rejection.message }
        return nil
    }
}
