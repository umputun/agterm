import ArgumentParser
import Foundation
import agtermCore

// MARK: - catalog

/// OperationOptions carry a structural command's operation id and the catalog epoch it was decided at, so
/// agterm-server runs it at most once and answers with a receipt. A Mac app refuses both.
struct OperationOptions: ParsableArguments {
    @Option(name: .customLong("op-id"), help: "Operation id agterm-server keeps a receipt under; needs --epoch.")
    var opID: String?

    @Option(name: .long, help: "The catalog epoch the operation was decided at; needs --op-id.")
    var epoch: String?

    @Option(name: .customLong("expect-panes"), help: "Comma-separated pane identities the target session must still have; needs --op-id.")
    var expectPanes: String?

    func validate() throws {
        guard (opID == nil) == (epoch == nil) else { throw ValidationError("--op-id and --epoch go together") }
        if let opID, !CatalogReceipt.isValidOpID(opID) {
            throw ValidationError("--op-id takes 1 to 128 letters, digits, '.', '_', ':' or '-'")
        }
        guard let expectPanes else { return }
        guard opID != nil else { throw ValidationError("--expect-panes needs --op-id") }
        guard !panes(expectPanes).isEmpty, panes(expectPanes).allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw ValidationError("--expect-panes takes pane identities separated by commas")
        }
    }

    private func panes(_ list: String) -> [String] {
        list.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// stamp adds the operation id and epoch to `request`, and leaves it as it was when neither is set.
    func stamp(_ request: ControlRequest) -> ControlRequest {
        guard let opID else { return request }
        var request = request
        var args = request.args ?? ControlArgs()
        args.opID = opID
        args.epoch = epoch
        args.panes = expectPanes.map(panes)
        request.args = args
        return request
    }
}

struct Catalog: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Carry agterm-server's catalog to a remote window on a Mac.",
        discussion: """
        agterm-server keeps one catalog of workspaces, sessions and panes; a remote window on a Mac mirrors it. \
        Only agterm-server serves these commands. A Mac app refuses them.
        """,
        subcommands: [Subscribe.self, Operation.self]
    )

    struct Operation: RequestCommand {
        static let configuration = CommandConfiguration(
            commandName: "op",
            abstract: "Ask agterm-server what became of an operation id.",
            discussion: """
            Answers from agterm-server's operation table: applied (with the revision it reached), no change, \
            refused, fenced, or unknown. An id it does not hold is recorded so that command is refused if it \
            arrives later: fenced, or unknown when the table may have dropped its entry since --epoch and --rev.
            """)

        @Argument(help: "The operation id a structural command was sent with.")
        var opID: String

        @Option(name: .long, help: "The catalog epoch the operation was sent at; needs --rev.")
        var epoch: String?

        @Option(name: .long, help: "The catalog revision the operation was sent at; needs --epoch.")
        var rev: Int?

        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard CatalogReceipt.isValidOpID(opID) else {
                throw ValidationError("an operation id is 1 to 128 letters, digits, '.', '_', ':' or '-'")
            }
            guard (epoch == nil) == (rev == nil) else { throw ValidationError("--epoch and --rev go together") }
        }

        func makeRequest() -> ControlRequest {
            var args = ControlArgs()
            args.epoch = epoch
            args.rev = rev
            return ControlRequest(cmd: .catalogOp, target: opID, args: epoch == nil ? nil : args)
        }
    }

    struct Subscribe: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Carry the catalog stream between stdin/stdout and agterm-server.",
            discussion: """
            Run by a Mac's remote window over ssh. Stdout carries newline-delimited JSON frames and nothing \
            else: the snapshot, then every change as a numbered delta. Stdin takes the other side's frames. \
            It is not meant to be run by hand. A refusal exits nonzero with the reason on stderr.
            """)

        @OptionGroup var options: BasicOptions

        func makeRequest() -> ControlRequest { ControlRequest(cmd: .catalogSubscribe) }

        func run() throws {
            let socket = try SocketClient(path: options.socketPath()).connect()
            defer { close(socket) }
            let bridge = StreamBridge(socket: socket, input: STDIN_FILENO, output: STDOUT_FILENO)
            try bridge.open(makeRequest())
            bridge.pump()
        }
    }
}
