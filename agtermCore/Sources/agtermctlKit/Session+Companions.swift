import ArgumentParser
import Foundation
import agtermCore

/// tooOldForCompanions names the reply an app predating companions gives: it cannot decode the command, so it
/// refused the request before doing anything. Every other error is the server's own and passes through.
func tooOldForCompanions(_ response: ControlResponse, command: Command) -> Bool {
    guard !response.ok, let error = response.error else { return false }
    return error.hasPrefix("invalid request:") && error.contains(command.rawValue)
}

/// companionSend wraps a sender so a companion request an old app refused reads as that, under `--json` the raw reply.
func companionSend(_ send: @escaping (ControlRequest) throws -> SocketReply, json: Bool) -> (ControlRequest) throws -> SocketReply {
    { request in
        let reply = try send(request)
        if !json, tooOldForCompanions(reply.response, command: request.cmd) {
            FileHandle.standardError.write(Data("error: the running app is too old for companions\n".utf8))
            throw ExitCode.failure
        }
        return reply
    }
}

func runCompanionRequest(_ request: ControlRequest, options: ClientOptions, echoID: Bool) throws {
    let reply = try SocketClient(path: options.socketPath()).send(request)
    if !options.json, tooOldForCompanions(reply.response, command: request.cmd) {
        FileHandle.standardError.write(Data("error: the running app is too old for companions\n".utf8))
        throw ExitCode.failure
    }
    SocketClient.printResponse(reply, json: options.json, echoID: echoID)
    if !reply.response.ok { throw ExitCode.failure }
}

extension Session {
    struct Collapse: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Fold a parent session's companions in the sidebar tree.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionCollapse, target: target.target, args: options.withWindow())
        }
    }

    struct Expand: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Unfold a parent session's companions in the sidebar tree.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionExpand, target: target.target, args: options.withWindow())
        }
    }
}
