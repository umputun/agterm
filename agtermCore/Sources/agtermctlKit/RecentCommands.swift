import ArgumentParser
import agtermCore

struct Recent: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Recently closed sessions and workspaces (File > Open Recent).",
        subcommands: [List.self, Open.self, Clear.self]
    )

    struct List: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "List recently closed sessions and workspaces, newest first.",
            discussion: "One row per entry: its id, kind, title and subtitle. The list keeps the last 20 entries "
                + "and drops the oldest silently; --json adds the close time and the session ids each entry restores. "
                + "--window naming an agterm-server window lists that server's entries."
        )
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .recentList, args: options.withWindow()) }
    }

    struct Open: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reopen a recently closed session or workspace (the newest when no id is given).",
            discussion: "The entry comes back with its id, split, flag, context and restore pins. It goes to "
                + "--window or the frontmost window, unless another window already holds its session or "
                + "workspace; --json names the window it went to. The window is not raised. An entry "
                + "whose restore was incomplete stays in the list."
        )
        @Argument(help: "Entry id or unique prefix, from 'recent list'.") var id: String?
        @OptionGroup var options: ClientOptions
        @OptionGroup var operation: OperationOptions
        @OptionGroup var attach: AttachOptions

        func makeRequest() throws -> ControlRequest {
            attach.stamp(operation.stamp(ControlRequest(cmd: .recentOpen, target: id, args: options.withWindow())))
        }
    }

    struct Clear: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Empty the recently closed list.",
            discussion: "--window naming an agterm-server window empties that server's list."
        )
        @OptionGroup var options: ClientOptions
        @OptionGroup var operation: OperationOptions

        func makeRequest() throws -> ControlRequest {
            operation.stamp(ControlRequest(cmd: .recentClear, args: options.withWindow()))
        }
    }
}
