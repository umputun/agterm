import ArgumentParser
import Foundation
import agtermCore

// MARK: - session overlay

/// The `session overlay` subcommand tree. Split out of `SessionCommands.swift` for the type size limit.
extension Session {
    struct Overlay: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open, read, resize, or close an ephemeral overlay terminal on a session.",
            subcommands: [Open.self, Close.self, Resize.self, Result.self, Copy.self, Text.self]
        )

        /// `--pane` validation for the overlay commands: the two pane roles only, deliberately NOT the shared
        /// `validatePaneArgument`, which also accepts `scratch` — there is no scratch pane to cover, and
        /// reusing it would send `scratch` to the socket instead of failing as a usage error.
        static func validatePane(_ pane: String?) throws {
            if let pane, OverlayPane(controlName: pane) == nil {
                throw ValidationError("--pane must be left or right")
            }
        }

        struct Open: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Open an overlay running COMMAND; it closes when COMMAND exits.")
            @Argument(help: "Program to run in the overlay (e.g. revdiff).") var command: String
            @Option(name: .long, help: "Working directory (default: the session's current directory).") var cwd: String?
            @Flag(name: .long, help: "Keep the overlay open after COMMAND exits (press any key to close).") var wait = false
            @Flag(name: .long, help: "Block until COMMAND exits and exit with its status (the program renders normally; capture its output via the program's own output file).") var block = false
            @Flag(name: .long, help: "Select (switch to) the target session after opening the overlay (default: open without switching).") var follow = false
            @Option(name: .long, help: "Render a floating, framed panel at PERCENT (1-100) of the pane instead of full-size.") var sizePercent: Int?
            @Option(name: .long, help: "Solid background color (#rrggbb) for the overlay pane, independent of the session's own.") var backgroundColor: String?
            @Option(name: .long, help: """
                Scope the overlay to ONE split pane (primary/left/top or split/right/bottom), leaving the sibling pane live and \
                visible; omit for the session-wide overlay. A pane overlay is always full-pane, so this \
                cannot be combined with --size-percent.
                """)
            var pane: String?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            // reject the mutually-exclusive combos + a malformed color at parse time (before any connection),
            // so it's a clean usage error and is unit-testable without a socket.
            func validate() throws {
                if block && wait { throw ValidationError("--block cannot be combined with --wait") }
                if let backgroundColor, !WatermarkConfig.isValidColorHex(backgroundColor) {
                    throw ValidationError("background-color must be a #rrggbb hex value")
                }
                try Overlay.validatePane(pane)
                if pane != nil, sizePercent != nil {
                    throw ValidationError("--pane cannot be combined with --size-percent (pane overlays are always full)")
                }
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayOpen, target: target.target,
                               args: options.withWindow(ControlArgs(cwd: cwd, command: command, wait: wait ? true : nil,
                                                                     sizePercent: sizePercent, follow: follow ? true : nil,
                                                                     pane: pane, color: backgroundColor)))
            }

            /// The `--block` poll request. Extracted from `run()` so the `--pane` forwarding is assertable
            /// without a live socket: polling a pane overlay with no pane reads the session-wide slot and
            /// blocks forever. No window scope — the returned id is globally unique and resolves cross-window,
            /// so a frontmost-window change during the run cannot make the poll miss the session.
            func resultRequest(id: String) -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayResult, target: id, args: pane.map { ControlArgs(pane: $0) })
            }

            func run() throws {
                guard block else { try defaultRun(); return }
                let client = SocketClient(path: options.socketPath())
                // open via the same `makeRequest()` as the non-block path: in block mode `validate()` guarantees
                // `!wait`, so its `wait` is nil, and the floating `--size-percent` rides that single source
                // instead of a duplicated ControlArgs.
                let opened = try client.send(makeRequest())
                guard opened.ok, let id = opened.result?.id else {
                    SocketClient.printResponse(opened, json: options.json)
                    throw ExitCode.failure
                }
                while true {
                    let res = try client.send(resultRequest(id: id))
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
            @Option(name: .long, help: "Close that split pane's overlay (primary/left/top or split/right/bottom); omit for the session-wide overlay.")
            var pane: String?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws { try Overlay.validatePane(pane) }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayClose, target: target.target,
                               args: options.withWindow(pane.map { ControlArgs(pane: $0) }))
            }
        }

        struct Resize: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Resize an open overlay: floating at a percent, or back to full-pane.")
            @Option(name: .long, help: "Resize to a floating, framed panel at PERCENT (1-100) of the pane.") var sizePercent: Int?
            @Flag(name: .long, help: "Resize to full-pane (translucent, hides the session).") var full = false
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            // require exactly one of --size-percent / --full at parse time (before any connection), so it is a
            // clean usage error and unit-testable without a socket; the dispatcher re-checks the same rules.
            func validate() throws {
                if full && sizePercent != nil { throw ValidationError("--full cannot be combined with --size-percent") }
                if !full && sizePercent == nil { throw ValidationError("provide --size-percent PERCENT or --full") }
                if let sizePercent, !(1...100).contains(sizePercent) {
                    throw ValidationError("--size-percent must be between 1 and 100")
                }
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayResize, target: target.target,
                               args: options.withWindow(ControlArgs(sizePercent: sizePercent, full: full ? true : nil)))
            }
        }

        struct Result: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Print the overlay program's exit status (errors if it is still running or never ran).")
            @Option(name: .long, help: "Read that split pane's overlay status (primary/left/top or split/right/bottom); omit for the session-wide overlay.")
            var pane: String?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws { try Overlay.validatePane(pane) }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayResult, target: target.target,
                               args: options.withWindow(pane.map { ControlArgs(pane: $0) }))
            }
        }

        struct Copy: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Print the selection made INSIDE the overlay (session copy reads the pane underneath).")
            @Option(name: .long, help: "Read that split pane's overlay (primary/left/top or split/right/bottom); omit for the session-wide overlay.")
            var pane: String?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws { try Overlay.validatePane(pane) }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayCopy, target: target.target,
                               args: options.withWindow(pane.map { ControlArgs(pane: $0) }))
            }
        }

        struct Text: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Print the overlay's terminal buffer as plain text (a TUI's drawn screen, wrapped as rendered).")
            @Flag(name: .long, help: "Read the full screen + scrollback instead of just the visible screen.") var all = false
            @Option(name: .long, help: "Keep only the last N lines of the full buffer.") var lines: Int?
            @Option(name: .long, help: "Read that split pane's overlay (primary/left/top or split/right/bottom); omit for the session-wide overlay.")
            var pane: String?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            // same order as the dispatcher, so the CLI and the socket reject the same call the same way.
            func validate() throws {
                if all, lines != nil {
                    throw ValidationError("use either --all or --lines, not both")
                }
                if let lines, lines <= 0 {
                    throw ValidationError("--lines must be greater than 0")
                }
                try Overlay.validatePane(pane)
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayText, target: target.target,
                               args: options.withWindow(ControlArgs(pane: pane, all: all ? true : nil, lines: lines)))
            }
        }
    }
}
