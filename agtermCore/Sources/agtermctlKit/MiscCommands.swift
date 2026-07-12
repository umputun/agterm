import ArgumentParser
import Foundation
import agtermCore

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
        static let configuration = CommandConfiguration(abstract: "Clear every session's saved foreground command so the next restart restores plain shells.")
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

    /// `agtermctl quick [show|hide|toggle]` — the default, so the bare verb keeps working. Shows/hides the
    /// frontmost window's quick terminal.
    struct Visibility: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "visibility", abstract: "Quick terminal visibility (show|hide|toggle).")
        @Argument(help: "Mode: show, hide, or toggle (default).") var mode: String = "toggle"
        // the quick terminal is always the frontmost window's, so this carries no `--window` selector.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .quick, args: ControlArgs(mode: mode))
        }
    }

    /// `agtermctl quick type TEXT` — inject literal keystrokes into the frontmost window's quick terminal
    /// (the quick-terminal twin of `session type`). No `--target`/`--window`: it's always the frontmost
    /// window's quick terminal.
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

    /// `agtermctl quick text` — print the frontmost window's quick-terminal buffer as plain text (the
    /// read-back for `quick type`; does not touch the system clipboard). No `--pane`: the quick terminal
    /// has a single surface.
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

/// `agtermctl dashboard <ids…> [--font-size N | --auto-size] [--window W]` opens a view-only grid of the
/// named sessions (max 9); `agtermctl dashboard --mru [--font-size N | --auto-size] [--window W]` opens one
/// of the window's most-recently-used sessions (up to 9) instead of naming ids; `agtermctl dashboard --close
/// [--window W]` closes the open one. The positional ids map to `ControlArgs.targets`; the dispatcher caps
/// them at 9, dedups, and reports any drop. The CLI re-checks the flag combinations `validate()`-style so a
/// bad invocation is a clean usage error without a socket round-trip (the dispatcher enforces the same rules
/// server-side).
struct Dashboard: RequestCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a view-only grid of live sessions, or --close the open one.",
        discussion: """
        dashboard S1 S2 S3                 open a grid of the named sessions (ids or unique prefixes, max 9)
        dashboard S1 S2 --font-size 12     open with an absolute cell font size (points)
        dashboard S1 S2 --auto-size        open sizing cells relative to the Settings default font
        dashboard --mru                    open a grid of the window's most-recently-used sessions (up to 9)
        dashboard --mru --auto-size        the same, sizing cells relative to the Settings default font
        dashboard S1 --window W            open in a specific window (defaults to the frontmost)
        dashboard --close                  close the open dashboard
        """)
    @Argument(help: "Session ids (or unique prefixes) to show, max 9. Omit only with --mru or --close.") var ids: [String] = []
    @Option(name: .customLong("font-size"), help: "Absolute cell font size in points (mutually exclusive with --auto-size).") var fontSize: Double?
    @Flag(name: .long, help: "Size cells relative to the Settings default font, shrinking as the grid grows.") var autoSize = false
    @Flag(name: .long, help: "Populate the grid from the window's most-recently-used sessions (up to 9).") var mru = false
    @Flag(name: .long, help: "Close the open dashboard (takes no ids, --mru, or font options).") var close = false
    @OptionGroup var options: ClientOptions

    // reject the invalid flag combinations at parse time (before any connection) so they are clean usage
    // errors, unit-testable without a socket; the dispatcher re-checks the same rules server-side.
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
        // an open needs explicit ids OR --mru (which supplies them from the window's recency).
        guard !ids.isEmpty || mru else {
            throw ValidationError("dashboard requires at least one session id (or --mru, or --close)")
        }
        if fontSize != nil, autoSize {
            throw ValidationError("--font-size is mutually exclusive with --auto-size")
        }
        // nan/inf parse as Double but aren't a valid size; reject non-finite/non-positive here with a clean error.
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

// MARK: - sidebar

struct Sidebar: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sidebar visibility and view mode.",
        subcommands: [Visibility.self, Mode.self, Expand.self, Collapse.self],
        defaultSubcommand: Visibility.self
    )

    /// `agtermctl sidebar [show|hide|toggle]` — the default, so the bare verb keeps working. Toggles the
    /// frontmost window's sidebar visibility.
    struct Visibility: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "visibility", abstract: "Sidebar visibility (show|hide|toggle).")
        @Argument(help: "Mode: show, hide, or toggle (default).") var mode: String = "toggle"
        // the sidebar is always the frontmost window's, so this carries no `--window` selector.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sidebar, args: ControlArgs(mode: mode))
        }
    }

    /// `agtermctl sidebar mode [tree|flagged|toggle]` — flips the frontmost window's sidebar view between
    /// the workspace tree and the flat flagged working-set list.
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

    /// `agtermctl sidebar expand [--window W]` — expand every workspace in a window's sidebar tree
    /// (defaults to the frontmost). Unlike `visibility`/`mode`, this carries the `--window` selector so a
    /// script can expand a background window's tree.
    struct Expand: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Expand every workspace in the sidebar.")
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .sidebarExpand, args: options.withWindow()) }
    }

    /// `agtermctl sidebar collapse [--window W]` — collapse every workspace except the active one (it
    /// stays expanded) in a window's sidebar (defaults to the frontmost).
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

    /// Help text for the shared `--pane` option on the font subcommands. Reuses the `left|right|scratch`
    /// vocabulary of `session type`/`session text`; omitted defaults to the main pane.
    static let paneHelp = "Which pane's font to change: left (main), right (split), or scratch (the "
        + "session's scratch terminal, even when hidden). Defaults to the left pane."

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
