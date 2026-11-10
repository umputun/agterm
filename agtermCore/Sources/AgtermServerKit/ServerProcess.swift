import Foundation

/// ServerProcess runs one short helper, zmx or systemd-run, and collects what it printed.
///
/// It spawns and reaps the child itself: on Linux, `Process` reports a child's exit only once every holder of its
/// output pipe has closed it, and a daemon the child started may hold one for its whole life.
enum ServerProcess {
    struct Output: Equatable, Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case launch(String)
        case timedOut([String])

        var description: String {
            switch self {
            case .launch(let reason): "cannot start: \(reason)"
            case .timedOut(let argv): "timed out: \(argv.joined(separator: " "))"
            }
        }
    }

    /// Grace for SIGTERM before SIGKILL, and for output to arrive after the child exits.
    static let grace: TimeInterval = 0.25

    /// run waits for the child for at most `timeout`; output is collected for `grace` after it exits. The child gets
    /// default signal handling and an empty signal mask, whatever this process ignores or blocks.
    static func run(_ argv: [String], environment: [String: String], directory: String? = nil, input: Data? = nil,
                    timeout: TimeInterval) throws -> Output {
        let stdout = try pipePair()
        let stderr = try pipePair()
        let stdin = try input.map { _ in try pipePair() }
        let pid: pid_t
        do {
            pid = try spawn(argv, environment: environment, directory: directory,
                            descriptors: (stdin?.read, stdout.write, stderr.write))
        } catch {
            [stdout.read, stdout.write, stderr.read, stderr.write, stdin?.read, stdin?.write].compactMap { $0 }.forEach { close($0) }
            throw error
        }
        close(stdout.write)
        close(stderr.write)
        let out = Collector(stdout.read)
        let err = Collector(stderr.read)
        let waiter = Waiter(pid)
        let feeder = stdin.map { pipe in
            close(pipe.read)
            return Feeder(pipe.write, input ?? Data())
        }
        guard let status = waiter.wait(timeout) else {
            kill(pid, SIGTERM)
            if waiter.wait(grace) == nil {
                kill(pid, SIGKILL)
                _ = waiter.wait(.infinity)
            }
            feeder?.finish(0)
            _ = out.collect(0)
            _ = err.collect(0)
            throw Failure.timedOut(argv)
        }
        feeder?.finish(grace)
        return Output(status: status, stdout: out.collect(grace), stderr: err.collect(grace))
    }

    /// spawn starts `argv` with `descriptors` as its stdin (/dev/null when nil), stdout and stderr.
    private static func spawn(_ argv: [String], environment: [String: String], directory: String?,
                              descriptors: (stdin: Int32?, stdout: Int32, stderr: Int32)) throws -> pid_t {
        let (stdin, stdout, stderr) = descriptors
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        if let stdin {
            posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var flags = Int32(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        // nothing but the three descriptors above reaches the child, which may be a daemon living for the pane's life
        #if canImport(Darwin)
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #elseif canImport(Glibc)
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))

        // musl has no closefrom action, so the server's own binary closes them in the child before the real exec
        #if canImport(Musl)
        let launched = ["/proc/self/exe", CleanExec.argument] + argv
        #else
        let launched = argv
        #endif
        var arguments = launched.map { strdup($0) } + [nil]
        var variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (arguments + variables).forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, launched[0], &actions, &attributes, &arguments, &variables)
        guard code == 0 else { throw Failure.launch("\(argv[0]): \(String(cString: strerror(code)))") }
        return pid
    }

    /// pipePair is a pipe whose ends close on exec, so a child spawned meanwhile for another call cannot keep
    /// either open; the spawn's dup2 hands the child its own end without the flag.
    private static func pipePair() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw Failure.launch("pipe: \(String(cString: strerror(errno)))") }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    /// Feeder writes the child's input on its own thread until done or `finish` gives up, so neither a child that
    /// never reads nor a descendant still holding the read end can keep it, or the caller, waiting. A closed read end
    /// fails the write with EPIPE rather than raising SIGPIPE: per descriptor on Darwin, per thread on Linux.
    private final class Feeder: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private let done = DispatchSemaphore(value: 0)

        init(_ fd: Int32, _ data: Data) {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            #if canImport(Darwin)
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            #endif
            let thread = Thread { [self] in
                var pipeSignal = sigset_t()
                sigemptyset(&pipeSignal)
                sigaddset(&pipeSignal, SIGPIPE)
                pthread_sigmask(SIG_BLOCK, &pipeSignal, nil)
                data.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    var offset = 0
                    while offset < data.count, !lock.withLock({ stopped }) {
                        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let ready = poll(&poller, 1, 50)
                        if ready < 0, errno == EINTR { continue }
                        guard ready >= 0 else { return }
                        guard ready > 0 else { continue }
                        let count = write(fd, base + offset, data.count - offset)
                        if count < 0, errno == EINTR || errno == EAGAIN { continue }
                        guard count > 0 else { return }
                        offset += count
                    }
                }
                close(fd)
                done.signal()
            }
            thread.start()
        }

        func finish(_ timeout: TimeInterval) {
            _ = done.wait(timeout: .now() + timeout)
            lock.withLock { stopped = true }
        }
    }

    /// Waiter reaps the child on its own thread and reports its status as an exit code, `128 + signal` for a signal.
    private final class Waiter: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var status: Int32?

        init(_ pid: pid_t) {
            let thread = Thread { [self] in
                var raw: Int32 = 0
                while waitpid(pid, &raw, 0) < 0, errno == EINTR {}
                let signal = raw & 0x7f
                lock.withLock { status = signal == 0 ? (raw >> 8) & 0xff : 128 + signal }
                done.signal()
            }
            thread.start()
        }

        func wait(_ timeout: TimeInterval) -> Int32? {
            let deadline: DispatchTime = timeout.isInfinite ? .distantFuture : .now() + timeout
            guard done.wait(timeout: deadline) == .success else { return nil }
            done.signal()
            return lock.withLock { status }
        }
    }

    /// Collector reads one pipe on its own thread until EOF, or until `collect` gives up on a write end held
    /// elsewhere; it polls, so it never sits in a `read` nothing will finish.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var stopped = false
        private let done = DispatchSemaphore(value: 0)

        init(_ fd: Int32) {
            let thread = Thread { [self] in
                var chunk = [UInt8](repeating: 0, count: 16 * 1024)
                while !lock.withLock({ stopped }) {
                    var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&poller, 1, 50)
                    if ready < 0, errno == EINTR { continue }
                    guard ready >= 0 else { break }
                    guard ready > 0 else { continue }
                    let count = read(fd, &chunk, chunk.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    lock.withLock { data.append(contentsOf: chunk[0..<count]) }
                }
                close(fd)
                done.signal()
            }
            thread.start()
        }

        func collect(_ timeout: TimeInterval) -> String {
            _ = done.wait(timeout: .now() + timeout)
            return lock.withLock {
                stopped = true
                return String(decoding: data, as: UTF8.self)
            }
        }
    }
}

/// CleanExec is the musl spawn helper: ServerProcess starts agterm-server's own binary with `argument` first, and that
/// child, single-threaded after its exec, closes every descriptor above stderr and execs the real program. Nothing
/// another server thread opened, close-on-exec or not, reaches the program.
public enum CleanExec {
    static let argument = "--agterm-clean-exec"

    /// runIfRequested replaces this process with the program after `argument` when it was started as the helper, and
    /// returns otherwise. agterm-server calls it before anything else runs; it exits 127 rather than exec with a
    /// descriptor it could not close.
    public static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.count > 2, arguments[1] == argument else { return }
        guard let open = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") else {
            fail("cannot list /proc/self/fd")
        }
        for fd in open.compactMap({ Int32($0) }) where fd > STDERR_FILENO { close(fd) }
        var argv = arguments.dropFirst(2).map { strdup($0) } + [nil]
        execv(arguments[2], &argv)
        fail("\(arguments[2]): \(String(cString: strerror(errno)))")
    }

    private static func fail(_ reason: String) -> Never {
        FileHandle.standardError.write(Data("agterm-server: \(reason)\n".utf8))
        _exit(127)
    }
}
