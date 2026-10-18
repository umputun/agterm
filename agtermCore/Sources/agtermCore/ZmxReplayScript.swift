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
