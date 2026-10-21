import ArgumentParser
import Foundation
import agtermCore

extension Session.Overlay {
    struct PageServe: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "page-serve",
            abstract: "Carry a handed-over page's channel between stdin/stdout and this app.",
            discussion: """
            Run on this Mac by the agterm on another Mac, over ssh, when it shows one of this app's pages: it \
            claims the page with its single-use token and then copies the channel both ways untouched, so the \
            page's files and bridge requests are served by this app. It is not meant to be run by hand. A \
            refused token exits 1 with the reason on stderr.
            """)

        @Argument(help: "The token the other Mac was handed with the page.")
        var token: String

        @OptionGroup var options: BasicOptions

        func makeRequest() -> ControlRequest { ControlRequest(cmd: .sessionOverlayPageServe, target: token) }

        func run() throws {
            let socket = try SocketClient(path: options.socketPath()).connect()
            defer { close(socket) }
            let bridge = StreamBridge(socket: socket, input: STDIN_FILENO, output: STDOUT_FILENO)
            do {
                try bridge.open(makeRequest())
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                throw ExitCode.failure
            }
            bridge.pump()
        }
    }
}
