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

    @Test(arguments: [(nil, true), ("on", true), ("off", false)] as [(String?, Bool)])
    func aScratchResolvesItsModeAgainstTheCatalogsScratch(_ mode: String?, _ shown: Bool) {
        let parsed = parse(.sessionScratch, target: first.id.uuidString) { $0.mode = mode }

        #expect(parsed == .operation(.setScratch(first.id, shown: shown), select: false))
    }

    @Test func aShownScratchTogglesOffAndAFollowedCommandIsSentAndSelects() {
        first.scratchDaemon = Session.ScratchDaemon(identity: UUID(), shown: true)

        #expect(parse(.sessionScratch, target: first.id.uuidString) == .operation(.setScratch(first.id, shown: false), select: false))
        #expect(parse(.sessionScratch, target: first.id.uuidString) { $0.mode = "on"; $0.command = "htop"; $0.follow = true }
            == .operation(.setScratch(first.id, shown: true, command: "htop"), select: true))
    }

    @Test func aScratchRefusesAnExpectedScratchAndABadMode() {
        #expect(refusal(parse(.sessionScratch) { $0.scratch = "none" }) == "operation receipts are served only by agterm-server")
        #expect(refusal(parse(.sessionScratch) { $0.mode = "sideways" }) == "invalid scratch mode: sideways")
    }

    @Test func aCompanionLandsUnderTheActiveSession() {
        #expect(parse(.sessionCompanionNew) == .operation(.newCompanion(parent: first.id), select: true))
    }

    @Test func aPageRowIsCreatedOnTheServerAndSelectedOnlyWhenFollowed() throws {
        let page = { (follow: Bool?) in
            self.parse(.sessionPage, target: self.second.id.uuidString) { $0.url = "https://example.com"; $0.follow = follow }
        }
        guard case .operation(.newPage(let anchor, let companion, let options), let select) = page(nil) else {
            Issue.record("not a page row: \(page(nil))")
            return
        }

        #expect(anchor == second.id)
        #expect(!companion)
        #expect(options.words == ["--url=https://example.com"])
        #expect(!select)
        guard case .operation(.newPage(second.id, false, _), select: true) = page(true) else {
            Issue.record("a followed page row is not selected: \(page(true))")
            return
        }
        let companionRow = parse(.sessionCompanionPage) { $0.url = "https://example.com" }
        #expect(companionRow == .operation(.newPage(anchor: first.id, companion: true, page: options), select: false))
    }

    @Test func aPageRowRefusesWhatALocalOneRefuses() {
        #expect(refusal(parse(.sessionPage) { $0.url = "https://example.com"; $0.pane = "left" })
            == "a page session is full size: it takes no --pane, --size-percent, --width or --height")
        #expect(refusal(parse(.sessionCompanionPage) { $0.command = "htop" }) == OverlayHtmlError.companionNeedsPage)
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

    @Test func aTerminateOnAServerRowIsAClose() {
        let target = first.id.uuidString

        #expect(RemoteOperation.structuralCommands.contains(.sessionTerminate))
        #expect(parse(.sessionTerminate, target: target) == .operation(.closeSession(first.id), select: false))
        #expect(parse(.sessionTerminate) { $0.targets = [target, second.id.uuidString] } == .operation(.closeSessions([first.id, second.id]), select: false))
        #expect(RemoteOperation.closeSession(first.id).words == ["session", "close", "--target", target])
        #expect(parse(.sessionTerminate, target: target) { $0.undoable = true } == .operation(.closeSession(first.id, undoable: true), select: false))
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

    @Test func anUndoableCloseAsksTheServerForItsGrace() {
        let target = first.id.uuidString

        #expect(parse(.sessionClose, target: target) { $0.undoable = true } == .operation(.closeSession(first.id, undoable: true), select: false))
        #expect(parse(.sessionClose) { $0.targets = [target, second.id.uuidString]; $0.undoable = true }
            == .operation(.closeSessions([first.id, second.id], undoable: true), select: false))
        #expect(RemoteOperation.closeSession(first.id, undoable: true).words == ["session", "close", "--target", target, "--undoable"])
        #expect(RemoteOperation.closeSessions([first.id, second.id], undoable: true).words
            == ["session", "close", "--target", target, "--target", second.id.uuidString, "--undoable"])
    }

    @Test func undoAndReopenNameNoRow() {
        #expect(RemoteOperation.undoClose("u1").words == ["session", "undo", "--target", "u1"])
        #expect(RemoteOperation.undoClose("u1").target == nil)
        #expect(RemoteOperation.reopenRecent("r1").words == ["recent", "open"])
        #expect(RemoteOperation.reopenRecent("r1").operands == ["r1"])
        #expect(RemoteOperation.reopenRecent(nil).operands == [])
    }

    @Test func aWaitingCommandIsHeldOnTheServer() {
        let shell = RemoteShellOptions(command: "make", wait: true)

        #expect(parse(.sessionNew) { $0.command = "make"; $0.wait = true } == .operation(.newSession(workspace: workspace.id, shell: shell), select: true))
        #expect(parse(.sessionCompanionNew, target: first.id.uuidString) { $0.command = "make"; $0.wait = true }
            == .operation(.newCompanion(parent: first.id, shell: shell), select: true))
    }

    @Test func aRestartNamesThePaneByTheRoleThisWindowShows() {
        first.daemonBackedPanes = [first.paneIdentity]
        let target = first.id.uuidString

        #expect(parse(.sessionRestart, target: target) { $0.pane = "split"; $0.command = "top" }
            == .operation(.restart(first.id, pane: .right, command: "top"), select: false))
        #expect(parse(.sessionRestart, target: target) { $0.paneID = first.paneIdentity.uuidString; $0.pane = "right" }
            == .operation(.restart(first.id, pane: .left, command: nil), select: false))
    }

    @Test(arguments: [
        (ControlArgs(pane: "left", paneID: "gone"), "unknown pane id: gone"),
        (ControlArgs(pane: "scratch"), "session.restart does not address the scratch pane"),
        (ControlArgs(command: "top"), "session.restart requires --pane-id or --pane"),
        (ControlArgs(command: " ", pane: "left"), "session.restart takes a non-empty command, or none to replay"),
    ])
    func aRestartRefusesWhatALocalOneRefuses(args: ControlArgs, error: String) {
        let request = ControlRequest(cmd: .sessionRestart, target: first.id.uuidString, args: args)

        #expect(refusal(RemoteOperation.parse(request, in: store)) == error)
    }

    @Test func companionDuplicateAndConvertGoToTheServer() {
        let target = first.id.uuidString

        #expect(parse(.sessionCompanionDuplicate, target: target) == .operation(.duplicateCompanion(first.id), select: true))
        #expect(parse(.sessionCompanionDuplicate, target: target) { $0.noSelect = true } == .operation(.duplicateCompanion(first.id), select: false))
        #expect(parse(.sessionCompanionConvert, target: target) == .operation(.convertCompanion(first.id), select: false))
    }

    @Test func aCompanionMoveGoesToTheServerWithTheCallersIndex() throws {
        let companion = try store.addCompanion(to: first.id, options: CompanionOptions(select: false)).get()

        let parsed = parse(.sessionCompanionMove, target: companion.id.uuidString) { $0.parent = String(second.id.uuidString.prefix(8)); $0.index = 3 }

        #expect(parsed == .operation(.moveCompanion(companion.id, parent: second.id, index: 3), select: false))
    }

    @Test func aCompanionMoveKeepsTheLocalRefusals() throws {
        let companion = try store.addCompanion(to: first.id, options: CompanionOptions(select: false)).get()
        let target = companion.id.uuidString

        #expect(refusal(parse(.sessionCompanionMove, target: target)) == "session.companion.move needs a parent")
        #expect(refusal(parse(.sessionCompanionMove, target: target) { $0.parent = second.id.uuidString; $0.index = -1 }) == "index must be 0 or more")
        #expect(refusal(parse(.sessionCompanionMove, target: target) { $0.parent = target }) == "the new parent must be a top-level session")
        #expect(refusal(parse(.sessionCompanionMove, target: first.id.uuidString) { $0.parent = second.id.uuidString }) == "not a companion")
        #expect(refusal(parse(.sessionCompanionMove, target: target) { $0.parent = UUID().uuidString })?.isEmpty == false)
    }

    @Test(arguments: [
        ((nil, [], []), nil),
        ((0, [], []), 0),
        ((0, ["b"], ["a", "b"]), 1),
        ((1, ["b", "c"], ["b", "a", "c"]), 2),
        ((2, ["b", "c"], ["b", "c", "a"]), 2),
        ((5, ["b"], ["b", "a"]), 1),
    ] as [((Int?, [String], [String]), Int?)])
    func aVisibleSlotMapsToTheServersGroupPastItsDetachedRows(drop: (slot: Int?, visible: [String], group: [String]), expected: Int?) {
        let ids = Dictionary(uniqueKeysWithValues: ["a", "b", "c"].map { ($0, UUID()) })
        let index = RemoteOperation.companionIndex(slot: drop.slot, visible: drop.visible.compactMap { ids[$0] },
                                                   group: drop.group.compactMap { ids[$0] })
        #expect(index == expected)
    }

    @Test func aKillNamesOnePaneAndKeepsTheLocalRefusals() {
        let target = first.id.uuidString

        #expect(parse(.zmxKill, target: target) { $0.pane = "split"; $0.force = true } == .operation(.killDaemon(first.id, pane: .right), select: false))
        #expect(refusal(parse(.zmxKill, target: "active") { $0.pane = "left"; $0.force = true }) == "zmx.kill needs a session id; 'active' is not accepted")
        #expect(refusal(parse(.zmxKill, target: target) { $0.force = true }) == "zmx.kill requires --pane left|right")
        #expect(refusal(parse(.zmxKill, target: target) { $0.pane = "left" }) == "zmx.kill requires --force")
        #expect(RemoteOperation.structuralCommands.contains(.zmxKillPane))
        #expect(parse(.zmxKillPane, target: target) { $0.pane = "left"; $0.force = true; $0.paneID = "tok" }
            == .operation(.killDaemon(first.id, pane: .left, paneID: "tok"), select: false))
        #expect(refusal(parse(.zmxKillPane, target: target) { $0.pane = "left"; $0.force = true }) == "zmx.kill.pane requires --pane-id")
        #expect(refusal(parse(.zmxKillPane, target: target) { $0.pane = "left" }) == "zmx.kill.pane requires --force")
        #expect(parse(.zmxKill, target: target) { $0.pane = "left"; $0.force = true; $0.paneID = "tok" }
            == .operation(.killDaemon(first.id, pane: .left), select: false))
    }

    @Test func creationOptionsGoToTheServer() {
        let tint = SidebarTint(color: .red, parts: [.name])

        let named = parse(.sessionNew) { $0.workspaceName = "ops"; $0.createWorkspace = true; $0.tint = "red"; $0.tintOn = ["name"] }
        let companion = parse(.sessionCompanionNew, target: first.id.uuidString) { $0.tint = "red"; $0.tintOn = ["name"] }
        let workspace = parse(.workspaceNew) { $0.name = "x"; $0.collapsed = true; $0.tint = "red"; $0.tintOn = ["name"] }

        #expect(named == .operation(.newSessionInNamedWorkspace(name: "ops", create: true, shell: RemoteShellOptions(tint: tint)), select: true))
        #expect(companion == .operation(.newCompanion(parent: first.id, shell: RemoteShellOptions(tint: tint)), select: true))
        #expect(workspace == .operation(.newWorkspace(name: "x", collapsed: true, tint: tint), select: false))
    }

    @Test(arguments: [
        ("both", "use either --workspace or --workspace-name, not both"),
        ("create", "--create-workspace requires --workspace-name"),
        ("anchor", "session.new takes --after/--before or a workspace, not both"),
        ("tint", "invalid tint: mauve (\(TintValue.validValuesList))"),
    ])
    func aContradictoryNewSessionIsRefusedAsLocally(_ shape: String, _ error: String) {
        let parsed = parse(.sessionNew) { args in
            switch shape {
            case "both": args.workspace = workspace.id.uuidString; args.workspaceName = "w"
            case "create": args.createWorkspace = true
            case "anchor": args.after = first.id.uuidString; args.workspaceName = "w"
            default: args.tint = "mauve"
            }
        }

        #expect(refusal(parsed) == error)
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

    @Test func aBatchIsOneServerCommand() {
        let targets = [first.id.uuidString, second.id.uuidString, first.id.uuidString]
        let other = store.addWorkspace(name: "o")

        #expect(parse(.sessionClose) { $0.targets = targets } == .operation(.closeSessions([first.id, second.id]), select: false))
        #expect(parse(.sessionMove) { $0.targets = targets; $0.workspace = other.id.uuidString }
            == .operation(.moveSessions([first.id, second.id], to: .workspace(other.id)), select: false))
        #expect(refusal(parse(.sessionMove) { $0.targets = targets; $0.to = "up" }) == "session.move --to takes one session")
        #expect(parse(.sessionClose) { $0.targets = [second.id.uuidString] } == .operation(.closeSession(second.id), select: false))
    }

    @Test func anEmptyBatchIsRefusedRatherThanReadAsTheActiveSession() {
        store.selectSession(first.id)

        #expect(refusal(parse(.sessionClose) { $0.targets = [] }) == "session.close requires at least one --target")
        #expect(refusal(parse(.sessionMove) { $0.targets = []; $0.workspace = workspace.id.uuidString })
            == "session.move requires at least one --target")
    }

    @Test func aFlagIsSentAsTheValueTheRowShouldHaveAndAClearAsOne() {
        let target = first.id.uuidString
        store.setFlag(true, forSession: second.id)

        #expect(parse(.sessionFlag, target: target) == .operation(.setFlag(first.id, on: true), select: false))
        #expect(parse(.sessionFlag, target: second.id.uuidString) == .operation(.setFlag(second.id, on: false), select: false))
        #expect(parse(.sessionFlag, target: target) { $0.mode = "off" } == .operation(.setFlag(first.id, on: false), select: false))
        #expect(parse(.sessionFlag) { $0.mode = "clear" } == .operation(.clearFlags, select: false))
        #expect(refusal(parse(.sessionFlag, target: target) { $0.mode = "sideways" }) == "invalid flag mode: sideways")
        #expect(refusal(parse(.sessionFlag) { $0.mode = "clear"; $0.before = target }) == "--before and --after apply only to session.flag move")
        #expect(parse(.workspaceFlag, target: workspace.id.uuidString) == .operation(.setWorkspaceFlag(workspace.id, on: true), select: false))
    }

    @Test func aTintIsSentAsParsedLocally() {
        #expect(parse(.sessionTint, target: first.id.uuidString) { $0.mode = "set"; $0.tint = "Red"; $0.tintOn = ["name"] }
            == .operation(.setTint(first.id, .set(.named(.red), parts: [.name])), select: false))
        #expect(parse(.workspaceTint, target: workspace.id.uuidString) { $0.mode = "clear" }
            == .operation(.setWorkspaceTint(workspace.id, .clear), select: false))
        #expect(refusal(parse(.sessionTint, target: first.id.uuidString) { $0.mode = "clear"; $0.tint = "red" })
            == "session.tint clear takes no color or placement")
    }

    @Test func eachOperationSpellsItsOptionsAsTheCLIDoes() {
        let id = first.id, other = second.id
        let tint = SidebarTint(color: .hex("#ff8800"), parts: [.icon, .name])

        #expect(RemoteOperation.newSessionInNamedWorkspace(name: "-ops", create: true, shell: RemoteShellOptions(tint: tint)).words
            == ["session", "new", "--workspace-name=-ops", "--create-workspace", "--tint=#ff8800", "--tint-on=icon,name"])
        #expect(RemoteOperation.newWorkspace(name: "x", collapsed: true, tint: SidebarTint(color: .red)).words
            == ["workspace", "new", "--collapsed", "--tint=red", "--tint-on=icon"])
        #expect(RemoteOperation.closeSessions([id, other]).words == ["session", "close", "--target", id.uuidString, "--target", other.uuidString])
        #expect(RemoteOperation.moveSessions([id, other], to: .after(other)).words
            == ["session", "move", "--target", id.uuidString, "--target", other.uuidString, "--after", other.uuidString])
        #expect(RemoteOperation.setFlag(id, on: false).words == ["session", "flag", "off", "--target", id.uuidString])
        #expect(RemoteOperation.clearFlags.words == ["session", "flag", "clear"])
        #expect(RemoteOperation.setTint(id, .set(.named(.red), parts: [.name, .icon])).words
            == ["session", "tint", "red", "--on", "icon,name", "--target", id.uuidString])
        #expect(RemoteOperation.setTint(id, .set(.named(.red), parts: nil)).words == ["session", "tint", "red", "--target", id.uuidString])
        #expect(RemoteOperation.setWorkspaceTint(id, .clear).words == ["workspace", "tint", "clear", "--target", id.uuidString])
        #expect(RemoteOperation.setWorkspaceFlag(id, on: true).words == ["workspace", "flag", "on", "--target", id.uuidString])
        #expect(RemoteOperation.newCompanion(parent: id, shell: RemoteShellOptions(command: "make", wait: true)).words
            == ["session", "new", "--parent", id.uuidString, "--command=make", "--wait"])
        #expect(RemoteOperation.restart(id, pane: .right, command: "-x").words
            == ["session", "restart", "--target", id.uuidString, "--pane", "right", "--command=-x"])
        #expect(RemoteOperation.restart(id, pane: .left, command: nil).words == ["session", "restart", "--target", id.uuidString, "--pane", "left"])
        #expect(RemoteOperation.duplicateCompanion(id).words == ["session", "duplicate", "--companion", "--target", id.uuidString])
        #expect(RemoteOperation.convertCompanion(id).words == ["session", "convert", "--companion", "--target", id.uuidString])
        #expect(RemoteOperation.moveCompanion(id, parent: id, index: 2).words
            == ["session", "move", "--target", id.uuidString, "--parent", id.uuidString, "--index", "2"])
        #expect(RemoteOperation.moveCompanion(id, parent: id, index: nil).words == ["session", "move", "--target", id.uuidString, "--parent", id.uuidString])
        #expect(RemoteOperation.moveCompanion(id, parent: id, index: nil).label == "Move Companion")
        #expect(RemoteOperation.killDaemon(id, pane: .left).words == ["zmx", "kill", "--target", id.uuidString, "--pane", "left", "--force"])
        #expect(RemoteOperation.killDaemon(id, pane: .right, paneID: "tok").words
            == ["zmx", "kill", "--target", id.uuidString, "--pane", "right", "--pane-id", "tok", "--force"])
    }

    @Test func aFlaggedOrderMoveStaysOnThisMac() {
        let move = ControlRequest(cmd: .sessionFlag, target: first.id.uuidString, args: ControlArgs(mode: "move"))

        #expect(RemoteOperation.runsLocally(move, in: store))
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
