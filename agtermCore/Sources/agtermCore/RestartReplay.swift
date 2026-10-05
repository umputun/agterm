/// RestartReplay decides what a `session.restart` without a command runs: the pane's foreground program
/// again, in the directory it is running in.
public enum RestartReplay {
    /// Observation is one read of the process holding the pane's foreground.
    public struct Observation: Equatable, Sendable {
        /// foreground is nil when the process could not be read.
        public let foreground: CommandRestore.PaneForeground?
        /// isDaemonLeader is true for the daemon's root process, including a program it exec'd.
        public let isDaemonLeader: Bool
        /// workingDirectory is nil when it could not be read or is not a directory.
        public let workingDirectory: String?

        public init(foreground: CommandRestore.PaneForeground?, isDaemonLeader: Bool, workingDirectory: String?) {
            self.foreground = foreground
            self.isDaemonLeader = isDaemonLeader
            self.workingDirectory = workingDirectory
        }
    }

    /// Launch is what the new shell is asked to run, and where.
    public struct Launch: Equatable, Sendable {
        public let argv: [String]
        public let workingDirectory: String
    }

    /// Refusal is why a pane's foreground cannot be replayed. Every case is decided before anything is ended.
    public enum Refusal: Error, Equatable, Sendable {
        case unreadable
        case shell(String)
        case denylisted(String)
        case unreplayable
        case tooLong
        case noDirectory

        public var message: String {
            let reason = switch self {
            case .unreadable: "the pane's foreground program cannot be read"
            case .shell(let name): "no replayable foreground program: \(name) holds the pane"
            case .denylisted(let name): "\(name) is on the restore denylist"
            case .unreplayable: "the foreground program's arguments cannot be replayed"
            case .tooLong:
                "the foreground program's command line is too long to replay "
                    + "(max \(ControlSessionRestartOptions.maxCommandBytes) bytes)"
            case .noDirectory: "the foreground program's working directory is unavailable"
            }
            return reason + "; pass --command to name the line. nothing was changed"
        }
    }

    /// resolve returns the launch to replay. It refuses a daemon-leader shell, because replaying its
    /// launch wrapper can nest shells. `shell` is the user's `$SHELL` basename, so a non-standard one is
    /// recognized too.
    public static func resolve(_ observation: Observation, shell: String?,
                               denylist: Set<String>) -> Result<Launch, Refusal> {
        guard let foreground = observation.foreground else { return .failure(.unreadable) }
        if let name = foreground.shellName { return .failure(.shell(name)) }
        guard let argv = foreground.command, let program = argv.first else { return .failure(.unreadable) }
        let name = CommandRestore.basename(program)
        if observation.isDaemonLeader, CommandRestore.isKnownShell(name, extra: shell) {
            return .failure(.shell(name))
        }
        guard !denylist.contains(name) else { return .failure(.denylisted(name)) }
        guard CommandRestore.shouldRestore(argv: argv, denylist: []) else { return .failure(.unreplayable) }
        guard CommandRestore.shellQuotedLine(argv).utf8.count <= ControlSessionRestartOptions.maxCommandBytes else {
            return .failure(.tooLong)
        }
        guard let directory = observation.workingDirectory else { return .failure(.noDirectory) }
        return .success(Launch(argv: argv, workingDirectory: directory))
    }
}
