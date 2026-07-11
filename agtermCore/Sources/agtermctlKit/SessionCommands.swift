import ArgumentParser
import Foundation
import agtermCore

/// Shared `--pane` validation for the commands that accept `left|right|scratch` (session type, text, status,
/// and font). Rejects any other value with a clean usage error before the socket round-trip, matching the
/// server-side switch (so the CLI and server can't drift, and a raw socket client still hits the same check
/// server-side). These commands intentionally reuse `StatusPane`'s `left|right|scratch` value set as the
/// shared pane-addressing vocabulary — the enum is named for agent status but its cases are the pane names.
func validatePaneArgument(_ pane: String?) throws {
    if let pane, StatusPane(rawValue: pane) == nil {
        throw ValidationError("--pane must be left, right, or scratch")
    }
}

// MARK: - session

struct Session: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Session commands.",
        subcommands: [New.self, Close.self, Select.self, Go.self, Rename.self, Reveal.self, Move.self, TypeText.self,
                      Split.self, Scratch.self, Focus.self, Resize.self, Copy.self, Paste.self, SelectAll.self,
                      Text.self, Status.self, FlagCommand.self,
                      Seen.self, Search.self, Background.self, Overlay.self]
    )

    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create a session.")
        @Option(name: .long, help: "Working directory (defaults to $HOME).") var cwd: String?
        @Option(name: .long, help: "Target workspace by id/prefix/active (defaults to the current one). Mutually exclusive with --workspace-name.") var workspace: String?
        @Option(name: .long, help: "Target workspace by name; errors if not found unless --create-workspace. Mutually exclusive with --workspace.") var workspaceName: String?
        @Flag(name: .long, help: "With --workspace-name, create the workspace when it does not exist (reuse it otherwise).") var createWorkspace = false
        @Option(name: .long, help: "Run this command as the session's process instead of the login shell (no echoed command line; the session closes when it exits).") var command: String?
        @Option(name: .long, help: "Initial session name (defaults to the auto basename).") var name: String?
        @Option(name: .long, help: "Place the new session right AFTER this anchor session (id/prefix/active); the anchor carries its own workspace, replacing --workspace.") var after: String?
        @Option(name: .long, help: "Place the new session right BEFORE this anchor session (id/prefix/active); mirror of --after.") var before: String?
        @OptionGroup var options: ClientOptions
        var echoesResultID: Bool { true }

        func validate() throws {
            if after != nil, before != nil {
                throw ValidationError("use either --after or --before, not both")
            }
            // the anchor sid already names the workspace, so placement can't also address one.
            if after != nil || before != nil, workspace != nil || workspaceName != nil {
                throw ValidationError("session.new takes --after/--before or a workspace, not both")
            }
            if workspace != nil, workspaceName != nil {
                throw ValidationError("use either --workspace or --workspace-name, not both")
            }
            if createWorkspace, workspaceName == nil {
                throw ValidationError("--create-workspace requires --workspace-name")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionNew, args: options.withWindow(
                ControlArgs(name: name, cwd: cwd, workspace: workspace, workspaceName: workspaceName,
                            createWorkspace: createWorkspace ? true : nil, command: command,
                            after: after, before: before)))
        }
    }

    struct Close: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Close a session.")
        @OptionGroup var target: BatchTargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            let batchArgs = target.batchTargets.map { ControlArgs(targets: $0) }
            let args = options.withWindow(batchArgs)
            return ControlRequest(cmd: .sessionClose, target: target.targets.first ?? "active", args: args)
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

    struct Reveal: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Reveal a session's focused working directory in Finder.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionReveal, target: target.target, args: options.withWindow())
        }
    }

    struct Move: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move a session: to another workspace, reorder with --to, or place relative to an anchor with --after/--before.")
        @Argument(help: "Destination workspace id/prefix (relocate). Omit with --to or --after/--before.") var workspace: String?
        @Option(name: .long, help: "Reorder within the workspace: up, down, top, or bottom.") var to: String?
        @Option(name: .long, help: "Place right AFTER this anchor session (id/prefix/active); the anchor carries its own workspace (relocates + positions in one shot).") var after: String?
        @Option(name: .long, help: "Place right BEFORE this anchor session (id/prefix/active); mirror of --after.") var before: String?
        @OptionGroup var target: BatchTargetOptions
        @OptionGroup var options: ClientOptions

        // exactly one placement intent among {workspace positional (relocate), --to (reorder),
        // --after/--before (anchor-relative place)}; reject the empty/conflicting cases at parse time so
        // it's a clean usage error, unit-testable without a socket. The anchor carries its own workspace,
        // so placement is mutually exclusive with both --to and a destination workspace.
        func validate() throws {
            if after != nil, before != nil {
                throw ValidationError("use either --after or --before, not both")
            }
            if after != nil || before != nil {
                if to != nil {
                    throw ValidationError("session.move takes --after/--before or --to, not both")
                }
                if workspace != nil {
                    throw ValidationError("session.move takes --after/--before or a workspace, not both")
                }
                return
            }
            if target.targets.count > 1, to != nil {
                throw ValidationError("session.move --target can be repeated only with a workspace or --after/--before")
            }
            switch (workspace, to) {
            case (nil, nil): throw ValidationError("provide a destination workspace, --to, or --after/--before")
            case (.some, .some): throw ValidationError("provide a destination workspace or --to, not both")
            default: break
            }
        }

        func makeRequest() throws -> ControlRequest {
            let args: ControlArgs
            if let after {
                args = ControlArgs(after: after)
            } else if let before {
                args = ControlArgs(before: before)
            } else if let workspace {
                args = ControlArgs(workspace: workspace)
            } else {
                args = ControlArgs(to: to)
            }
            var withTargets = args
            withTargets.targets = target.batchTargets
            return ControlRequest(cmd: .sessionMove, target: target.targets.first ?? "active",
                                  args: options.withWindow(withTargets))
        }
    }

    struct TypeText: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "type", abstract: "Inject text into a session.")
        @Argument(help: "Text to inject (omit with --stdin).") var text: String?
        @Flag(name: .long, help: "Read the text from stdin instead of an argument.") var stdin = false
        @Flag(name: .long, help: "Select (and realize) a never-shown session before injecting (main pane only; a split pane must already exist).") var select = false
        @Option(name: .long, help: "Which pane to type into: left (main), right (split), or scratch (the session's scratch terminal, even when hidden). Defaults to the left pane.") var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws { try validatePaneArgument(pane) }

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
                                  args: options.withWindow(ControlArgs(text: payload, select: select, pane: pane)))
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
        @Option(name: .long, help: "When showing, run this command as the scratch's process instead of a login shell (run-once; respawns the scratch if one is already open).") var command: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionScratch, target: target.target, args: options.withWindow(ControlArgs(mode: mode, command: command)))
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

    struct Resize: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Resize a split session's divider (set or nudge the left-pane fraction).")
        @Option(name: .customLong("split-ratio"), help: "Absolute left-pane fraction 0..1 (e.g. 0.7). Clamped to 0.05..0.95.") var splitRatio: Double?
        @Option(name: .customLong("grow-left"), help: "Grow the left pane by this fraction (e.g. 0.05); shrinks the right.") var growLeft: Double?
        @Option(name: .customLong("grow-right"), help: "Grow the right pane by this fraction (e.g. 0.05); shrinks the left.") var growRight: Double?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        // exactly one of the three forms must be set; reject neither/multiple at parse time so it's a clean
        // usage error, unit-testable without a socket. Prints the applied (clamped) fraction.
        func validate() throws {
            let values = [splitRatio, growLeft, growRight].compactMap { $0 }
            guard values.count == 1 else {
                throw ValidationError("provide exactly one of --split-ratio, --grow-left, or --grow-right")
            }
            // nan/inf parse as Double but fail to JSON-encode (a generic error after the socket opens), so
            // reject non-finite input here with a clean usage error.
            guard values[0].isFinite else {
                throw ValidationError("the resize value must be a finite number")
            }
        }

        func makeRequest() throws -> ControlRequest {
            // grow-left/grow-right map to a signed wire delta (+ grows the left pane); split-ratio is absolute.
            let args: ControlArgs
            if let splitRatio {
                args = ControlArgs(ratio: splitRatio)
            } else if let growLeft {
                args = ControlArgs(ratioDelta: growLeft)
            } else {
                args = ControlArgs(ratioDelta: -(growRight ?? 0))
            }
            return ControlRequest(cmd: .sessionResize, target: target.target, args: options.withWindow(args))
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

    struct Paste: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Paste the system clipboard into a session (like ⌘V).")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionPaste, target: target.target, args: options.withWindow())
        }
    }

    struct SelectAll: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "select-all",
                                                        abstract: "Select a session's entire terminal buffer (like ⌘A).")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionSelectAll, target: target.target, args: options.withWindow())
        }
    }

    struct Text: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Print a session's terminal buffer as plain text (does not touch the system clipboard).")
        @Flag(name: .long, help: "Read the full screen + scrollback instead of just the visible screen.") var all = false
        @Option(name: .long, help: "Keep only the last N lines of the full buffer.") var lines: Int?
        @Option(name: .long, help: "Which pane to read: left (main), right (split), or scratch (the session's scratch terminal, even when hidden). Defaults to the on-screen pane.") var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            if all, lines != nil {
                throw ValidationError("use either --all or --lines, not both")
            }
            if let lines, lines <= 0 {
                throw ValidationError("--lines must be greater than 0")
            }
            try validatePaneArgument(pane)
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionText, target: target.target,
                           args: options.withWindow(ControlArgs(pane: pane, all: all ? true : nil, lines: lines)))
        }
    }

    struct Status: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Set a session's agent status indicator.")
        @Argument(help: "State: idle, active, completed, or blocked.") var state: String
        @Flag(name: .long, help: "Pulse the indicator for attention.") var blink = false
        @Flag(name: .long, help: "Reset the indicator to idle once the session is visited.") var autoReset = false
        @Option(name: .long, help: """
            Play a sound when set: 'default' (or 'beep') for the system alert sound, or a system sound \
            name (Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, \
            Submarine, Tink).
            """)
        var sound: String?
        @Option(name: .long, help: "Override the glyph tint for this call only (#rrggbb); reverts on the next status set without it.")
        var color: String?
        @Option(name: .long, help: "Which pane set this status: left (main), right (split), or scratch. Records the blocked pane so nav lands on it. Defaults to the left pane.") var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            if let color, !WatermarkConfig.isValidColorHex(color) {
                throw ValidationError("color must be a #rrggbb hex value")
            }
            try validatePaneArgument(pane)
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionStatus, target: target.target,
                           args: options.withWindow(ControlArgs(pane: pane, status: state, blink: blink ? true : nil,
                                                                 autoReset: autoReset ? true : nil, sound: sound,
                                                                 color: color)))
        }
    }

    // named `FlagCommand` (not `Flag`) so it doesn't shadow ArgumentParser's `@Flag` wrapper within
    // the `Session` namespace; `commandName` keeps the user-facing verb `flag`.
    struct FlagCommand: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "flag", abstract: "Flag a session for the flagged working-set view (on|off|toggle|clear).")
        @Argument(help: "Mode: on, off, toggle (default), or clear (unflag all; ignores --target).") var mode: String = "toggle"
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard ["on", "off", "toggle", "clear"].contains(mode) else {
                throw ValidationError("mode must be on, off, toggle, or clear")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionFlag, target: target.target, args: options.withWindow(ControlArgs(mode: mode)))
        }
    }

    struct Seen: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Clear a session's unseen-notification badge without changing the selection or focus (idempotent).")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionSeen, target: target.target, args: options.withWindow())
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

    struct Background: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "background",
            abstract: "Set or clear a session's background (image, rasterized text, or solid color).",
            subcommands: [Image.self, Text.self, Color.self, Clear.self]
        )

        /// Shared input validation against the host-free `WatermarkConfig`, so a bad value is a clean
        /// parse error before any socket round-trip, matching the server's rejection exactly. The enum
        /// checks reject `""` too, so no separate empty-string special-case is needed.
        static func validate(fit: String? = nil, position: String? = nil, opacity: Double? = nil,
                             color: String? = nil, text: String? = nil, path: String? = nil) throws {
            if let fit, !WatermarkConfig.isValidFit(fit) {
                throw ValidationError("fit must be one of: \(WatermarkConfig.validFits.joined(separator: ", "))")
            }
            if let position, !WatermarkConfig.isValidPosition(position) {
                throw ValidationError("position must be one of: \(WatermarkConfig.validPositions.joined(separator: ", "))")
            }
            if let opacity, !WatermarkConfig.isValidOpacity(opacity) {
                throw ValidationError("opacity must be between 0.0 and 1.0")
            }
            if let color, !WatermarkConfig.isValidColorHex(color) {
                throw ValidationError("color must be a #rrggbb hex value")
            }
            if let text, !WatermarkConfig.isValidText(text) {
                throw ValidationError("text must be 1–\(WatermarkConfig.maxTextLength) characters")
            }
            if let path, !WatermarkConfig.isValidImagePath(path) {
                throw ValidationError("image path must not contain control characters")
            }
        }

        struct Image: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Show a PNG or JPEG image behind the terminal (auto-fits the window).")
            @Argument(help: "Path to a PNG or JPEG image file.") var path: String
            @Option(name: .long, help: "Image opacity 0.0-1.0 (default 1.0).") var opacity: Double?
            @Option(name: .long, help: "Fit: contain (default), cover, stretch, or none.") var fit: String?
            @Option(name: .long, help: "Position: center (default) or an edge/corner anchor (top-left, bottom-right, …).") var position: String?
            @Flag(name: .customLong("repeat"), help: "Tile the image to fill blank space.") var repeatImage = false
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws { try Background.validate(fit: fit, position: position, opacity: opacity, path: path) }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionBackground, target: target.target,
                               args: options.withWindow(ControlArgs(mode: "image", path: path, opacity: opacity,
                                                                    fit: fit, position: position,
                                                                    repeats: repeatImage ? true : nil)))
            }
        }

        struct Text: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Render TEXT as a watermark behind the terminal (auto-fits the window).")
            @Argument(help: "Watermark text.") var text: String
            @Option(name: .long, help: "Text color as #rrggbb (default: the terminal foreground color).") var color: String?
            @Option(name: .long, help: "Opacity 0.0-1.0 (default 1.0).") var opacity: Double?
            @Option(name: .long, help: "Fit: contain (default), cover, stretch, or none.") var fit: String?
            @Option(name: .long, help: "Position: center (default) or an edge/corner anchor (top-left, bottom-right, …).") var position: String?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws {
                try Background.validate(fit: fit, position: position, opacity: opacity, color: color, text: text)
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionBackground, target: target.target,
                               args: options.withWindow(ControlArgs(text: text, mode: "text", color: color,
                                                                    opacity: opacity, fit: fit, position: position)))
            }
        }

        struct Color: RequestCommand {
            static let configuration = CommandConfiguration(
                abstract: "Set a solid background color for the terminal (honors the Settings window translucency).")
            @Argument(help: "Background color as #rrggbb.") var color: String
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws { try Background.validate(color: color) }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionBackground, target: target.target,
                               args: options.withWindow(ControlArgs(mode: "color", color: color)))
            }
        }

        struct Clear: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Remove the session's background (watermark or solid color).")
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionBackground, target: target.target,
                               args: options.withWindow(ControlArgs(mode: "clear")))
            }
        }
    }

    struct Overlay: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open, resize, or close an ephemeral overlay terminal on a session.",
            subcommands: [Open.self, Close.self, Resize.self, Result.self]
        )

        struct Open: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Open an overlay running COMMAND; it closes when COMMAND exits.")
            @Argument(help: "Program to run in the overlay (e.g. revdiff).") var command: String
            @Option(name: .long, help: "Working directory (default: the session's current directory).") var cwd: String?
            @Flag(name: .long, help: "Keep the overlay open after COMMAND exits (press any key to close).") var wait = false
            @Flag(name: .long, help: "Block until COMMAND exits and exit with its status (the program renders normally; capture its output via the program's own output file).") var block = false
            @Flag(name: .long, help: "Select (switch to) the target session after opening the overlay (default: open without switching).") var follow = false
            @Option(name: .long, help: "Render a floating, framed panel at PERCENT (1-100) of the pane instead of full-size.") var sizePercent: Int?
            @Option(name: .long, help: "Solid background color (#rrggbb) for the overlay pane, independent of the session's own.") var backgroundColor: String?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            // reject the mutually-exclusive combo + a malformed color at parse time (before any connection),
            // so it's a clean usage error and is unit-testable without a socket.
            func validate() throws {
                if block && wait { throw ValidationError("--block cannot be combined with --wait") }
                if let backgroundColor, !WatermarkConfig.isValidColorHex(backgroundColor) {
                    throw ValidationError("background-color must be a #rrggbb hex value")
                }
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayOpen, target: target.target,
                               args: options.withWindow(ControlArgs(cwd: cwd, command: command, wait: wait ? true : nil,
                                                                     sizePercent: sizePercent, follow: follow ? true : nil,
                                                                     color: backgroundColor)))
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
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayResult, target: target.target, args: options.withWindow())
            }
        }
    }
}
