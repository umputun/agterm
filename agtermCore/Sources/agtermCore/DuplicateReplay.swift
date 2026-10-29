/// DuplicateReplay decides what one pane of Duplicate as Companion starts: another copy of the program holding
/// the source pane, in that program's directory, or a plain shell where a shell holds it.
/// A pipeline or shell job is copied as its observed foreground process only; nothing checks the job's shape.
public enum DuplicateReplay {
    public enum Plan: Equatable, Sendable {
        case shell(workingDirectory: String)
        case program(argv: [String], workingDirectory: String)

        public var workingDirectory: String {
            switch self {
            case .shell(let directory), .program(_, let directory): directory
            }
        }

        /// argv is the program to start, nil for a plain shell.
        public var argv: [String]? {
            if case .program(let argv, _) = self { return argv }
            return nil
        }

        /// command is the pane's creation command, as `session new --command` takes one; nil for a plain shell.
        public var command: String? { argv.map(CommandRestore.shellQuotedLine) }
    }

    /// Refusal is a pane that cannot be copied; the duplicate creates nothing when any pane refuses.
    public struct Refusal: Error, Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case replay(RestartReplay.Refusal)
            /// backslash: the creation command reaches libghostty's argv splitter outside Live and fish's eval in
            /// Live, which read a backslash inside single quotes differently.
            case backslash
            case noExecutable
        }

        public let pane: String
        public let reason: Reason

        public init(pane: String, reason: Reason) {
            self.pane = pane
            self.reason = reason
        }

        public var message: String {
            let text = switch reason {
            case .replay(let refusal): refusal.reason
            case .backslash: "the foreground program's arguments contain a backslash, which cannot be copied"
            case .noExecutable: "the foreground program's executable path cannot be read"
            }
            return "\(pane) pane: \(text); nothing was created"
        }
    }

    /// resolve plans `pane` from one observation. A recognized shell holding the pane gives a plain shell in its
    /// directory, `fallbackDirectory` when that cannot be read; every refusal of the restart replay, a daemon-leader
    /// shell included, refuses the copy. A bare argv[0] becomes the observed executable path, because outside
    /// Live the creation command runs on the app's PATH, not the source shell's.
    public static func resolve(_ observation: RestartReplay.Observation, pane: String, fallbackDirectory: String,
                               shell: String?, denylist: Set<String>) -> Result<Plan, Refusal> {
        if observation.foreground?.shellName != nil {
            return .success(.shell(workingDirectory: observation.workingDirectory ?? fallbackDirectory))
        }
        var resolved = observation
        if var argv = observation.foreground?.command, let program = argv.first, !program.hasPrefix("/") {
            guard let executable = observation.executablePath else { return .failure(Refusal(pane: pane, reason: .noExecutable)) }
            argv[0] = executable
            resolved = RestartReplay.Observation(foreground: .program(argv), isDaemonLeader: observation.isDaemonLeader,
                                                 workingDirectory: observation.workingDirectory,
                                                 executablePath: observation.executablePath)
        }
        switch RestartReplay.resolve(resolved, shell: shell, denylist: denylist) {
        case .failure(let reason):
            return .failure(Refusal(pane: pane, reason: .replay(reason)))
        case .success(let launch):
            guard !launch.argv.contains(where: { $0.contains("\\") }) else {
                return .failure(Refusal(pane: pane, reason: .backslash))
            }
            return .success(.program(argv: launch.argv, workingDirectory: launch.workingDirectory))
        }
    }
}
