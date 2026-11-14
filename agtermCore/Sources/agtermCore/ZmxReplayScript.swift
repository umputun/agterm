public enum ZmxReplayScript {
    public static func render(argv: [String], integrationDirectory: String,
                              inheritedZdotdir: String?, shell: String) -> String {
        render(statement: CommandRestore.shellQuotedLine(argv), integrationDirectory: integrationDirectory,
               inheritedZdotdir: inheritedZdotdir, shell: shell)
    }

    public static func render(commandLine: String, integrationDirectory: String,
                              inheritedZdotdir: String?, shell: String) -> String {
        render(statement: "'builtin' 'eval' -- \(quoted(commandLine))", integrationDirectory: integrationDirectory,
               inheritedZdotdir: inheritedZdotdir, shell: shell)
    }

    /// renderEnding runs a creation command without returning to a login shell.
    public static func renderEnding(commandLine: String) -> String {
        "'builtin' 'eval' -- \(quoted(commandLine))"
    }

    public static func renderFishEnding(commandLine: String) -> String {
        "builtin status job-control full; builtin eval \(fishQuoted(commandLine))"
    }

    /// holdLine is what a held pane shows once its command is done, ghostty's own wait-after-command line.
    public static let holdLine = "Process exited. Press any key to close the terminal."

    /// renderHolding runs a creation command, then holds the pane for one key. The command runs in a subshell, a fork
    /// of the interactive shell, so its `exit` or `exec` cannot skip the hold; `always` keeps it after Ctrl-C.
    public static func renderHolding(commandLine: String) -> String {
        "{ ( 'builtin' 'eval' -- \(quoted(commandLine)) ) } always { 'builtin' 'print' -r -- \(quoted(holdLine)) ; "
            + "'builtin' 'read' -k1 -s ; }"
    }

    /// renderBashHolding is `renderHolding` for bash, which has no `always`: the hold is the EXIT trap, which also
    /// runs when Ctrl-C ends the command list.
    public static func renderBashHolding(commandLine: String) -> String {
        "__agterm_hold() { builtin printf '%s\\n' \(quoted(holdLine)); IFS= builtin read -r -n1 -s; }; "
            + "builtin trap __agterm_hold EXIT; ( builtin eval \(quoted(commandLine)) )"
    }

    /// renderFishHolding is `renderHolding` for fish, which has no subshell: the command runs in a child login fish,
    /// the context `renderFishEnding` gives it, and the key is read outside fish, whose `read` waits on terminal
    /// replies a detached daemon never gets.
    public static func renderFishHolding(commandLine: String, shell: String) -> String {
        let child = "\(fishQuoted(shell)) -lic \(fishQuoted(renderFishEnding(commandLine: commandLine)))"
        return "builtin status job-control full; builtin eval \(fishQuoted(child)); "
            + "builtin printf '%s\\n' \(fishQuoted(holdLine)); "
            + "command sh -c \(fishQuoted("stty -icanon -echo min 1 time 0; dd bs=1 count=1 >/dev/null 2>&1"))"
    }

    /// renderBash replays `argv`, then becomes the integrated login shell: the EXIT trap, which also runs after
    /// Ctrl-C, exports again the variables ghostty.bash consumed when it loaded and execs `shell`.
    public static func renderBash(argv: [String], exports: [(name: String, value: String)], shell: String) -> String {
        let rearm = exports.map { "builtin export \($0.name)=\(quoted($0.value))" }
            + ["builtin exec -- \(quoted(shell)) --posix -l"]
        return "__agterm_rearm() { \(rearm.joined(separator: "; ")); }; builtin trap __agterm_rearm EXIT; "
            + CommandRestore.shellQuotedLine(argv)
    }

    public static func renderFish(argv: [String], integrationRoot: String, shell: String) -> String {
        renderFish(statement: argv.map(fishQuoted).joined(separator: " "), integrationRoot: integrationRoot, shell: shell)
    }

    public static func renderFish(commandLine: String, integrationRoot: String, shell: String) -> String {
        renderFish(statement: commandLine, integrationRoot: integrationRoot, shell: shell)
    }

    /// The rearm and exec run in an `always` block: interactive zsh drops the rest of a plain `;` list when the
    /// payload is interrupted with Ctrl-C, and the pane's process would exit instead of becoming the login shell.
    private static func render(statement: String, integrationDirectory: String,
                               inheritedZdotdir: String?, shell: String) -> String {
        var rearm = ["'builtin' 'export' ZDOTDIR=\(quoted(integrationDirectory))"]
        if let inheritedZdotdir {
            rearm.append("'builtin' 'export' GHOSTTY_ZSH_ZDOTDIR=\(quoted(inheritedZdotdir))")
        } else {
            rearm.append("'builtin' 'unset' GHOSTTY_ZSH_ZDOTDIR")
        }
        rearm.append("'builtin' 'exec' -- \(quoted(shell)) -il")
        return "{ \(statement) ; } always { \(rearm.joined(separator: " ; ")) ; }"
    }

    private static func quoted(_ value: String) -> String {
        CommandRestore.shellQuotedLine([value])
    }

    private static func renderFish(statement: String, integrationRoot: String, shell: String) -> String {
        let quotedRoot = fishQuoted(integrationRoot)
        let rearm = [
            "begin",
            "builtin set --local __agterm_xdg_source",
            "if builtin set -q XDG_DATA_DIRS; and builtin test -n \"$XDG_DATA_DIRS\"",
            "builtin set __agterm_xdg_source \"$XDG_DATA_DIRS\"",
            "else",
            "builtin set __agterm_xdg_source /usr/local/share:/usr/share",
            "end",
            "builtin set --local __agterm_xdg_user_dirs",
            "builtin set --local __agterm_xdg_data_dir",
            "for __agterm_xdg_data_dir in (string split : -- \"$__agterm_xdg_source\")",
            "if builtin test -n \"$__agterm_xdg_data_dir\"; and builtin test \"$__agterm_xdg_data_dir\" != \(quotedRoot)",
            "builtin set --append __agterm_xdg_user_dirs \"$__agterm_xdg_data_dir\"",
            "end",
            "end",
            "builtin set --global --export --path XDG_DATA_DIRS \(quotedRoot) $__agterm_xdg_user_dirs",
            "end",
        ].joined(separator: "; ")
        // eval confines interruption to the payload so the outer list still rearms and execs.
        return [
            "builtin status job-control full",
            "builtin eval \(fishQuoted(statement))",
            "builtin set -gx GHOSTTY_SHELL_INTEGRATION_XDG_DIR \(quotedRoot)",
            rearm,
            "exec \(fishQuoted(shell)) -il",
        ].joined(separator: "; ")
    }

    private static func fishQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}
