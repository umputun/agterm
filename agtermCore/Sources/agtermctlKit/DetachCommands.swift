import ArgumentParser
import Foundation
import agtermCore

// MARK: - detach and reattach, a remote window's rows

/// DetachedTargetOptions name a hidden row, which has no `active`: a detached id or a unique prefix of one.
struct DetachedTargetOptions: ParsableArguments {
    @Option(name: .long, help: "Detached id or unique prefix, as tree's remote.detachedSessions / detachedWorkspaces list it.")
    var target: String

    func validate() throws {
        guard target.lowercased() != "active" else { throw ValidationError("a detached row is never 'active'; pass its id") }
    }
}

extension Session {
    struct Detach: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Hide a remote window's sessions on this Mac and leave them running on the server.",
            discussion: "A parent takes its companions with it. Reattach brings a session back; session close ends it.")
        @OptionGroup var target: BatchTargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            let args = ControlArgs(targets: target.batchTargets)
            return ControlRequest(cmd: .sessionDetach, target: target.targets.first ?? "active",
                                  args: options.withWindow(args == ControlArgs() ? nil : args))
        }
    }

    struct Reattach: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Show a detached session of a remote window again.")
        @OptionGroup var target: DetachedTargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionReattach, target: target.target, args: options.withWindow())
        }
    }
}

extension Workspace {
    struct Detach: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Hide a remote window's workspace and its sessions on this Mac, leaving them running on the server.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceDetach, target: target.target, args: options.withWindow())
        }
    }

    struct Reattach: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Show a detached workspace of a remote window again.")
        @OptionGroup var target: DetachedTargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceReattach, target: target.target, args: options.withWindow())
        }
    }
}

extension Window.Remote {
    struct Dismiss: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Drop a remote window's marks for actions whose outcome it could not learn.")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowRemoteDismiss, target: id) }
    }
}
