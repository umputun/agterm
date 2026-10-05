import ArgumentParser
import agtermCore

extension Session {
    struct Restart: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replace the shell of one live pane and run a shell line, or the same program again, in the new one.",
            discussion: """
            session restart --target ID --pane-id TOKEN --command 'cld brief.md'
            session restart --target ID --pane-id TOKEN

            Ends the pane's shell and its foreground program, then starts a new login shell in the \
            same pane that runs COMMAND and stays as an interactive shell afterwards. The pane keeps its \
            place, its stable id and its AGTERM_* environment, and starts with an empty screen. Nothing is \
            typed into the pane.

            Without --command the new shell runs the pane's current foreground program again, with the \
            arguments `tree` reports as foreground or splitForeground, in the directory that program is \
            running in. That is the program as it runs now, not the line that started it: environment \
            assignments, redirections and the other parts of a pipeline are not reconstructed. It is \
            refused, with nothing changed, when a shell holds the pane (the pane's own shell running a \
            builtin or a loop included), when the program cannot be read (sudo, top), when its directory \
            is unavailable, or when it is listed in restore-denylist.conf. The reply carries the argv the new shell was \
            asked to run as restart.replayedArgv.

            The reply comes once a new shell exists in the pane, and carries the ended shell's pid and \
            the new one's as restart.oldPid and restart.newPid. They are the pane's shells, not the program \
            COMMAND starts; read that from `tree` as foreground or splitForeground. An error names the \
            step that did not happen.

            Works only in Live sessions mode, for a local pane. A hidden split and a pane in a background \
            window are restarted like any other. A background or disowned job of the old \
            shell is not ended.

            COMMAND is one shell line of at most \(ControlSessionRestartOptions.maxCommandBytes) bytes.
            """)
        @Option(name: .long, help: "Shell line the new shell runs. Omit to run the pane's foreground program again.")
        var command: String?
        @Option(name: .long, help: "Which pane to restart: primary/left/top or split/right/bottom.") var pane: String?
        @Option(name: .customLong("pane-id"), help: """
            The pane's stable token (the shell's $AGTERM_PANE_ID). It resolves to the pane's current slot \
            and wins over --pane; a token that does not resolve is an error, with or without --pane.
            """)
        var paneID: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard pane != nil || paneID?.isEmpty == false else {
                throw ValidationError("provide --pane-id or --pane")
            }
            try validatePaneArgument(pane)
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionRestart, target: target.target,
                           args: options.withWindow(ControlArgs(command: command, pane: pane, paneID: paneID)))
        }
    }
}
