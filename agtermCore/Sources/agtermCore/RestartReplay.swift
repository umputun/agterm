/// RestartReplay decides what a `session.restart` without a command runs: the pane's foreground program,
/// under the filter a relaunch in Re-run commands mode applies to a captured one.
public enum RestartReplay {
    /// Refusal is why a pane's foreground cannot be replayed. Every case is decided before anything is ended.
    public enum Refusal: Error, Equatable, Sendable {
        case unreadable
        case shell(String)
        case denylisted(String)
        case unreplayable
        case tooLong

        public var message: String {
            let reason = switch self {
            case .unreadable: "the pane's foreground program cannot be read"
            case .shell(let name): "no replayable foreground program: \(name) holds the pane"
            case .denylisted(let name): "\(name) is on the restore denylist"
            case .unreplayable: "the foreground program's arguments cannot be replayed"
            case .tooLong:
                "the foreground program's command line is too long to replay "
                    + "(max \(ControlSessionRestartOptions.maxCommandBytes) bytes)"
            }
            return reason + "; pass --command to name the line. nothing was changed"
        }
    }

    /// resolve returns the argv to replay. A shell in the foreground is refused even though it may be
    /// running a builtin or a loop, because its argv does not say what.
    public static func resolve(foreground: CommandRestore.PaneForeground?,
                               denylist: Set<String>) -> Result<[String], Refusal> {
        guard let foreground else { return .failure(.unreadable) }
        if let shell = foreground.shellName { return .failure(.shell(shell)) }
        guard let argv = foreground.command, let program = argv.first else { return .failure(.unreadable) }
        let name = CommandRestore.basename(program)
        guard !denylist.contains(name) else { return .failure(.denylisted(name)) }
        guard CommandRestore.shouldRestore(argv: argv, denylist: []) else { return .failure(.unreplayable) }
        guard CommandRestore.shellQuotedLine(argv).utf8.count <= ControlSessionRestartOptions.maxCommandBytes else {
            return .failure(.tooLong)
        }
        return .success(argv)
    }
}
