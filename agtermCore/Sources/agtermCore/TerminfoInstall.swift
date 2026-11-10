import Foundation

/// Installs the bundled `xterm-ghostty` terminfo entry on a remote host over one ssh connection, so
/// programs there stop warning that the terminal is unknown. A local `infocmp` dumps the entry as
/// source and the remote `tic` compiles it into that account's `~/.terminfo`.
///
/// Host-free apart from the two child processes; the CLI owns the argument surface and the printing.
public enum TerminfoInstall {
    public static let entry = "xterm-ghostty"

    /// The connection, as a narrower surface than ssh's own. A verbatim argument bag would let `-G`
    /// print the config and claim success, `-N` never run `tic`, and `-n` discard the source; anything
    /// beyond these belongs in the user's ssh config under a host alias.
    public struct Connection: Equatable, Sendable {
        public var destination: String
        public var port: Int?
        public var identities: [String]
        public var jump: String?
        public var config: String?

        public init(destination: String, port: Int? = nil, identities: [String] = [], jump: String? = nil,
                    config: String? = nil) {
            self.destination = destination
            self.port = port
            self.identities = identities
            self.jump = jump
            self.config = config
        }
    }

    public enum Failure: Error, Equatable {
        /// The destination is empty, contains whitespace or a control character, or starts with `-`,
        /// which ssh would read as an option.
        case invalidDestination
        /// No terminfo database holding the entry was found at the searched paths.
        case terminfoNotFound(searched: [String])
        /// `infocmp` exited non-zero; its stderr is carried for the user.
        case dumpFailed(status: Int32, stderr: String)
        /// A system call on the way to running ssh failed; `errno` is the code it returned.
        case spawnFailed(operation: String, errno: Int32)
    }

    /// How the remote side ended: ssh's exit status, or the signal that killed it.
    public typealias Outcome = ForegroundSpawn.Outcome

    /// Where the entry is looked up, in order. The database next to the running CLI comes first because
    /// the bundle is the only source whose entry is known to match this build; `TERMINFO` from the
    /// environment is the fallback for a CLI running outside a bundle, such as a `swift build` tree
    /// inside an agterm shell, where libghostty has exported the app's own database.
    ///
    /// `clientPath` is the CLI's resolved real path: the installed CLI is a symlink into the bundle, so
    /// the caller resolves it before this sees it.
    static func candidateDirectories(clientPath: String?, environment: [String: String]) -> [String] {
        var candidates: [String] = []
        if let clientPath {
            let directory = (clientPath as NSString).deletingLastPathComponent
            #if os(Linux)
            // agterm-server's install keeps its resources beside the CLI
            candidates.append((directory as NSString).appendingPathComponent("resources/terminfo"))
            #else
            let contents = (directory as NSString).deletingLastPathComponent
            candidates.append((contents as NSString).appendingPathComponent("Resources/terminfo"))
            #endif
        }
        if let env = environment["TERMINFO"], !env.isEmpty {
            candidates.append(env)
        }
        return candidates
    }

    /// The first candidate directory that holds the entry under either hashed layout: ncurses files it
    /// under the first letter (`x/`), Darwin's under its hex code (`78/`).
    public static func terminfoDirectory(clientPath: String?, environment: [String: String],
                                         fileManager: FileManager = .default) -> String? {
        candidateDirectories(clientPath: clientPath, environment: environment).first { directory in
            ["78", "x"].contains { fileManager.fileExists(atPath: "\(directory)/\($0)/\(entry)") }
        }
    }

    /// The local dump: `infocmp -x` so the entry's extended capabilities (the ones worth installing it
    /// for) come along. `TERMINFO` is set for the child so it reads the chosen database and nothing else.
    static func dumpCommand(terminfoDirectory: String, infocmp: String = "/usr/bin/infocmp")
        -> (argv: [String], environment: [String: String]) {
        ([infocmp, "-x", entry], ["TERMINFO": terminfoDirectory])
    }

    /// What the remote account runs, with the source on stdin. One line, because the account's login
    /// shell parses the quoted command before `/bin/sh` sees it and tcsh rejects a quoted newline.
    static let remoteScript = "command -v tic >/dev/null 2>&1 || { printf '%s\\n' "
        + "'agterm: tic is not installed on this host, install ncurses first' >&2; exit 3; }; "
        + "mkdir -p \"$HOME/.terminfo\" && exec tic -x -o \"$HOME/.terminfo\" -"

    /// Installer-owned execution settings; a command-line `-o` wins over any config file, and each of
    /// these set the other way would discard the source, skip or detach the command, or refuse it.
    static let executionOptions = [
        "-T",
        "-o", "StdinNull=no",
        "-o", "SessionType=default",
        "-o", "ForkAfterAuthentication=no",
        "-o", "RemoteCommand=none",
    ]

    /// The ssh invocation. `-T` because the source travels on stdin and the remote must see EOF, which a
    /// pty would never deliver. No `BatchMode`: this is run by hand, so a password or host-key prompt is
    /// expected and answered on the terminal. The script runs through a quoted `/bin/sh -c` because sshd
    /// hands the command to the account's shell, which need not parse POSIX syntax.
    public static func installCommand(_ connection: Connection, ssh: String = "ssh") throws -> [String] {
        try sshCommand(connection, ssh: ssh) + [CommandRestore.shellQuotedLine(["/bin/sh", "-c", remoteScript])]
    }

    /// sshCommand is the ssh invocation up to and including the destination, for any command run this way.
    static func sshCommand(_ connection: Connection, ssh: String) throws -> [String] {
        let destination = connection.destination
        guard RemoteSession.isPlain(destination), !destination.hasPrefix("-") else { throw Failure.invalidDestination }
        var argv = [ssh] + executionOptions
        if let port = connection.port { argv += ["-p", String(port)] }
        for identity in connection.identities { argv += ["-i", identity] }
        if let jump = connection.jump { argv += ["-J", jump] }
        if let config = connection.config { argv += ["-F", config] }
        argv.append(destination)
        return argv
    }

    /// Dump locally, then install remotely. The dump completes before ssh starts, so a missing or broken
    /// local entry never opens a connection. ssh inherits stdout and stderr, which is where its prompts
    /// and the remote diagnostics go. `ssh` and `infocmp` are injectable so tests can stand in fakes.
    public static func run(_ connection: Connection, clientPath: String?, environment: [String: String],
                           ssh: String = "ssh", infocmp: String = "/usr/bin/infocmp") throws -> Outcome {
        let argv = try installCommand(connection, ssh: ssh)
        let searched = candidateDirectories(clientPath: clientPath, environment: environment)
        guard let directory = terminfoDirectory(clientPath: clientPath, environment: environment) else {
            throw Failure.terminfoNotFound(searched: searched)
        }
        let source = try dump(terminfoDirectory: directory, infocmp: infocmp)
        return try install(argv: argv, source: source, environment: environment)
    }

    private static func dump(terminfoDirectory: String, infocmp: String) throws -> Data {
        let command = dumpCommand(terminfoDirectory: terminfoDirectory, infocmp: infocmp)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.argv[0])
        process.arguments = Array(command.argv.dropFirst())
        process.environment = command.environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // both pipes are drained before the wait, or a dump larger than the pipe buffer deadlocks
        let source = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.dumpFailed(status: process.terminationStatus,
                                     stderr: String(decoding: diagnostics, as: UTF8.self))
        }
        return source
    }

    /// ssh runs in the caller's foreground process group so its prompts work; see `ForegroundSpawn`.
    /// Off Darwin it refuses: installing pushes a Mac's terminfo to a remote host, and the Linux build is a server.
    private static func install(argv: [String], source: Data, environment: [String: String]) throws -> Outcome {
        #if canImport(Darwin)
        do {
            return try ForegroundSpawn.run(argv, input: .data(source), environment: environment)
        } catch let failure as ForegroundSpawn.Failure {
            throw Failure.spawnFailed(operation: failure.operation, errno: failure.errno)
        }
        #else
        throw Failure.spawnFailed(operation: "terminfo install", errno: ENOTSUP)
        #endif
    }
}
