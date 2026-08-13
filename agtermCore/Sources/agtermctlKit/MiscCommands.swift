import ArgumentParser
import Foundation
import agtermCore

// MARK: - keymap

struct Keymap: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keymap commands.",
        subcommands: [Reload.self, List.self]
    )

    struct Reload: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Re-read and apply keymap.conf (prints the diagnostic count).")
        // the keymap commands are app-global (the frontmost window's settings model), so no `--window`.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .keymapReload) }
    }

    struct List: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the resolved keymap and the live menu key equivalents.",
            discussion: """
            Prints every built-in with the binds the keymap resolved for it — the menu shortcut first, then \
            any monitor-bound alternatives, joined with `|` — plus the custom commands, any \
            parse diagnostics, and the key equivalents the menu bar is actually carrying. The last \
            section is what makes a stale or hijacked chord visible: SwiftUI rebuilds the menu only on \
            the next app activation, so a chord can be right in the keymap and wrong in the menu.
            """
        )
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .keymapList) }
    }
}

// MARK: - config

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Config commands.",
        subcommands: [Reload.self]
    )

    struct Reload: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Re-read and apply the agterm-scoped ghostty.conf (prints the diagnostic count).")
        // config.reload is app-global (one settings model + GhosttyApp), so no `--window` selector.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .configReload) }
    }
}

// MARK: - restore

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore-running-command commands.",
        subcommands: [Clear.self]
    )

    struct Clear: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clear every session's saved foreground command so the next restart restores plain shells.",
            discussion: """
            This is app-global and CAPTURE-scoped: it drops the foreground commands agterm captured at \
            quit, across every open window, and leaves per-session restore-command overrides alone.

            Not to be confused with `agtermctl session restore --clear`, which is per-session and \
            OVERRIDE-scoped: it drops one pane's pinned command so that pane goes back to auto-capture.
            """)
        // restore.clear is app-global (clears every open window), so no `--window` selector.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .restoreClear) }
    }
}

// MARK: - theme

struct Theme: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Theme commands.",
        subcommands: [Set.self, List.self]
    )

    struct Set: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set + persist the terminal theme, per slot.",
            discussion: """
            theme set NAME            set the light/single theme (a dark theme, if set, is kept)
            theme set --dark NAME     set the dark theme — the terminal then tracks the macOS \
            Light/Dark appearance (the light side seeds from the current theme)
            theme set --dark none     clear the dark theme (stop tracking the appearance)
            theme set                 ghostty's built-in default (clears everything)
            """)
        @Argument(help: "Light/single theme name (a bundled theme); omit for ghostty's built-in default.") var name: String?
        @Option(help: "Light-appearance theme (same slot as NAME).") var light: String?
        @Option(help: "Dark-appearance theme, or 'none' to clear it.") var dark: String?
        // theme is app-global (one settings model), so no `--window` selector.
        @OptionGroup var options: BasicOptions

        func validate() throws {
            if name != nil && light != nil {
                throw ValidationError("Pass either a NAME or --light, not both.")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .themeSet, args: ControlArgs(name: name, light: light, dark: dark))
        }
    }

    struct List: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "List bundled themes (the current one marked).")
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .themeList) }
    }
}

// MARK: - quick

struct Quick: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Quick terminal: visibility, type into it, read its text.",
        subcommands: [Visibility.self, TypeText.self, Text.self],
        defaultSubcommand: Visibility.self
    )

    /// `agtermctl quick [show|hide|toggle]` — the default subcommand, so the bare verb keeps working.
    struct Visibility: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "visibility", abstract: "Quick terminal visibility (show|hide|toggle).")
        @Argument(help: "Mode: show, hide, or toggle (default).") var mode: String = "toggle"
        // the quick terminal is always the frontmost window's, so this carries no `--window` selector.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .quick, args: ControlArgs(mode: mode))
        }
    }

    /// `agtermctl quick type TEXT` — inject literal keystrokes into the quick terminal, the twin of
    /// `session type`. No `--target`/`--window`: always the frontmost window's.
    struct TypeText: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "type", abstract: "Inject text into the quick terminal.")
        @Argument(help: "Text to inject (omit with --stdin).") var text: String?
        @Flag(name: .long, help: "Read the text from stdin instead of an argument.") var stdin = false
        @OptionGroup var options: BasicOptions

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
            return ControlRequest(cmd: .quickType, args: ControlArgs(text: payload))
        }
    }

    /// `agtermctl quick text` — print the frontmost window's quick-terminal buffer as plain text, the
    /// read-back for `quick type`; does not touch the system clipboard. No `--pane`: one surface only.
    struct Text: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "text", abstract: "Print the quick terminal's buffer as plain text.")
        @Flag(name: .long, help: "Read the full screen + scrollback instead of just the visible screen.") var all = false
        @Option(name: .long, help: "Keep only the last N lines of the full buffer.") var lines: Int?
        @OptionGroup var options: BasicOptions

        func validate() throws {
            if all, lines != nil {
                throw ValidationError("use either --all or --lines, not both")
            }
            if let lines, lines <= 0 {
                throw ValidationError("--lines must be greater than 0")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .quickText, args: ControlArgs(all: all ? true : nil, lines: lines))
        }
    }
}

// MARK: - surface

struct Surface: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Terminal surface commands.",
        subcommands: [Zoom.self]
    )

    struct Zoom: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Zoom a terminal surface (show|hide|toggle).")
        @Argument(help: "Mode: show, hide, or toggle (default).") var mode: String = "toggle"
        @OptionGroup var target: SurfaceTargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .surfaceZoom, target: target.target,
                           args: options.withWindow(ControlArgs(mode: mode)))
        }
    }
}

// MARK: - dashboard

/// Opens a view-only grid of the named sessions (max 9), or of the window's most-recently-used sessions
/// with `--mru`; `--close` closes the open one. An id may carry a `:left`/`:right` pane suffix to place one
/// pane of a split session (#331). The dispatcher validates flags and pane grammar; the 9-cell cap, the
/// session+pane dedup, and the drop report are app-side, since expanding an id into cells needs the store.
struct Dashboard: RequestCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a view-only grid of live sessions, or --close the open one.",
        discussion: """
        dashboard S1 S2 S3                 open a grid of the named sessions (ids or unique prefixes, max 9)
        dashboard S1:left                  place only the main pane of a split session
        dashboard S1:left S2:right         mix panes across sessions; a bare id still takes all of its panes
        dashboard S1 S2 --font-size 12     open with an absolute cell font size (points)
        dashboard S1 S2 --auto-size        open sizing cells relative to the Settings default font
        dashboard --mru                    open a grid of the window's most-recently-used sessions (up to 9)
        dashboard --mru --auto-size        the same, sizing cells relative to the Settings default font
        dashboard S1 --window W            open in a specific window (defaults to the frontmost)
        dashboard --close                  close the open dashboard

        The 9-cell cap counts PANES, so a split session normally takes two of them. A pane suffix keeps the
        pane you want and frees the other cell; `:right` on a session with no split is reported as
        unresolved. The suffix is the same form `tree --json` reports in `dashboardMembers`.
        """)
    @Argument(help: """
        Session ids (or unique prefixes) to show, max 9. Each may carry a :left/:right pane suffix; a bare \
        id takes every pane of the session. Omit only with --mru or --close.
        """) var ids: [String] = []
    @Option(name: .customLong("font-size"), help: "Absolute cell font size in points (mutually exclusive with --auto-size).") var fontSize: Double?
    @Flag(name: .long, help: "Size cells relative to the Settings default font, shrinking as the grid grows.") var autoSize = false
    @Flag(name: .long, help: "Populate the grid from the window's most-recently-used sessions (up to 9).") var mru = false
    @Flag(name: .long, help: "Close the open dashboard (takes no ids, --mru, or font options).") var close = false
    @OptionGroup var options: ClientOptions

    // reject invalid flag combinations at parse time — clean usage errors, no socket; re-checked server-side.
    func validate() throws {
        if close {
            guard ids.isEmpty, !mru, fontSize == nil, !autoSize else {
                throw ValidationError("--close takes no ids, --mru, or font options")
            }
            return
        }
        if mru, !ids.isEmpty {
            throw ValidationError("--mru cannot be combined with session ids")
        }
        guard !ids.isEmpty || mru else {
            throw ValidationError("dashboard requires at least one session id (or --mru, or --close)")
        }
        if fontSize != nil, autoSize {
            throw ValidationError("--font-size is mutually exclusive with --auto-size")
        }
        // nan/inf parse as Double but aren't valid sizes; reject non-finite/non-positive with a clean error.
        if let fontSize, !fontSize.isFinite || fontSize <= 0 {
            throw ValidationError("--font-size must be a positive number")
        }
    }

    func makeRequest() throws -> ControlRequest {
        let args = ControlArgs(targets: ids.isEmpty ? nil : ids,
                               close: close ? true : nil,
                               fontSize: fontSize,
                               autoSize: autoSize ? true : nil,
                               mru: mru ? true : nil)
        return ControlRequest(cmd: .dashboard, args: options.withWindow(args))
    }
}

// MARK: - pick

/// Native fuzzy-picker commands. `Open` is the default, so the shell-friendly common case is simply
/// `printf 'one\ntwo\n' | agtermctl pick`; `result`/`cancel` make `--no-block` usable without the protocol.
struct Pick: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open, poll, or cancel a native fuzzy picker.",
        subcommands: [Open.self, Result.self, Cancel.self],
        defaultSubcommand: Open.self
    )

    struct Open: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read choices from stdin and open a native fuzzy picker."
        )

        @Option(name: .long, help: "Placeholder text shown in the picker query field.") var prompt: String?
        @Option(name: .long, help: "Initial text for the picker query field; it opens already filtered.")
        var query: String?
        @Flag(name: .long, help: "Accept the current query as a custom result.") var allowCustom = false
        @Flag(name: .long, help: "Raise the target window when the picker opens.") var follow = false
        @Flag(name: .long, help: "Print the picker id and return without waiting for a result.") var noBlock = false
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            try makeRequest(input: FileHandle.standardInput.readDataToEndOfFile())
        }

        /// Build the open request from injected stdin bytes, so tests never block on the process's real stdin.
        func makeRequest(input: Data) throws -> ControlRequest {
            let args = ControlArgs(
                follow: follow ? true : nil,
                items: try Self.parseItems(input),
                prompt: prompt,
                query: query,
                allowCustom: allowCustom ? true : nil
            )
            return ControlRequest(cmd: .pickOpen, args: options.withWindow(args))
        }

        /// Sniff stdin's first non-whitespace byte. JSON arrays preserve caller-supplied ids/subtitles;
        /// bare lines use the label itself as the id and discard empty or whitespace-only lines.
        static func parseItems(_ input: Data) throws -> [ControlPickItem] {
            let whitespace = Set([UInt8(ascii: " "), UInt8(ascii: "\t"),
                                  UInt8(ascii: "\n"), UInt8(ascii: "\r")])
            if input.first(where: { !whitespace.contains($0) }) == UInt8(ascii: "[") {
                return try JSONDecoder().decode([ControlPickItem].self, from: input)
            }
            guard let text = String(data: input, encoding: .utf8) else {
                throw ValidationError("stdin must be UTF-8 text or a JSON item array")
            }
            return text.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ControlPickItem(id: $0, label: $0) }
        }

        func run() throws {
            let client = SocketClient(path: options.socketPath())
            try execute(
                input: FileHandle.standardInput.readDataToEndOfFile(),
                send: client.send,
                sleep: Thread.sleep(forTimeInterval:),
                output: { print($0) },
                errorOutput: Self.writeStandardError
            )
        }

        /// Execute open → poll with injectable I/O, so tests exercise the unbounded blocking flow without
        /// real delays or process fds.
        func execute(
            input: Data,
            send: (ControlRequest) throws -> ControlResponse,
            sleep: (TimeInterval) -> Void,
            output: (String) -> Void,
            errorOutput: (String) -> Void = Self.writeStandardError
        ) throws {
            let opened = try send(makeRequest(input: input))
            guard opened.ok else {
                Self.writeResponse(opened, json: options.json, output: output, errorOutput: errorOutput)
                throw ExitCode.failure
            }
            guard let pickID = opened.result?.id else {
                errorOutput("error: pick.open result missing id")
                throw ExitCode.failure
            }
            if noBlock {
                output(try SocketClient.formatPickID(pickID))
                return
            }

            var pendingPolls = 0
            while true {
                let response: ControlResponse
                do {
                    response = try send(ControlRequest(cmd: .pickResult, target: pickID))
                } catch {
                    // a transport failure mid-wait leaves the picker up with nobody waiting; every request
                    // opens its own connection, so the cancel can still land though this poll could not.
                    abandon(pickID, send: send)
                    throw error
                }
                // the poll carries no window selector, so a pending picker is always found by id and answers
                // ok; a not-ok response means the server no longer holds one, with nothing left to dismiss.
                guard response.ok else {
                    Self.writeResponse(response, json: options.json, output: output, errorOutput: errorOutput)
                    throw ExitCode.failure
                }
                guard let result = response.result?.pick else {
                    errorOutput("error: pick.result missing result")
                    abandon(pickID, send: send)
                    throw ExitCode.failure
                }
                if result.result == .pending {
                    pendingPolls += 1
                    sleep(SocketClient.pickPollDelay(afterPendingPoll: pendingPolls))
                    continue
                }

                output(try SocketClient.formatPickResult(result))
                let code = SocketClient.pickExitCode(for: result.result)
                if code.rawValue != 0 { throw code }
                return
            }
        }

        /// Dismiss a picker this command opened but can no longer wait on: else the window holds one whose
        /// owner is gone and refuses the next `pick.open`. Best effort — the poll already failed anyway.
        private func abandon(_ pickID: String, send: (ControlRequest) throws -> ControlResponse) {
            _ = try? send(ControlRequest(cmd: .pickCancel, target: pickID))
        }

        private static func writeResponse(
            _ response: ControlResponse,
            json: Bool,
            output: (String) -> Void,
            errorOutput: (String) -> Void
        ) {
            let line = SocketClient.formatResponse(response, json: json)
            if json {
                output(line)
            } else {
                errorOutput(line)
            }
        }

        private static func writeStandardError(_ line: String) {
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        }
    }

    struct Result: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a picker's current or terminal result as JSON."
        )
        @Argument(help: "Exact picker id returned by pick open.") var id: String
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .pickResult, target: id, args: options.withWindow())
        }

        func run() throws {
            try execute(
                send: SocketClient(path: options.socketPath()).send,
                output: { print($0) },
                errorOutput: Self.writeStandardError
            )
        }

        /// One-shot read with injectable transport/stdout/stderr, so every wire outcome and exit mapping is
        /// covered without replacing process file descriptors.
        func execute(
            send: (ControlRequest) throws -> ControlResponse,
            output: (String) -> Void,
            errorOutput: (String) -> Void = Self.writeStandardError
        ) throws {
            let response = try send(makeRequest())
            guard response.ok else {
                let line = SocketClient.formatResponse(response, json: options.json)
                if options.json {
                    output(line)
                } else {
                    errorOutput(line)
                }
                throw ExitCode.failure
            }
            guard let result = response.result?.pick else {
                errorOutput("error: pick.result missing result")
                throw ExitCode.failure
            }
            output(try SocketClient.formatPickResult(result))
            let code = SocketClient.pickExitCode(for: result.result)
            if code.rawValue != 0 { throw code }
        }

        private static func writeStandardError(_ line: String) {
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        }
    }

    struct Cancel: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Cancel a pending picker.")
        @Argument(help: "Exact picker id returned by pick open.") var id: String
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .pickCancel, target: id, args: options.withWindow())
        }
    }
}

// MARK: - sidebar

struct Sidebar: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sidebar visibility and view mode.",
        subcommands: [Visibility.self, Mode.self, Expand.self, Collapse.self],
        defaultSubcommand: Visibility.self
    )

    /// `agtermctl sidebar [show|hide|toggle]` — the default subcommand, so the bare verb keeps working.
    struct Visibility: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "visibility", abstract: "Sidebar visibility (show|hide|toggle).")
        @Argument(help: "Mode: show, hide, or toggle (default).") var mode: String = "toggle"
        // the sidebar is always the frontmost window's, so this carries no `--window` selector.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sidebar, args: ControlArgs(mode: mode))
        }
    }

    /// Flips the frontmost window's sidebar between the workspace tree and the flat flagged working-set list.
    struct Mode: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "mode", abstract: "Sidebar view mode (tree|flagged|toggle).")
        @Argument(help: "Mode: tree, flagged, or toggle (default).") var mode: String = "toggle"
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard ["tree", "flagged", "toggle"].contains(mode) else {
                throw ValidationError("mode must be tree, flagged, or toggle")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sidebarMode, args: ControlArgs(mode: mode))
        }
    }

    /// `agtermctl sidebar expand [--window W]` — expand every workspace in a window's sidebar tree (default
    /// frontmost). Unlike `visibility`/`mode` it carries `--window`, so a script can reach a background one.
    struct Expand: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Expand every workspace in the sidebar.")
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .sidebarExpand, args: options.withWindow()) }
    }

    /// Collapse every workspace except the active one in a window's sidebar (frontmost by default).
    struct Collapse: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Collapse all workspaces except the active one.")
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .sidebarCollapse, args: options.withWindow()) }
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

    /// Help for the shared `--pane` option; role and axis-position aliases resolve to the same stable slots.
    static let paneHelp = "Which pane's font to change: left (main), right (split), or scratch (the "
        + "session's scratch terminal, even when hidden). primary/left/top and split/right/bottom are aliases. Defaults to the left pane."

    struct Inc: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Increase font size.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions
        @Option(name: .long, help: ArgumentHelp(Font.paneHelp)) var pane: String?

        func validate() throws { try validatePaneArgument(pane) }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .fontInc, target: target.target, args: options.withWindow(pane.map { ControlArgs(pane: $0) }))
        }
    }

    struct Dec: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Decrease font size.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions
        @Option(name: .long, help: ArgumentHelp(Font.paneHelp)) var pane: String?

        func validate() throws { try validatePaneArgument(pane) }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .fontDec, target: target.target, args: options.withWindow(pane.map { ControlArgs(pane: $0) }))
        }
    }

    struct Reset: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Reset font size.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions
        @Option(name: .long, help: ArgumentHelp(Font.paneHelp)) var pane: String?

        func validate() throws { try validatePaneArgument(pane) }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .fontReset, target: target.target, args: options.withWindow(pane.map { ControlArgs(pane: $0) }))
        }
    }
}
