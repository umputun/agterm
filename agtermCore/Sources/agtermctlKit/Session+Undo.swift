import ArgumentParser
import agtermCore

extension Session {
    struct Undo: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Undo an undoable close while its grace lasts.",
            discussion: """
                Takes the undoID a `session close --undoable` reply carries (--json). Once the grace has ended \
                the close is final and this is refused; `recent open` reopens it from Recent Closed instead. \
                A close made through an agterm-server window is undone with the same --window.
                """)
        @Option(name: .long, help: "The undoID a 'session close --undoable --json' reply carried.") var target: String
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .sessionUndo, target: target, args: options.withWindow()) }

        func run() throws {
            let send = companionSend(SocketClient(path: options.socketPath()).send, json: options.json,
                                     tooOld: "the running app is too old for session undo")
            let reply = try send(try makeRequest())
            SocketClient.printResponse(reply, json: options.json)
            if !reply.response.ok { throw ExitCode.failure }
        }
    }
}
