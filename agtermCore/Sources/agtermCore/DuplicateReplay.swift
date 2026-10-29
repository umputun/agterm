import Foundation

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
            /// notLocated: no path the program could have been started from resolves to the running image.
            case notLocated
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
            case .notLocated: "the path the foreground program was started from cannot be found"
            }
            return "\(pane) pane: \(text); nothing was created"
        }
    }

    /// resolve plans `pane` from one observation. A recognized shell holding the pane gives a plain shell in its
    /// directory, `fallbackDirectory` when that cannot be read; every refusal of the restart replay, a daemon-leader
    /// shell included, refuses the copy. A program not started by absolute path is copied by the path it was started
    /// from, because outside Live the creation command runs on the app's PATH, not the source shell's: for a bare
    /// name the first entry of the source's own PATH that resolves to the running image, else the first executable
    /// one, which is the shell's own pick when a version manager's shim re-exec'd; for a relative name its directory.
    /// It launches unresolved, so `vimdiff` stays `vimdiff`. With no PATH to read, as for a platform binary, the
    /// system directories are searched and the image is the fallback; otherwise one that cannot be located is
    /// refused rather than copied as the image. The checks see both the path and the image.
    public static func resolve(_ observation: RestartReplay.Observation, pane: String, fallbackDirectory: String,
                               shell: String?, denylist: Set<String>,
                               resolvedFile: (String) -> String? = canonicalExecutable) -> Result<Plan, Refusal> {
        if observation.foreground?.shellName != nil {
            return .success(.shell(workingDirectory: observation.workingDirectory ?? fallbackDirectory))
        }
        var candidates = [observation]
        if let argv = observation.foreground?.command, let program = argv.first, !program.hasPrefix("/") {
            guard let executable = observation.executablePath else { return .failure(Refusal(pane: pane, reason: .noExecutable)) }
            guard !program.contains("/") || observation.workingDirectory != nil else {
                return .failure(Refusal(pane: pane, reason: .replay(.noDirectory)))
            }
            let image = resolvedFile(executable) ?? executable
            let found = startingPaths(of: program, in: observation).compactMap { path in resolvedFile(path).map { (path, $0) } }
            // macOS withholds a platform binary's environment, and those live in the system directories
            let unreadable = observation.searchPath == nil && !program.contains("/")
            let fallback = unreadable ? executable : (found.first?.0)
            guard let started = found.first(where: { $0.1 == image })?.0 ?? fallback else {
                return .failure(Refusal(pane: pane, reason: .notLocated))
            }
            candidates = [started, executable].map { observation.running(argv, as: $0) }
        }
        let outcomes = candidates.map { program($0, pane: pane, shell: shell, denylist: denylist) }
        return outcomes.first { if case .failure = $0 { true } else { false } } ?? outcomes[0]
    }

    static let systemSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// canonicalExecutable is `path` with every symlink resolved when it names an executable file, nil otherwise.
    public static func canonicalExecutable(_ path: String) -> String? {
        FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : nil
    }

    private static func program(_ observation: RestartReplay.Observation, pane: String, shell: String?,
                                denylist: Set<String>) -> Result<Plan, Refusal> {
        switch RestartReplay.resolve(observation, shell: shell, denylist: denylist) {
        case .failure(let reason):
            return .failure(Refusal(pane: pane, reason: .replay(reason)))
        case .success(let launch):
            guard !launch.argv.contains(where: { $0.contains("\\") }) else {
                return .failure(Refusal(pane: pane, reason: .backslash))
            }
            return .success(.program(argv: launch.argv, workingDirectory: launch.workingDirectory))
        }
    }

    // preserve invocation symlink names while normalizing relative paths consistently across hosts
    private static func joined(_ program: String, under directory: String) -> String {
        var parts: [Substring] = []
        for part in "\(directory)/\(program)".split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    // absolute PATH entries only: a relative entry meant whatever directory the shell sat in at that lookup
    private static func startingPaths(of program: String, in observation: RestartReplay.Observation) -> [String] {
        if program.contains("/") {
            guard let directory = observation.workingDirectory else { return [] }
            return [joined(program, under: directory)]
        }
        return (observation.searchPath ?? systemSearchPath).split(separator: ":").filter { $0.hasPrefix("/") }
            .map { $0.hasSuffix("/") ? "\($0)\(program)" : "\($0)/\(program)" }
    }
}

private extension RestartReplay.Observation {
    func running(_ argv: [String], as program: String) -> Self {
        Self(foreground: .program([program] + argv.dropFirst()), isDaemonLeader: isDaemonLeader,
             workingDirectory: workingDirectory, executablePath: executablePath, searchPath: searchPath)
    }
}
