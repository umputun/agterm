import Foundation
import Testing
@testable import agtermCore

@MainActor
struct OriginCatalogScopeTests {
    private let store = makeStore()
    private let other = makeStore()
    private let work: Workspace
    private let row: Session
    private let attached: Session
    private let elsewhere: Session

    init() throws {
        work = store.addWorkspace(name: "work")
        row = try #require(store.addSession(toWorkspace: work.id, cwd: "/w"))
        attached = try #require(store.addSession(toWorkspace: work.id, cwd: "/r", remoteHost: "box", remoteSessionID: "s1"))
        let away = other.addWorkspace(name: "away")
        elsewhere = try #require(other.addSession(toWorkspace: away.id, cwd: "/e"))
    }

    private func refusal(_ cmd: Command, target: String? = nil, args: ControlArgs = ControlArgs()) -> String? {
        OriginCatalogScope.refusal(ControlRequest(cmd: cmd, target: target, args: args), in: store)
    }

    @Test(arguments: [Command.sessionRename, .sessionClose, .sessionSplit, .sessionRestart, .zmxKill, .sessionCompanionNew, .sessionFlag])
    func aRowOfThisWindowIsInScope(_ cmd: Command) {
        #expect(refusal(cmd, target: row.id.uuidString) == nil)
    }

    @Test func theWindowsOwnRootIsInScopeAndAnotherWindowsIsNot() throws {
        store.ensureRoot()
        other.ensureRoot()
        var own = ControlArgs()
        own.workspace = try #require(store.rootWorkspace).id.uuidString
        var foreign = ControlArgs()
        foreign.workspace = try #require(other.rootWorkspace).id.uuidString

        #expect(refusal(.sessionMove, target: row.id.uuidString, args: own) == nil)
        #expect(refusal(.sessionMove, target: row.id.uuidString, args: foreign) == "no workspace \(foreign.workspace ?? "") in this window")
    }

    @Test func aRowOfAnotherWindowIsRefused() {
        #expect(refusal(.sessionRename, target: elsewhere.id.uuidString) == "no session \(elsewhere.id.uuidString) in this window")
    }

    @Test func everyBatchTargetIsChecked() {
        var args = ControlArgs()
        args.targets = [row.id.uuidString, elsewhere.id.uuidString]

        #expect(refusal(.sessionClose, target: row.id.uuidString, args: args) == "no session \(elsewhere.id.uuidString) in this window")
    }

    @Test func anAnchorIsChecked() {
        var after = ControlArgs()
        after.after = elsewhere.id.uuidString
        var before = ControlArgs()
        before.before = attached.id.uuidString

        #expect(refusal(.sessionMove, target: row.id.uuidString, args: after) == "no session \(elsewhere.id.uuidString) in this window")
        #expect(refusal(.sessionNew, args: before)
            == "session \(attached.id.uuidString) is attached from box and is not part of this window's catalog")
    }

    @Test func aCompanionsNewParentIsChecked() {
        var away = ControlArgs()
        away.parent = elsewhere.id.uuidString
        var hidden = ControlArgs()
        hidden.parent = attached.id.uuidString
        var here = ControlArgs()
        here.parent = row.id.uuidString

        #expect(refusal(.sessionCompanionMove, target: row.id.uuidString, args: away) == "no session \(elsewhere.id.uuidString) in this window")
        #expect(refusal(.sessionCompanionMove, target: row.id.uuidString, args: hidden)
            == "session \(attached.id.uuidString) is attached from box and is not part of this window's catalog")
        #expect(refusal(.sessionCompanionMove, target: row.id.uuidString, args: here) == nil)
    }

    @Test func aDestinationWorkspaceIsChecked() throws {
        let away = try #require(other.workspaces.first)
        var args = ControlArgs()
        args.workspace = away.id.uuidString

        #expect(refusal(.sessionMove, target: row.id.uuidString, args: args) == "no workspace \(away.id.uuidString) in this window")
        args.workspace = work.id.uuidString
        #expect(refusal(.sessionMove, target: row.id.uuidString, args: args) == nil)
    }

    @Test func aRowAttachedFromAnotherHostIsNeverATarget() {
        #expect(refusal(.sessionClose, target: attached.id.uuidString)
            == "session \(attached.id.uuidString) is attached from box and is not part of this window's catalog")
    }

    @Test func aWorkspaceCommandTakesThisWindowsWorkspace() throws {
        let away = try #require(other.workspaces.first)

        #expect(refusal(.workspaceRename, target: work.id.uuidString) == nil)
        #expect(refusal(.workspaceTint, target: work.id.uuidString) == nil)
        #expect(refusal(.workspaceFlag, target: work.id.uuidString) == nil)
        #expect(refusal(.workspaceMove, target: away.id.uuidString) == "no workspace \(away.id.uuidString) in this window")
    }

    @Test func deletingAWorkspaceHoldingAttachedRowsIsRefusedWithTheCount() throws {
        #expect(refusal(.workspaceDelete, target: work.id.uuidString)
            == "workspace work holds 1 session attached from other hosts, which a remote window does not show; delete it on this Mac")

        let plain = store.addWorkspace(name: "plain")
        #expect(refusal(.workspaceDelete, target: plain.id.uuidString) == nil)
    }

    @Test func aShortOrActiveTargetIsRefused() {
        #expect(refusal(.sessionRename, target: "active") == "no session active in this window")
        #expect(refusal(.sessionRename, target: String(row.id.uuidString.prefix(8)))
            == "no session \(String(row.id.uuidString.prefix(8))) in this window")
    }

    @Test(arguments: [Command.sessionUndo, .recentOpen, .workspaceNew])
    func aCommandWithoutRowTargetsIsLeftToItsOwnScope(_ cmd: Command) {
        #expect(refusal(cmd, target: "undo-1") == nil)
    }

    @Test(arguments: [Command.sessionRename, .sessionClose, .sessionSplit, .sessionFlag, .workspaceDelete, .workspaceRename])
    func aTargetedOperationWithoutATargetIsRefused(_ cmd: Command) {
        #expect(refusal(cmd) == "\(cmd.rawValue) from a remote window names its target")
    }

    @Test func operationsWithNoRowTargetNeedNone() {
        var clear = ControlArgs()
        clear.mode = "clear"

        #expect(refusal(.sessionNew) == nil)
        #expect(refusal(.workspaceNew) == nil)
        #expect(refusal(.sessionFlag, args: clear) == nil)
        #expect(refusal(.recentOpen) == nil)
    }
}
