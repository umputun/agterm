import ArgumentParser
import Foundation
import Testing
@testable import agtermCore
@testable import agtermctlKit

struct CatalogCommandsTests {
    private static let attachingCommands: [(argv: [String], cmd: Command)] = [
        (["session", "new"], .sessionNew),
        (["session", "new", "--parent", "p1"], .sessionCompanionNew),
        (["session", "duplicate"], .sessionDuplicate),
        (["session", "duplicate", "--companion"], .sessionCompanionDuplicate),
        (["session", "split", "on"], .sessionSplit),
        (["session", "scratch", "on", "--command", "top"], .sessionScratch),
        (["session", "restart", "--pane", "left"], .sessionRestart),
        (["session", "convert", "--companion"], .sessionCompanionConvert),
        (["recent", "open"], .recentOpen),
    ]

    private func request(_ argv: [String]) throws -> ControlRequest {
        guard let command = try Agtermctl.parseAsRoot(argv) as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test(arguments: attachingCommands)
    func everyCommandWhoseNewPaneTheCallerAttachesCarriesTheIntent(argv: [String], cmd: Command) throws {
        let held = try request(argv + ["--attach-pending"])
        let plain = try request(argv)

        #expect(held.cmd == cmd)
        #expect(held.args?.attachPending == true)
        #expect(plain.args?.attachPending == nil)
    }

    @Test func theIntentTravelsBesideAnOperationID() throws {
        let held = try request(["session", "restart", "--pane", "left", "--attach-pending", "--op-id", "op-1", "--epoch", "e1"])

        #expect(held.args?.attachPending == true)
        #expect(held.args?.opID == "op-1")
        #expect(held.args?.pane == "left")
    }

    @Test func catalogSubscribeSendsItsCommandAlone() throws {
        let subscribe = try Catalog.Subscribe.parse(["--socket", "/tmp/x.sock"])

        #expect(subscribe.makeRequest() == ControlRequest(cmd: .catalogSubscribe))
        #expect(subscribe.options.socketPath() == "/tmp/x.sock")
    }

    @Test func catalogOpNamesTheIdAsItsTarget() throws {
        let op = try Catalog.Operation.parse(["op-1"])

        #expect(op.makeRequest() == ControlRequest(cmd: .catalogOp, target: "op-1"))
    }

    @Test func catalogOpRefusesAnInvalidId() {
        #expect(throws: (any Error).self) { try Catalog.Operation.parse(["a b"]) }
    }

    @Test func catalogOpCarriesWhereTheOperationWasSent() throws {
        let op = try Catalog.Operation.parse(["op-1", "--epoch", "e1", "--rev", "7"])

        let request = op.makeRequest()

        #expect(request.args?.epoch == "e1")
        #expect(request.args?.rev == 7)
    }

    @Test func catalogOpNamesTheWindowWhoseCatalogItAsks() throws {
        let op = try Catalog.Operation.parse(["op-1", "--window", "W1"])

        #expect(op.makeRequest().args?.window == "W1")
        #expect(op.makeRequest().args?.epoch == nil)
    }

    @Test(arguments: [["op-1", "--epoch", "e1"], ["op-1", "--rev", "7"]])
    func catalogOpTakesEpochAndRevTogether(_ words: [String]) {
        #expect(throws: (any Error).self) { try Catalog.Operation.parse(words) }
    }

    @Test func aStructuralCommandCarriesTheExpectedPanes() throws {
        let first = UUID().uuidString
        let second = UUID().uuidString
        let swap = try Session.Swap.parse(["--target", "s1", "--op-id", "op-1", "--epoch", "e1", "--expect-panes", "\(first),\(second)"])

        #expect(try swap.makeRequest().args?.panes == [first, second])
    }

    @Test(arguments: [["--expect-panes", "not-a-uuid", "--op-id", "op-1", "--epoch", "e1"], ["--expect-panes", "", "--op-id", "op-1", "--epoch", "e1"],
                      ["--expect-panes", "6F9619FF-8B86-D011-B42D-00C04FC964FF"]])
    func expectedPanesAreIdentitiesSentWithAnOperation(_ flags: [String]) {
        #expect(throws: (any Error).self) { try Session.Swap.parse(["--target", "s1"] + flags) }
    }

    @Test func aStructuralCommandCarriesItsOperationIdAndEpoch() throws {
        let rename = try Session.Rename.parse(["build", "--target", "s1", "--op-id", "op-1", "--epoch", "e1"])

        let request = try rename.makeRequest()

        #expect(request.cmd == .sessionRename)
        #expect(request.args?.opID == "op-1")
        #expect(request.args?.epoch == "e1")
        #expect(request.args?.name == "build")
    }

    @Test func withoutAnOperationIdTheRequestIsUnchanged() throws {
        let swap = try Session.Swap.parse(["--target", "s1"])

        #expect(try swap.makeRequest() == ControlRequest(cmd: .sessionSwap, target: "s1"))
    }

    @Test(arguments: [["--op-id", "op-1"], ["--epoch", "e1"], ["--op-id", "a b", "--epoch", "e1"]])
    func anOperationIdAndEpochGoTogetherAndTheIdIsPlain(_ flags: [String]) {
        #expect(throws: (any Error).self) { try Workspace.Delete.parse(["--target", "w1"] + flags) }
    }

    @Test(arguments: [
        (["session", "new"], Command.sessionNew), (["session", "close"], .sessionClose), (["session", "move", "--to", "up"], .sessionMove),
        (["session", "split", "visibility"], .sessionSplit), (["session", "split", "close"], .sessionSplitClose),
        (["session", "swap"], .sessionSwap), (["workspace", "new"], .workspaceNew), (["workspace", "rename", "x"], .workspaceRename),
        (["workspace", "move", "--to", "up"], .workspaceMove), (["session", "new", "--parent", "s1"], .sessionCompanionNew),
        (["session", "overlay", "open", "--page", "--url", "https://example.com"], .sessionPage),
        (["session", "overlay", "open", "--companion", "--url", "https://example.com"], .sessionCompanionPage),
        (["session", "restart", "--pane", "left"], .sessionRestart), (["session", "duplicate", "--companion"], .sessionCompanionDuplicate),
        (["session", "convert", "--companion"], .sessionCompanionConvert), (["zmx", "kill", "--target", "s1", "--pane", "left", "--force"], .zmxKill),
    ])
    func everyStructuralCommandTakesAnOperationId(_ words: [String], _ cmd: Command) throws {
        let parsed = try Agtermctl.parseAsRoot(words + ["--op-id", "op-1", "--epoch", "e1"])
        let command = try #require(parsed as? any RequestCommand)

        let request = try command.makeRequest()

        #expect(request.cmd == cmd)
        #expect(request.args?.opID == "op-1")
        #expect(request.args?.epoch == "e1")
    }

    @Test func aPlainDuplicateRefusesAnOperationId() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "duplicate", "--op-id", "op-1", "--epoch", "e1"]) }
    }

    @Test func aPlainOverlayOpenRefusesAnOperationId() {
        #expect(throws: (any Error).self) {
            try Agtermctl.parseAsRoot(["session", "overlay", "open", "--url", "https://example.com", "--op-id", "op-1", "--epoch", "e1"])
        }
    }

    private static func page(_ configure: (inout ControlArgs) -> Void) -> ControlArgs {
        var args = ControlArgs()
        configure(&args)
        return args
    }

    @Test(arguments: [
        (true, page { $0.url = "https://example.com/-a"; $0.navigation = true; $0.javascript = true }),
        (false, page { $0.url = "http://localhost:3000"; $0.chromeless = true; $0.color = "#102030" }),
        (false, page { $0.url = "https://example.com"; $0.persistent = true; $0.browse = true }),
        (true, page { $0.html = "/srv/-doc.html"; $0.cwd = "/srv" }),
        (false, page { $0.html = "/srv/doc.html" }),
    ])
    @MainActor
    func aForwardedPageRowParsesBackToThePageItWasAskedFor(_ companion: Bool, _ args: ControlArgs) throws {
        let row = companion ? "page companion" : "page session"
        guard case .options(let asked) = ControlDispatcher.pageRowOptions(args, row: row, needsPage: "needs a page") else {
            Issue.record("the page row was refused")
            return
        }
        let anchor = UUID()
        let operation = RemoteOperation.newPage(anchor: anchor, companion: companion, page: try #require(RemotePageOptions(asked)))

        let window = UUID().uuidString
        let parsed = try Agtermctl.parseAsRoot(operation.words + ["--window", window, "--op-id", "op-1", "--epoch", "e1"])
        let request = try #require(parsed as? any RequestCommand).makeRequest()

        #expect(request.cmd == (companion ? .sessionCompanionPage : .sessionPage))
        #expect(request.target == anchor.uuidString)
        #expect(request.args?.opID == "op-1")
        #expect(request.args?.window == window)
        guard case .options(let sent) = ControlDispatcher.pageRowOptions(request.args, row: row, needsPage: "needs a page") else {
            Issue.record("the forwarded page row was refused")
            return
        }
        #expect(sent == asked)
    }
}

extension CatalogCommandsTests {
    static let anyID = UUID()
    static let everyOperation: [RemoteOperation] = [
        .newSession(workspace: anyID), .newSession(workspace: anyID, anchor: .after(anyID)),
        .newSessionInNamedWorkspace(name: "w", create: true), .newCompanion(parent: anyID),
        .setSplit(anyID, shown: true, axis: nil), .setScratch(anyID, shown: true), .closeSplit(anyID), .swap(anyID),
        .renameSession(anyID, name: "n"), .moveSession(anyID, to: .workspace(anyID)), .closeSession(anyID, undoable: true),
        .closeSessions([anyID, UUID()]), .moveSessions([anyID, UUID()], to: .before(anyID)), .setFlag(anyID, on: true),
        .clearFlags, .setTint(anyID, .clear), .setWorkspaceFlag(anyID, on: true), .setWorkspaceTint(anyID, .clear),
        .newWorkspace(name: "w"), .renameWorkspace(anyID, name: "w"), .deleteWorkspace(anyID), .moveWorkspace(anyID, to: "up"),
        .restart(anyID, pane: .left, command: nil), .duplicateCompanion(anyID), .convertCompanion(anyID),
        .killDaemon(anyID, pane: .left), .undoClose(anyID.uuidString), .reopenRecent(nil),
    ]

    @Test(arguments: everyOperation)
    func everyOperationNamesTheWindowItRunsIn(_ operation: RemoteOperation) throws {
        let window = UUID().uuidString
        let operands = operation.operands.isEmpty ? [] : ["--"] + operation.operands
        let parsed = try Agtermctl.parseAsRoot(operation.words + ["--window", window, "--op-id", "op-1", "--epoch", "e1"] + operands)
        let request = try #require(parsed as? any RequestCommand).makeRequest()

        #expect(request.args?.window == window)
        #expect(request.args?.opID == "op-1")
    }
}
