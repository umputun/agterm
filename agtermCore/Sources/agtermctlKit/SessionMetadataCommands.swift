import ArgumentParser
import agtermCore

// The `session` subcommands carrying per-session METADATA rather than driving a surface: the agent status
// glyph, the restore-command pin, flagged membership, and the title-bar context. Split out of
// `SessionCommands.swift` for the file and type size limits.
extension Session {
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
        @Option(name: .long, help: """
            Override the glyph silhouette for this call only: \
            \(StatusShape.validNamesPhrase); \
            reverts on the next status set without it.
            """)
        var shape: String?
        @Option(name: .long, help: """
            Which pane set this status: primary/left/top, split/right/bottom, or scratch. Records the blocked \
            pane so navigation reaches it. Defaults to primary.
            """)
        var pane: String?
        @Option(name: .customLong("pane-id"), help: """
            A surface's stable token (the shell's $AGTERM_PANE_ID) — the agent-status hook forwards it so a \
            status set from a promoted-then-re-split pane lands on the pane's current slot. Overrides --pane \
            when it resolves; falls back to --pane otherwise.
            """)
        var paneID: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            if let color, !WatermarkConfig.isValidColorHex(color) {
                throw ValidationError("color must be a #rrggbb hex value")
            }
            if let shape, StatusShape(rawValue: shape) == nil {
                throw ValidationError("shape must be one of: \(StatusShape.validNamesPhrase)")
            }
            try validatePaneArgument(pane)
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionStatus, target: target.target,
                           args: options.withWindow(ControlArgs(pane: pane, paneID: paneID, status: state,
                                                                 blink: blink ? true : nil,
                                                                 autoReset: autoReset ? true : nil, sound: sound,
                                                                 color: color, shape: shape)))
        }
    }

    /// The per-session, per-pane restore-command override. Nested under `Session`, a different verb from the
    /// top-level `restore clear` (app-global and capture-scoped; this one per-session and override-scoped).
    struct Restore: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pin the command a session's pane re-runs on the next launch.",
            discussion: """
            session restore "claude --resume ID"   pin a shell line for the next launch
            session restore --none                 pin to nothing (the pane restores a plain shell)
            session restore --clear                drop the override, back to auto-capture

            The override is written now and consumed on the NEXT launch — it never touches the running \
            session. It wins over the pane's captured foreground command in rerun mode and reads back on \
            `tree` as restoreCommand (main pane) or \
            splitRestoreCommand (split pane). It is STICKY: it fires again on every launch until cleared.

            Set and --none still save policy while this launch is in fresh-shell or live mode; the response \
            names the active mode and says the policy is saved for rerun mode. --clear works in every mode. \
            A pin never opts one session out of live mode.

            COMMAND is shell code, stored verbatim in the window's state file and readable via `tree`, so \
            it must not carry secrets.

            Not to be confused with `agtermctl restore clear`, which is app-global and clears every \
            session's CAPTURED foreground command; this one is per-session and clears only the override.
            """)
        @Argument(help: "Shell line to run on the next launch (omit with --none or --clear).") var command: String?
        @Flag(name: .long, help: "Pin the pane to nothing: it restores a plain shell, suppressing the captured command.") var none = false
        @Flag(name: .long, help: "Drop the override so the pane goes back to restoring its captured foreground command.") var clear = false
        @Option(name: .long, help: "Which pane to pin: primary/left/top or split/right/bottom; scratch is rejected. Defaults to primary.") var pane: String?
        @Option(name: .customLong("pane-id"), help: """
            A surface's stable token (the shell's $AGTERM_PANE_ID) — resolves to the pane's CURRENT slot, \
            so a hook in a promoted-then-re-split pane still pins the right one. Unlike `session status`, \
            a token that does not resolve is an error unless --pane is also given as the fallback.
            """)
        var paneID: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        // exactly one of the three forms; reject neither/multiple at parse time so it's a clean usage
        // error, unit-testable without a socket (the dispatcher enforces the same modes server-side).
        func validate() throws {
            guard [command != nil, none, clear].filter({ $0 }).count == 1 else {
                throw ValidationError("provide exactly one of a COMMAND, --none, or --clear")
            }
            try validatePaneArgument(pane)
        }

        func makeRequest() throws -> ControlRequest {
            // validate() guarantees the forms are exclusive, so `command` is nil for none/clear.
            let mode = none ? "none" : clear ? "clear" : "set"
            return ControlRequest(cmd: .sessionRestore, target: target.target,
                                  args: options.withWindow(ControlArgs(mode: mode, command: command,
                                                                        pane: pane, paneID: paneID)))
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

    struct Context: RequestCommand {
        static let configuration = CommandConfiguration(
            commandName: "context",
            abstract: "Set or clear what a session is about, shown in the title bar.",
            discussion: """
                The text says what the session is FOR — a PR, an issue, a task — where the sidebar row has \
                no space for it. It persists across a relaunch and stays until --clear; nothing expires it.
                """)
        @Argument(help: """
            The context text (omit with --clear). Trimmed; max 256 UTF-8 bytes; no control characters or \
            line breaks.
            """)
        var text: String?
        @Flag(name: .long, help: "Remove the context.") var clear = false
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        // exactly one form; a blank TEXT is rejected server-side rather than treated as a second clear.
        func validate() throws {
            guard [text != nil, clear].filter({ $0 }).count == 1 else {
                throw ValidationError("provide exactly one of a TEXT or --clear")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionContext, target: target.target,
                           args: options.withWindow(ControlArgs(text: text, mode: clear ? "clear" : "set")))
        }
    }
}
