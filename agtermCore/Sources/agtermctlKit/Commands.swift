import ArgumentParser
import Foundation
import agtermCore

/// The connection/print surface every subcommand shares: where to connect and how to print. The
/// `RequestCommand.run()` default drives only these, so a command's options can be `BasicOptions`
/// (socket/json only, for `window.*` which target via the positional id) or `ClientOptions` (those
/// plus `--window`).
protocol ConnectionOptions {
    /// Print the raw JSON response instead of a human-readable line.
    var json: Bool { get }

    /// Resolve the socket path from `--socket` and the environment.
    func socketPath(env: [String: String]) -> String
}

extension ConnectionOptions {
    func socketPath() -> String { socketPath(env: ProcessInfo.processInfo.environment) }
}

/// Where to connect and how to print — the options every subcommand accepts. `window.*` commands use
/// this directly (they target via the positional id, so `--window` has no meaning for them); the
/// session/workspace/tree/font commands layer `--window` on top via `ClientOptions`.
struct BasicOptions: ParsableArguments, ConnectionOptions {
    /// Override the resolved socket path. Defaults to the `AGTERM_STATE_DIR`/app-support rendezvous.
    @Option(name: .long, help: "Override the control socket path.")
    var socket: String?

    @Flag(name: .long, help: "Print the raw JSON response.")
    var json = false

    /// Resolve the socket path: explicit `--socket`, else the agtermCore rendezvous resolver. Precedence:
    /// `--socket` → `<AGTERM_STATE_DIR>/agterm.sock` → `<$HOME>/Library/Application Support/agterm/agterm.sock` →
    /// `/tmp/agterm/agterm.sock`. `env` is injectable so the precedence is unit-testable; production passes the
    /// process environment.
    func socketPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let socket { return socket }
        let appSupport = (env["HOME"].map { ($0 as NSString).appendingPathComponent("Library/Application Support/agterm") })
            ?? "/tmp/agterm"
        return ControlResolve.socketPath(stateDir: env["AGTERM_STATE_DIR"], appSupport: appSupport)
    }
}

/// `BasicOptions` plus the `--window` selector for the commands that operate on a window's tree.
struct ClientOptions: ParsableArguments, ConnectionOptions {
    @OptionGroup var basic: BasicOptions

    /// Target window for session/workspace/tree/font commands: id / prefix / `active` (=frontmost).
    /// Selects the window whose tree the command operates on; maps to `ControlArgs.window`.
    @Option(name: .long, help: "Target window id, unique prefix, or 'active' (defaults to the frontmost).")
    var window: String?

    var json: Bool { basic.json }

    func socketPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String { basic.socketPath(env: env) }

    /// Fold the `--window` selector into an existing args bag, or build one carrying only the window.
    /// Returns `nil` when there is no window and no base bag, so the request stays in its compact form
    /// (no empty `args` object on the wire) and matches the no-window request value.
    func withWindow(_ base: ControlArgs? = nil) -> ControlArgs? {
        guard window != nil else { return base }
        var args = base ?? ControlArgs()
        args.window = window
        return args
    }
}

/// Options for the commands that address a single session or workspace; `--target` defaults to `active`.
struct TargetOptions: ParsableArguments {
    @Option(name: .long, help: "Target session/workspace id, unique prefix, or 'active'.")
    var target: String = "active"
}

/// Options for batch-capable session commands. Repeating `--target` preserves CLI order on the wire.
struct BatchTargetOptions: ParsableArguments {
    @Option(name: .customLong("target"), help: "Target session id, prefix, or 'active'. Repeat for a batch.")
    var targets: [String] = []

    var batchTargets: [String]? { targets.count > 1 ? targets : nil }
}

/// Options for commands that address an individual terminal surface from `tree`.
struct SurfaceTargetOptions: ParsableArguments {
    @Option(name: .long, help: "Target surface id from tree, 'quick' (the quick terminal), or 'active'.")
    var target: String = "active"
}

/// The root `agtermctl` command. Subcommands mirror the control catalog 1:1.
public struct Agtermctl: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "agtermctl",
        abstract: "Drive agterm over its control socket.",
        subcommands: [Tree.self, Workspace.self, Session.self, Surface.self, Dashboard.self, Window.self, Quick.self,
                      Sidebar.self, Notify.self, Font.self, Keymap.self, Config.self, Theme.self, Restore.self]
    )

    public init() {}
}

/// A subcommand that knows how to build the `ControlRequest` it should send. The default `run()`
/// sends it and prints the response; tests build the request directly via `makeRequest()`. `Options`
/// is `ClientOptions` for the window-targeting commands and `BasicOptions` for `window.*`.
protocol RequestCommand: ParsableCommand {
    associatedtype Options: ParsableArguments & ConnectionOptions
    var options: Options { get }
    func makeRequest() throws -> ControlRequest
    /// Whether the human-readable output should echo `result.id`. Default false — the id is just noise
    /// when the caller already named the target; the create commands (`*.new`) override it to true,
    /// since the new id isn't known until the command runs. The id is always present under `--json`.
    var echoesResultID: Bool { get }
}

extension RequestCommand {
    var echoesResultID: Bool { false }
    public func run() throws { try defaultRun() }

    /// The default behavior: send the request once and print the response. Named separately so a command
    /// that overrides `run()` (the `--block` overlay path) can still reach the single-round-trip path.
    func defaultRun() throws {
        let request = try makeRequest()
        let client = SocketClient(path: options.socketPath())
        let response = try client.send(request)
        SocketClient.printResponse(response, json: options.json, echoID: echoesResultID)
        if !response.ok { throw ExitCode.failure }
    }
}

// MARK: - tree

struct Tree: RequestCommand {
    static let configuration = CommandConfiguration(abstract: "Print the workspace/session tree.")
    @OptionGroup var options: ClientOptions

    func makeRequest() throws -> ControlRequest {
        ControlRequest(cmd: .tree, args: options.withWindow())
    }
}
