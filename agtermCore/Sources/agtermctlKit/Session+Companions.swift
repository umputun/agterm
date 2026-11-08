import ArgumentParser
import Foundation
import agtermCore

/// companionSend wraps a sender so a request an old app refused as an unknown command reads as `tooOld`,
/// under `--json` the raw reply.
func companionSend(_ send: @escaping (ControlRequest) throws -> SocketReply, json: Bool,
                   tooOld: String = "the running app is too old for companions") -> (ControlRequest) throws -> SocketReply {
    { request in
        let reply = try send(request)
        if !json, reply.response.refusesUnknown(request.cmd) {
            FileHandle.standardError.write(Data("error: \(tooOld)\n".utf8))
            throw ExitCode.failure
        }
        return reply
    }
}

func runCompanionRequest(_ request: ControlRequest, options: ClientOptions, echoID: Bool,
                         tooOld: String = "the running app is too old for companions") throws {
    let reply = try companionSend(SocketClient(path: options.socketPath()).send, json: options.json, tooOld: tooOld)(request)
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

    /// `--companion` is required so the verb names what the session becomes, the CLI form of Convert to Companion.
    struct Convert: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Convert a session into a companion of a fresh session opened in its place; prints the fresh session's id.")
        @Flag(name: .long, help: "Nest the session, with its companions, under a fresh session in its directory and slot.")
        var companion = false
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            if !companion { throw ValidationError("session convert needs --companion") }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionCompanionConvert, target: target.target, args: options.withWindow())
        }

        func run() throws {
            let send = companionSend(SocketClient(path: options.socketPath()).send, json: options.json,
                                     tooOld: "the running app is too old for convert")
            let reply = try send(try makeRequest())
            if options.json || !reply.response.ok {
                SocketClient.printResponse(reply, json: options.json)
            } else if let parent = reply.response.result?.parent {
                print(parent)
            }
            if !reply.response.ok { throw ExitCode.failure }
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
