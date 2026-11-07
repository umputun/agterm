import Foundation
import Testing
@testable import agtermCore

@MainActor
struct RemoteOperationRequestTests {
    private let store = makeStore()
    private let workspace: Workspace
    private let first: Session
    private let second: Session

    init() throws {
        workspace = store.addWorkspace(name: "w")
        first = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/a"))
        second = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/b"))
        store.selectSession(first.id)
    }

    private func parse(_ cmd: Command, target: String? = nil, _ configure: (inout ControlArgs) -> Void = { _ in }) -> RemoteOperationParse {
        var args = ControlArgs()
        configure(&args)
        return RemoteOperation.parse(ControlRequest(cmd: cmd, target: target, args: args), in: store)
    }

    private func refusal(_ parse: RemoteOperationParse) -> String? {
        guard case .refused(let response) = parse else { return nil }
        return response.error
    }

    @Test func aNewSessionLandsInTheNamedWorkspaceWithItsShellOptions() {
        let parsed = parse(.sessionNew) { $0.workspace = String(workspace.id.uuidString.prefix(8)); $0.name = "-x"; $0.cwd = "/srv" }

        let shell = RemoteShellOptions(name: "-x", cwd: "/srv")
        #expect(parsed == .operation(.newSession(workspace: workspace.id, shell: shell), select: true))
    }

    @Test func aNewSessionBesideAnAnchorTakesTheAnchorsWorkspace() {
        let parsed = parse(.sessionNew) { $0.before = second.id.uuidString; $0.noSelect = true }

        #expect(parsed == .operation(.newSession(workspace: workspace.id, anchor: .before(second.id)), select: false))
    }

    @Test func aDuplicateIsAFreshShellAfterTheRowInItsDirectory() {
        let parsed = parse(.sessionDuplicate, target: first.id.uuidString)

        #expect(parsed == .operation(.newSession(workspace: workspace.id, anchor: .after(first.id), shell: RemoteShellOptions(cwd: "/a")),
                                     select: true))
    }

    @Test func aCompanionLandsUnderTheActiveSession() {
        #expect(parse(.sessionCompanionNew) == .operation(.newCompanion(parent: first.id), select: true))
    }

    @Test(arguments: [(nil, true), ("on", true), ("off", false)] as [(String?, Bool)])
    func aSplitResolvesItsModeAgainstTheRow(_ mode: String?, _ shown: Bool) {
        let parsed = parse(.sessionSplit, target: first.id.uuidString) { $0.mode = mode; $0.axis = "horizontal" }

        #expect(parsed == .operation(.setSplit(first.id, shown: shown, axis: "horizontal"), select: false))
    }

    @Test func aToggleOfAShownSplitHidesIt() {
        first.hasSplit = true
        first.isSplit = true

        #expect(parse(.sessionSplit, target: first.id.uuidString) == .operation(.setSplit(first.id, shown: false, axis: nil), select: false))
    }

    @Test func everySessionVerbResolvesItsTarget() {
        let target = first.id.uuidString
        #expect(parse(.sessionSplitClose, target: target) == .operation(.closeSplit(first.id), select: false))
        #expect(parse(.sessionSwap, target: target) == .operation(.swap(first.id), select: false))
        #expect(parse(.sessionRename, target: target) { $0.name = "build" } == .operation(.renameSession(first.id, name: "build"), select: false))
        #expect(parse(.sessionClose, target: target) == .operation(.closeSession(first.id), select: false))
        #expect(parse(.sessionClose) { $0.targets = [target] } == .operation(.closeSession(first.id), select: false))
    }

    @Test func aMoveTakesExactlyOnePlacement() {
        let target = first.id.uuidString
        #expect(parse(.sessionMove, target: target) { $0.to = "down" } == .operation(.moveSession(first.id, to: .step("down")), select: false))
        #expect(parse(.sessionMove, target: target) { $0.after = second.id.uuidString }
            == .operation(.moveSession(first.id, to: .after(second.id)), select: false))
        #expect(parse(.sessionMove, target: target) { $0.workspace = workspace.id.uuidString }
            == .operation(.moveSession(first.id, to: .workspace(workspace.id)), select: false))
        #expect(refusal(parse(.sessionMove, target: target) { $0.to = "down"; $0.workspace = workspace.id.uuidString })
            == "session.move takes exactly one of --to, a workspace, or --after/--before")
        #expect(refusal(parse(.sessionMove, target: target) { $0.to = "sideways" }) == "session.move --to must be up|down|top|bottom")
    }

    @Test func everyWorkspaceVerbResolvesItsTarget() {
        let target = workspace.id.uuidString
        #expect(parse(.workspaceNew) { $0.name = "dev" } == .operation(.newWorkspace(name: "dev"), select: false))
        #expect(parse(.workspaceRename, target: target) { $0.name = " ops " } == .operation(.renameWorkspace(workspace.id, name: "ops"), select: false))
        #expect(parse(.workspaceDelete, target: target) == .operation(.deleteWorkspace(workspace.id), select: false))
        #expect(parse(.workspaceMove, target: target) { $0.to = "top" } == .operation(.moveWorkspace(workspace.id, to: "top"), select: false))
    }

    @Test(arguments: [
        (Command.sessionNew, "--workspace-name"), (.sessionNew, "--create-workspace"), (.sessionNew, "--wait"), (.sessionNew, "--tint"),
        (.sessionCompanionNew, "--wait"), (.sessionCompanionNew, "--tint"), (.sessionClose, "--undoable"), (.workspaceNew, "--collapsed"),
        (.workspaceNew, "--tint"),
    ])
    func aFieldTheServerCannotBeAskedForIsRefusedByName(_ cmd: Command, _ field: String) {
        let parsed = parse(cmd, target: first.id.uuidString) { args in
            switch field {
            case "--workspace-name": args.workspaceName = "w"
            case "--create-workspace": args.createWorkspace = true
            case "--wait": args.wait = true
            case "--tint": args.tint = "red"
            case "--undoable": args.undoable = true
            default: args.collapsed = true
            }
        }

        #expect(refusal(parsed) == "\(field) is not available in a remote window")
    }

    @Test(arguments: [0, 1, 2])
    func aRequestCarryingItsOwnOperationIsRefusedBeforeAnythingIsSent(_ field: Int) {
        let parsed = parse(.sessionRename, target: first.id.uuidString) { args in
            args.name = "x"
            switch field {
            case 0: args.opID = "op-1"
            case 1: args.epoch = "e1"
            default: args.panes = [UUID().uuidString]
            }
        }

        #expect(refusal(parsed) == "operation receipts are served only by agterm-server")
    }

    @Test func aBatchIsRefused() {
        let targets = [first.id.uuidString, second.id.uuidString]
        #expect(refusal(parse(.sessionClose) { $0.targets = targets }) == "a remote window closes one session at a time")
        #expect(refusal(parse(.sessionMove) { $0.targets = targets; $0.to = "up" }) == "a remote window moves one session at a time")
    }

    @Test func anUnknownTargetIsRefusedWithTheResolversError() {
        let missing = parse(.sessionRename, target: "zzzz") { $0.name = "x" }

        #expect(refusal(missing) == ControlResolve.errorMessage(noun: "session", target: "zzzz",
                                                                 resolution: ControlResolve.resolve("zzzz", candidates: [], active: nil)))
    }

    @Test func aSessionDropBecomesAnAnchorAmongTheOtherRows() {
        let ids = [UUID(), UUID(), UUID()]
        let target = UUID()

        #expect(RemoteOperation.dropPlacement(of: ids[0], workspace: target, sessions: ids, destination: 1) == .before(ids[2]))
        #expect(RemoteOperation.dropPlacement(of: ids[2], workspace: target, sessions: ids, destination: 0) == .before(ids[0]))
        #expect(RemoteOperation.dropPlacement(of: ids[0], workspace: target, sessions: ids, destination: 2) == .after(ids[2]))
        #expect(RemoteOperation.dropPlacement(of: ids[0], workspace: target, sessions: [], destination: 0) == .workspace(target))
    }

    @Test(arguments: [(2, 0, "top"), (1, 4, "bottom"), (3, 2, "up"), (1, 2, "down"), (1, 3, nil), (2, 2, nil)] as [(Int, Int, String?)])
    func aWorkspaceDropIsOneMoveStepOrNothing(_ source: Int, _ destination: Int, _ step: String?) {
        #expect(RemoteOperation.workspaceStep(from: source, to: destination, count: 5) == step)
    }

    @Test func aCompanionWithAPlacementIsRefused() {
        #expect(refusal(parse(.sessionCompanionNew) { $0.after = second.id.uuidString })
            == "a companion takes no workspace or placement: it lands under its parent")
    }
}
