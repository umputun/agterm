import ArgumentParser
import Foundation
import agtermCore

extension Session {
    struct Close: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Close a session.")
        @OptionGroup var target: BatchTargetOptions
        @Flag(name: .long, help: "Give a single close ⌘W's undo grace, so undo inside it brings the running shell back; closes at once when Settings turns undo off.")
        var undoable = false
        @Flag(name: .long, help: "End a session attached from another host on that host, not only here; any other session closes as without it.")
        var terminate = false
        @Option(name: .long, help: """
            Close one local session if these comma-separated companion UUIDs match. Pass an empty string for none.
            Use one full UUID for --target.
            """)
        var expectCompanions: String?
        @Option(name: .long, help: """
            Target window id, unique prefix, or 'active' for ordinary close. Omit to use the usual session lookup.
            With --expect-companions, use a full local window UUID. An open remote window requires it.
            """)
        var window: String?
        @OptionGroup var options: BasicOptions
        @OptionGroup var operation: OperationOptions

        func makeRequest() throws -> ControlRequest {
            if let expectCompanions {
                return try checkedRequest(expectCompanions)
            }
            let args = ControlArgs(targets: target.batchTargets, window: window, undoable: undoable ? true : nil)
            return operation.stamp(ControlRequest(cmd: terminate ? .sessionTerminate : .sessionClose,
                                                  target: target.targets.first ?? "active",
                                                  args: args == ControlArgs() ? nil : args))
        }

        private func checkedRequest(_ list: String) throws -> ControlRequest {
            guard target.targets.count == 1, let id = target.targets.first, UUID(uuidString: id) != nil else {
                throw ValidationError("--expect-companions requires one --target with a full session UUID")
            }
            if let window, UUID(uuidString: window) == nil {
                throw ValidationError("--expect-companions requires a full UUID for --window")
            }
            guard !undoable, !terminate else {
                throw ValidationError("--expect-companions cannot be combined with --undoable or --terminate")
            }
            guard operation.opID == nil, operation.epoch == nil, operation.expectPanes == nil else {
                throw ValidationError("--expect-companions cannot be combined with catalog operation options")
            }
            let companions = try (list.isEmpty ? [] : list.split(separator: ",", omittingEmptySubsequences: false)).map { part in
                guard let uuid = UUID(uuidString: String(part)) else {
                    throw ValidationError("--expect-companions takes full companion UUIDs separated by commas")
                }
                return uuid
            }
            return ControlRequest(cmd: .sessionCloseChecked, target: id, args: ControlArgs(window: window, expectCompanions: companions))
        }

        func run() throws {
            if expectCompanions != nil {
                return try runCompanionRequest(makeRequest(), options: options, echoID: false,
                                               tooOld: "the running app is too old for checked close")
            }
            guard terminate else { return try defaultRun() }
            let send = companionSend(SocketClient(path: options.socketPath()).send, json: options.json,
                                     tooOld: "the running app is too old for terminate")
            let reply = try send(try makeRequest())
            SocketClient.printResponse(reply, json: options.json)
            if !reply.response.ok { throw ExitCode.failure }
        }
    }
}
