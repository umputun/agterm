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

/// The root `agtermctl` command. Subcommands mirror the control catalog 1:1.
public struct Agtermctl: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "agtermctl",
        abstract: "Drive agterm over its control socket.",
        subcommands: [Tree.self, Workspace.self, Session.self, Window.self, Quick.self, Sidebar.self, Notify.self, Font.self, Keymap.self]
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

// MARK: - workspace

struct Workspace: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Workspace commands.",
        subcommands: [New.self, Rename.self, Delete.self, Select.self, Move.self]
    )

    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create a workspace.")
        @Argument(help: "Workspace name (defaults to the auto-generated name).") var name: String?
        @OptionGroup var options: ClientOptions
        var echoesResultID: Bool { true }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceNew, args: options.withWindow(ControlArgs(name: name)))
        }
    }

    struct Rename: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a workspace.")
        @Argument(help: "New workspace name.") var name: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceRename, target: target.target, args: options.withWindow(ControlArgs(name: name)))
        }
    }

    struct Delete: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a workspace.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceDelete, target: target.target, args: options.withWindow())
        }
    }

    struct Select: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Select a workspace.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceSelect, target: target.target, args: options.withWindow())
        }
    }

    struct Move: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Reorder a workspace among its siblings.")
        @Option(name: .long, help: "Direction: up, down, top, or bottom.") var to: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceMove, target: target.target, args: options.withWindow(ControlArgs(to: to)))
        }
    }
}

// MARK: - session

struct Session: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Session commands.",
        subcommands: [New.self, Close.self, Select.self, Go.self, Rename.self, Move.self, TypeText.self, Split.self, Scratch.self, Focus.self, Copy.self, Status.self, Search.self, Overlay.self]
    )

    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create a session.")
        @Option(name: .long, help: "Working directory (defaults to $HOME).") var cwd: String?
        @Option(name: .long, help: "Target workspace id/prefix (defaults to the current one).") var workspace: String?
        @Option(name: .long, help: "Run this command as the session's process instead of the login shell (no echoed command line; the session closes when it exits).") var command: String?
        @OptionGroup var options: ClientOptions
        var echoesResultID: Bool { true }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionNew, args: options.withWindow(ControlArgs(cwd: cwd, workspace: workspace, command: command)))
        }
    }

    struct Close: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Close a session.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionClose, target: target.target, args: options.withWindow())
        }
    }

    struct Select: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Select a session.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionSelect, target: target.target, args: options.withWindow())
        }
    }

    struct Go: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "go",
            abstract: "Navigate sessions: next|prev|first|last|next-attention|prev-attention.")
        @Option(name: .long, help: "Direction: next, prev, first, last, next-attention, or prev-attention (attention = blocked/completed).") var to: String
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionGo, args: options.withWindow(ControlArgs(to: to)))
        }
    }

    struct Rename: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a session.")
        @Argument(help: "New session name.") var name: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionRename, target: target.target, args: options.withWindow(ControlArgs(name: name)))
        }
    }

    struct Move: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Move a session to another workspace, or reorder it with --to.")
        @Argument(help: "Destination workspace id/prefix (relocate). Omit with --to.") var workspace: String?
        @Option(name: .long, help: "Reorder within the workspace: up, down, top, or bottom.") var to: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        // exactly one of the workspace positional (relocate) or --to (reorder) must be set; reject the
        // neither/both cases at parse time so it's a clean usage error, unit-testable without a socket.
        func validate() throws {
            switch (workspace, to) {
            case (nil, nil): throw ValidationError("provide a destination workspace or --to")
            case (.some, .some): throw ValidationError("provide a destination workspace or --to, not both")
            default: break
            }
        }

        func makeRequest() throws -> ControlRequest {
            let args = workspace.map { ControlArgs(workspace: $0) } ?? ControlArgs(to: to)
            return ControlRequest(cmd: .sessionMove, target: target.target, args: options.withWindow(args))
        }
    }

    struct TypeText: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "type", abstract: "Inject text into a session.")
        @Argument(help: "Text to inject (omit with --stdin).") var text: String?
        @Flag(name: .long, help: "Read the text from stdin instead of an argument.") var stdin = false
        @Flag(name: .long, help: "Select (and realize) a never-shown session before injecting.") var select = false
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            let payload: String
            if stdin {
                // non-UTF8 stdin decodes to nil and injects nothing — terminal input is UTF-8 text.
                let data = FileHandle.standardInput.readDataToEndOfFile()
                payload = String(data: data, encoding: .utf8) ?? ""
            } else if let text {
                payload = text
            } else {
                throw ValidationError("provide TEXT or --stdin")
            }
            return ControlRequest(cmd: .sessionType, target: target.target,
                                  args: options.withWindow(ControlArgs(text: payload, select: select)))
        }
    }

    struct Split: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Show or hide a session split (on|off|toggle).")
        @Argument(help: "Mode: on (show), off (hide), or toggle (default). Hidden panes stay alive.") var mode: String = "toggle"
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionSplit, target: target.target, args: options.withWindow(ControlArgs(mode: mode)))
        }
    }

    struct Scratch: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Show or hide a session scratch terminal (on|off|toggle).")
        @Argument(help: "Mode: on (show), off (hide), or toggle (default). The hidden scratch shell stays alive.") var mode: String = "toggle"
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionScratch, target: target.target, args: options.withWindow(ControlArgs(mode: mode)))
        }
    }

    struct Focus: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Focus a split session's pane (left|right|other).")
        @Argument(help: "Pane: left, right, or other (toggle, default).") var pane: String = "other"
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionFocus, target: target.target, args: options.withWindow(ControlArgs(pane: pane)))
        }
    }

    struct Copy: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Print a session's selected text (does not touch the system clipboard).")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionCopy, target: target.target, args: options.withWindow())
        }
    }

    struct Status: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Set a session's agent status indicator.")
        @Argument(help: "State: idle, active, completed, or blocked.") var state: String
        @Flag(name: .long, help: "Pulse the indicator for attention.") var blink = false
        @Flag(name: .long, help: "Reset the indicator to idle once the session is visited.") var autoReset = false
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionStatus, target: target.target,
                           args: options.withWindow(ControlArgs(status: state, blink: blink ? true : nil,
                                                                 autoReset: autoReset ? true : nil)))
        }
    }

    struct Search: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Search a session's terminal output (open the bar, set a needle, or step matches).")
        @Argument(help: "Needle to search for (omit to just open the bar).") var needle: String?
        @Flag(name: .long, help: "Step to the next match.") var next = false
        @Flag(name: .long, help: "Step to the previous match.") var prev = false
        @Flag(name: .long, help: "Close the search bar.") var close = false
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        // the three navigation flags are mutually exclusive; reject 2+ at parse time so it's a clean
        // usage error, unit-testable without a socket. a needle alongside --close is also rejected: close
        // ignores the needle, so the combo is a usage error rather than a silent no-op.
        func validate() throws {
            if [next, prev, close].filter({ $0 }).count > 1 {
                throw ValidationError("--next, --prev, and --close are mutually exclusive")
            }
            if close, needle != nil {
                throw ValidationError("--close cannot be combined with a needle")
            }
        }

        func makeRequest() throws -> ControlRequest {
            let to = next ? "next" : prev ? "prev" : close ? "close" : nil
            return ControlRequest(cmd: .sessionSearch, target: target.target,
                                  args: options.withWindow(ControlArgs(text: needle, to: to)))
        }
    }

    struct Overlay: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open or close an ephemeral overlay terminal on a session.",
            subcommands: [Open.self, Close.self, Result.self]
        )

        struct Open: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Open an overlay running COMMAND; it closes when COMMAND exits.")
            @Argument(help: "Program to run in the overlay (e.g. revdiff).") var command: String
            @Option(name: .long, help: "Working directory (default: the session's current directory).") var cwd: String?
            @Flag(name: .long, help: "Keep the overlay open after COMMAND exits (press any key to close).") var wait = false
            @Flag(name: .long, help: "Block until COMMAND exits and exit with its status (the program renders normally; capture its output via the program's own output file).") var block = false
            @Option(name: .long, help: "Render a floating, framed panel at PERCENT (1-100) of the pane instead of full-size.") var sizePercent: Int?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            // reject the mutually-exclusive combo at parse time (before any connection), so it's a clean
            // usage error and is unit-testable without a socket.
            func validate() throws {
                if block && wait { throw ValidationError("--block cannot be combined with --wait") }
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayOpen, target: target.target,
                               args: options.withWindow(ControlArgs(cwd: cwd, command: command, wait: wait ? true : nil,
                                                                     sizePercent: sizePercent)))
            }

            func run() throws {
                guard block else { try defaultRun(); return }
                let client = SocketClient(path: options.socketPath())
                // open via the same `makeRequest()` the non-block path uses (DRY): in block mode `validate()`
                // guarantees `!wait`, so its `wait` is nil — identical to opening non-wait, and the floating
                // `--size-percent` is carried through the single source instead of a duplicated ControlArgs.
                let opened = try client.send(makeRequest())
                guard opened.ok, let id = opened.result?.id else {
                    SocketClient.printResponse(opened, json: options.json)
                    throw ExitCode.failure
                }
                // poll session.overlay.result until the program exits. target the returned id with NO
                // window scope: the id is globally unique and resolves cross-window, so a frontmost-window
                // change during the run can't make the poll miss the session.
                while true {
                    let res = try client.send(ControlRequest(cmd: .sessionOverlayResult, target: id))
                    if res.ok {
                        if options.json { SocketClient.printResponse(res, json: true) }
                        // a successful result must carry the status; its absence is a protocol violation, not success.
                        guard let code = res.result?.exitCode else {
                            FileHandle.standardError.write(Data("error: result missing exit code\n".utf8))
                            throw ExitCode.failure
                        }
                        throw ExitCode(rawValue: Int32(code))
                    }
                    if res.error == OverlayResultError.stillRunning {
                        Thread.sleep(forTimeInterval: 0.1)
                        continue
                    }
                    SocketClient.printResponse(res, json: options.json)
                    throw ExitCode.failure
                }
            }
        }

        struct Close: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Close the overlay terminal (destroys it).")
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayClose, target: target.target, args: options.withWindow())
            }
        }

        struct Result: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Print the overlay program's exit status (errors if it is still running or never ran).")
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayResult, target: target.target, args: options.withWindow())
            }
        }
    }
}

// MARK: - window

struct Window: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Window commands.",
        subcommands: [New.self, List.self, Select.self, Close.self, Rename.self, Delete.self, Resize.self, Move.self]
    )

    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create and open a window.")
        @Argument(help: "Window name (defaults to the auto-generated name).") var name: String?
        @OptionGroup var options: BasicOptions
        var echoesResultID: Bool { true }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .windowNew, args: ControlArgs(name: name))
        }
    }

    struct List: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "List windows (id, name, open, active).")
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowList) }
    }

    struct Select: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Select (raise or open) a window.")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowSelect, target: id) }
    }

    struct Close: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Close a window (its bundle is kept).")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowClose, target: id) }
    }

    struct Rename: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a window.")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String
        @Argument(help: "New window name.") var name: String
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .windowRename, target: id, args: ControlArgs(name: name))
        }
    }

    struct Delete: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a window (keeps at least one).")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowDelete, target: id) }
    }

    struct Resize: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Resize a window (frame size in points).")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @Option(help: "New width in points.") var width: Int
        @Option(help: "New height in points.") var height: Int
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .windowResize, target: id, args: ControlArgs(width: width, height: height))
        }
    }

    struct Move: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Move a window (top-left x,y in points, relative to a display).")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @Option(help: "Left edge x in points, from the display's left.") var x: Int
        @Option(help: "Top edge y in points, from the display's top.") var y: Int
        @Option(help: "Display index (default: the window's current display).") var display: Int?
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .windowMove, target: id, args: ControlArgs(x: x, y: y, display: display))
        }
    }
}

// MARK: - keymap

struct Keymap: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keymap commands.",
        subcommands: [Reload.self]
    )

    struct Reload: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Re-read and apply keymap.conf (prints the diagnostic count).")
        // keymap.reload is app-global (the frontmost window's settings model), so no `--window` selector.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .keymapReload) }
    }
}

// MARK: - quick

struct Quick: RequestCommand {
    static let configuration = CommandConfiguration(abstract: "Quick terminal (show|hide|toggle).")
    @Argument(help: "Mode: show, hide, or toggle (default).") var mode: String = "toggle"
    // the quick terminal is always the frontmost window's, so this carries no `--window` selector.
    @OptionGroup var options: BasicOptions

    func makeRequest() throws -> ControlRequest {
        ControlRequest(cmd: .quick, args: ControlArgs(mode: mode))
    }
}

// MARK: - sidebar

struct Sidebar: RequestCommand {
    static let configuration = CommandConfiguration(abstract: "Sidebar visibility (show|hide|toggle).")
    @Argument(help: "Mode: show, hide, or toggle (default).") var mode: String = "toggle"
    // the sidebar is always the frontmost window's, so this carries no `--window` selector.
    @OptionGroup var options: BasicOptions

    func makeRequest() throws -> ControlRequest {
        ControlRequest(cmd: .sidebar, args: ControlArgs(mode: mode))
    }
}

// MARK: - notify

struct Notify: RequestCommand {
    static let configuration = CommandConfiguration(abstract: "Post a desktop notification (default: the active session of the frontmost window).")
    @Argument(help: "Notification body.") var body: String
    @Option(name: .long, help: "Notification title (defaults to the session name).") var title: String?
    @OptionGroup var target: TargetOptions
    @OptionGroup var options: ClientOptions

    func makeRequest() throws -> ControlRequest {
        ControlRequest(cmd: .notify, target: target.target, args: options.withWindow(ControlArgs(title: title, body: body)))
    }
}

// MARK: - font

struct Font: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Font size commands.",
        subcommands: [Inc.self, Dec.self, Reset.self]
    )

    struct Inc: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Increase font size.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .fontInc, target: target.target, args: options.withWindow())
        }
    }

    struct Dec: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Decrease font size.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .fontDec, target: target.target, args: options.withWindow())
        }
    }

    struct Reset: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Reset font size.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .fontReset, target: target.target, args: options.withWindow())
        }
    }
}
