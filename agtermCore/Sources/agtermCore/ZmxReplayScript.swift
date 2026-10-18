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
}
