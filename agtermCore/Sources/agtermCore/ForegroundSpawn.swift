import Foundation

/// ForegroundSpawn runs a command, ssh in practice, in the caller's foreground process group with the caller's stderr, so a
/// password or host-key prompt it reads from the controlling tty works. Foundation's `Process` puts its child in a
/// new process group, and a background group reading the tty is stopped by SIGTTIN, leaving the caller waiting on a
/// child that can never answer. Darwin only: the Linux build is a server and never runs these commands.
public enum ForegroundSpawn {
    /// Outcome is how the command ended: its exit status, or the signal that killed it.
    public enum Outcome: Equatable, Sendable {
        case exited(Int32)
        case signaled(Int32)
    }

    /// Input is what the command reads on stdin.
    public enum Input: Sendable {
        case data(Data)
        case file(String)
        case nothing
    }

    /// Failure reports a system call that failed on the way to running the command; `errno` is the code it returned.
    public struct Failure: Error, Equatable {
        public let operation: String
        public let errno: Int32
    }

    /// run feeds `input` to `argv` and leaves its stdout and stderr on the caller's.
    public static func run(_ argv: [String], input: Input, environment: [String: String]) throws -> Outcome {
        try spawn(argv, input: input, environment: environment, capture: false).outcome
    }

    /// capture runs `argv` with stdin from `/dev/null` and returns what it printed on stdout; stderr stays the
    /// caller's. A separate entry point so captured output never meets stdin data, which could deadlock both pipes.
    public static func capture(_ argv: [String], environment: [String: String]) throws -> (outcome: Outcome, output: Data) {
        try spawn(argv, input: .nothing, environment: environment, capture: true)
    }

    private static func spawn(_ argv: [String], input: Input, environment: [String: String],
                              capture: Bool) throws -> (outcome: Outcome, output: Data) {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }

        var inputEnds: (read: Int32, write: Int32)?
        switch input {
        case .data:
            let ends = try makePipe()
            inputEnds = ends
            try check(posix_spawn_file_actions_adddup2(&actions, ends.read, STDIN_FILENO), "posix_spawn_file_actions_adddup2")
        case .file(let path):
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, path, O_RDONLY, 0), "posix_spawn_file_actions_addopen")
        case .nothing:
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                      "posix_spawn_file_actions_addopen")
        }
        var outputEnds: (read: Int32, write: Int32)?
        if capture {
            let ends = try makePipe()
            outputEnds = ends
            try check(posix_spawn_file_actions_adddup2(&actions, ends.write, STDOUT_FILENO), "posix_spawn_file_actions_adddup2")
        } else {
            try check(posix_spawn_file_actions_addinherit_np(&actions, STDOUT_FILENO), "posix_spawn_file_actions_addinherit_np")
        }
        try check(posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO), "posix_spawn_file_actions_addinherit_np")

        // the child gets only the descriptors named above: another thread spawning between pipe() and close() would
        // otherwise hand its child a write end, and the command would wait for an EOF that never arrives
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }
        // the child also inherits the spawning thread's signal mask and ignored handlers; a caller that blocks
        // SIGTERM would leave it unkillable by it
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        try check(posix_spawnattr_setsigmask(&attributes, &noSignals), "posix_spawnattr_setsigmask")
        try check(posix_spawnattr_setsigdefault(&attributes, &allSignals), "posix_spawnattr_setsigdefault")
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "posix_spawnattr_setflags")

        var arguments = try copyStrings(argv)
        defer { arguments.forEach { free($0) } }
        var variables = try copyStrings(environment.map { "\($0.key)=\($0.value)" })
        defer { variables.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = argv[0].withCString { path in
            arguments.withUnsafeMutableBufferPointer { args in
                variables.withUnsafeMutableBufferPointer { vars in
                    posix_spawnp(&pid, path, &actions, &attributes, args.baseAddress, vars.baseAddress)
                }
            }
        }
        if let inputEnds { close(inputEnds.read) }
        if let outputEnds { close(outputEnds.write) }
        do {
            try check(spawned, "posix_spawnp")
        } catch {
            if let inputEnds { close(inputEnds.write) }
            if let outputEnds { close(outputEnds.read) }
            throw error
        }

        if let inputEnds, case .data(let data) = input { feed(data, to: inputEnds.write) }
        var output = Data()
        if let outputEnds {
            output = drain(outputEnds.read)
            close(outputEnds.read)
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { throw Failure(operation: "waitpid", errno: errno) }
        }
        let signal = status & 0x7f
        return (signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal), output)
        #else
        throw Failure(operation: "foreground spawn", errno: ENOTSUP)
        #endif
    }

    #if canImport(Darwin)
    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        // pipe reports through errno, unlike the posix_spawn calls that return the code itself
        guard pipe(&fds) == 0 else { throw Failure(operation: "pipe", errno: errno) }
        return (fds[0], fds[1])
    }

    // a command that exits before reading would otherwise SIGPIPE the caller before it can report; the EPIPE the
    // write gets instead is dropped, because the command's own stderr and status say what happened
    private static func feed(_ data: Data, to descriptor: Int32) {
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                if written <= 0 { break }
                offset += written
            }
        }
        close(descriptor)
    }

    private static func drain(_ descriptor: Int32) -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            output.append(buffer, count: count)
        }
        return output
    }

    private static func check(_ result: Int32, _ operation: String) throws {
        guard result == 0 else { throw Failure(operation: operation, errno: result) }
    }

    private static func copyStrings(_ values: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var strings = values.map { strdup($0) }
        guard strings.allSatisfy({ $0 != nil }) else {
            strings.forEach { free($0) }
            throw Failure(operation: "strdup", errno: ENOMEM)
        }
        strings.append(nil)
        return strings
    }
    #endif
}
