import ArgumentParser
import Foundation
import agtermCore

/// OverlayJobRunner supervises one remote overlay job on the origin: it claims the job over the app's
/// socket, runs the program under the pty it inherited from the viewer's ssh, reports how it ended, and
/// stops it when cancelled. Everything that decides the outcome is here; the command only wires signals.
final class OverlayJobRunner: @unchecked Sendable {
    /// How long a cancelled program gets to exit before it is killed.
    static let defaultGrace: TimeInterval = 3

    private let socket: Int32
    private let terminal: Int32
    private let grace: TimeInterval
    private let lock = NSLock()
    private var group: pid_t = 0
    private var killAt: Date?

    /// `terminal` is the pty the program runs under, the helper's own stdin by default.
    init(socket: Int32, terminal: Int32 = STDIN_FILENO, grace: TimeInterval = defaultGrace) {
        self.socket = socket
        self.terminal = terminal
        self.grace = grace
        // the program must not hold the app's connection: only the helper dying closes it, and that close
        // is how the app learns an unreported job is over
        _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
    }

    /// Sends the claim and returns the launch context. Throws the app's refusal, having launched nothing.
    func claim(_ job: String, token: String? = nil) throws -> OverlayLaunchContext {
        var args = ControlArgs()
        args.token = token
        try StreamBridge(socket: socket, input: -1, output: -1)
            .open(ControlRequest(cmd: .sessionOverlayJobRun, target: job, args: token == nil ? nil : args))
        guard let line = readLine(), case .context(let context)? = try? JSONDecoder().decode(OverlayJobFrame.self, from: line) else {
            throw SocketClientError("the app sent no launch context")
        }
        return context
    }

    // ssh-spawned overlays bypass libghostty's terminfo setup
    static func terminalEnvironment(_ base: [String: String], bundledTerminfo: String?) -> [String: String] {
        guard base["TERM"] == TerminfoInstall.entry, base["TERMINFO"]?.isEmpty ?? true, let bundledTerminfo else { return base }
        var environment = base
        environment["TERMINFO"] = bundledTerminfo
        return environment
    }

    /// Runs `context` to the end and returns the helper's own exit status: the program's, 128 plus the
    /// signal that ended it, or 127 when it could not be launched. The program starts from `baseEnvironment`, the helper's own, with the context
    /// over it, so it keeps HOME, PATH and TERM. A report the app never receives changes nothing here.
    func run(_ context: OverlayLaunchContext, baseEnvironment: [String: String]) -> Int32 {
        let environment = baseEnvironment.merging(context.environment) { _, fromContext in fromContext }
        let tty = isatty(terminal) == 1 ? terminal : nil
        let pid: pid_t
        do {
            pid = try Self.spawn(environment: environment, cwd: context.cwd, suspended: tty != nil)
        } catch {
            report(.launchFailed(String(describing: error)))
            return 127
        }
        // the program owns the terminal before it runs a single instruction, or a first read would stop it
        if let tty {
            guard tcsetpgrp(tty, pid) == 0 else {
                kill(-pid, SIGKILL)
                _ = Self.reap(pid)
                report(.launchFailed("could not give the program the terminal"))
                return 127
            }
            kill(pid, SIGCONT)
        }
        let canceledEarly: Bool = lock.withLock {
            group = pid
            return killAt != nil
        }
        report(.started)
        if canceledEarly { kill(-pid, SIGTERM) }
        let listener = Thread { [weak self] in self?.listen() }
        listener.name = "agtermctl.run-job.listen"
        listener.start()
        let status = supervise(pid, tty: tty)
        if let tty { tcsetpgrp(tty, getpgrp()) }
        if lock.withLock({ killAt != nil }) {
            report(.canceled)
        } else {
            report(.exited(Int(status)))
        }
        return status
    }

    /// Stops the program's whole process group: SIGTERM now, SIGKILL once the grace has passed. Safe from
    /// any thread and before the program started, in which case it is stopped as soon as it does.
    func cancel() {
        let pid: pid_t = lock.withLock {
            if killAt == nil { killAt = Date().addingTimeInterval(grace) }
            return group
        }
        if pid > 0 { kill(-pid, SIGTERM) }
    }

    /// Waits for the program, watching the terminal for a hangup, which cancels as a cancel frame does.
    /// After a cancel it also waits for the rest of the program's group, killing what outlives the grace,
    /// so no descendant is left running behind a `canceled` report.
    private func supervise(_ pid: pid_t, tty: Int32?) -> Int32 {
        var status: Int32?
        var killed = false
        while true {
            if status == nil { status = Self.reap(pid, blocking: false) }
            // after the reap: a program whose read got the hangup's end-of-file has already exited, and that
            // exit must not pass for an ordinary one while its group lives on
            if let tty, lock.withLock({ killAt == nil }), Self.hungUp(tty) { cancel() }
            let deadline = lock.withLock { killAt }
            if status != nil, deadline == nil || !Self.groupRuns(pid) { break }
            if let deadline, !killed, Date() >= deadline {
                kill(-pid, SIGKILL)
                killed = true
            }
            usleep(20_000)
        }
        return status ?? 0
    }

    /// Reads the app's frames until the connection ends. The app going away does not stop the program: it
    /// runs on under the viewer's pty, only unreported.
    private func listen() {
        while let line = readLine() {
            if case .cancel? = try? JSONDecoder().decode(OverlayJobFrame.self, from: line) { cancel() }
        }
    }

    private func report(_ frame: OverlayJobFrame) {
        guard let line = try? frame.line() else { return }
        _ = StreamBridge.sendAll(socket, line)
    }

    /// One byte at a time, so nothing behind a line is consumed before its reader asks for it.
    private func readLine() -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let count = read(socket, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { return line }
            line.append(byte)
            guard line.count <= PresentationCodec.maxFrameBytes else { return nil }
        }
    }

    /// Whether the terminal hung up, asked without reading, so the program's input is never taken. Darwin
    /// reports a pty's hangup only to a poll that asks for input; pending input alone sets no POLLHUP.
    private static func hungUp(_ tty: Int32) -> Bool {
        var probe = pollfd(fd: tty, events: Int16(POLLIN), revents: 0)
        guard poll(&probe, 1, 0) > 0 else { return false }
        return probe.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0
    }

    /// The program leads a process group of its own, which a cancel ends as a whole and which becomes the
    /// terminal's foreground, so it gets the keys and SIGWINCH directly. Under a terminal it starts
    /// suspended until that handoff is done. Its signal dispositions are reset to the defaults the helper
    /// changes. `eval` keeps the command's own exit status as the shell's.
    static func spawn(environment: [String: String], cwd: String, suspended: Bool) throws -> pid_t {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGQUIT, SIGTSTP, SIGTTOU, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setpgroup(&attributes, 0)
        var flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP
        #if canImport(Darwin)
        if suspended { flags |= POSIX_SPAWN_START_SUSPENDED }
        // a descriptor another thread has not yet marked close-on-exec stays out of the program; only open streams
        // are kept, and only when not close-on-exec, since inheriting clears the flag and a closed stream fails the spawn
        flags |= POSIX_SPAWN_CLOEXEC_DEFAULT
        for stream in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where fcntl(stream, F_GETFD) == 0 {
            posix_spawn_file_actions_addinherit_np(&actions, stream)
        }
        let script = #"eval "$AGTERM_OVL_CMD""#
        #else
        // glibc has no START_SUSPENDED, so the shell stops itself before the command and spawn waits for the stop
        let script = suspended ? #"kill -STOP $$; eval "$AGTERM_OVL_CMD""# : #"eval "$AGTERM_OVL_CMD""#
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))
        let argv = ["/bin/sh", "-c", script]
        let env = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStrings(argv) { argvPointers in
            withCStrings(env) { envPointers in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes, argvPointers, envPointers)
            }
        }
        guard result == 0 else { throw SocketClientError("could not start the program: \(String(cString: strerror(result)))") }
        #if !canImport(Darwin)
        if suspended {
            var status: Int32 = 0
            while waitpid(pid, &status, WUNTRACED) < 0 {
                guard errno == EINTR else {
                    throw SocketClientError("could not wait for the program to stop: \(String(cString: strerror(errno)))")
                }
            }
            guard status & 0xff == 0x7f else { throw SocketClientError("the program ended before it got the terminal") }
        }
        #endif
        return pid
    }

    // kill(-group, 0) counts zombies, and an orphan's zombie stays for good under a PID 1 that never reaps,
    // as a container's `tail -f /dev/null`
    private static func groupRuns(_ group: pid_t) -> Bool {
        guard kill(-group, 0) == 0 else { return false }
        #if os(Linux)
        return !onlyZombies(in: group)
        #else
        return true
        #endif
    }

    #if os(Linux)
    // a member that cannot be read is no proof that the group has only zombies left
    private static func onlyZombies(in group: pid_t) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return false }
        var members = 0
        for entry in entries where pid_t(entry) != nil {
            let fd = open("/proc/\(entry)/stat", O_RDONLY)
            guard fd >= 0 else {
                if errno == ENOENT || errno == ESRCH { continue }
                return false
            }
            defer { close(fd) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else {
                if count == 0 || errno == ESRCH { continue }
                return false
            }
            guard let fields = statusFields(String(decoding: buffer[..<count], as: UTF8.self)) else { return false }
            guard fields.group == group else { continue }
            guard fields.state == "Z" else { return false }
            members += 1
        }
        return members > 0
    }
    #endif

    // the command name in parentheses may hold `)` and spaces itself, so the fields start after its last `)`
    static func statusFields(_ stat: String) -> (state: Character, group: pid_t)? {
        guard let end = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: end)...].split(separator: " ")
        guard fields.count >= 3, fields[0].count == 1, let state = fields[0].first, let group = pid_t(fields[2]) else {
            return nil
        }
        return (state, group)
    }

    /// The program's status once it ended: its exit code, or 128 plus the signal that ended it. Nil when a
    /// non-blocking check finds it still running.
    @discardableResult
    private static func reap(_ pid: pid_t, blocking: Bool = true) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
            if result < 0, errno == EINTR { continue }
            guard result == pid else { return nil }
            let low = status & 0x7f
            return low == 0 ? (status >> 8) & 0xff : 128 + low
        }
    }
}

private func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

extension Session.Overlay {
    struct RunJob: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run-job",
            abstract: "Run a remote overlay job this app handed to another Mac.",
            discussion: """
            Run on this Mac by the agterm on another Mac, over ssh, when it shows one of this app's \
            overlays: it claims the job, runs its program under that ssh terminal, and reports how it \
            ended. It is not meant to be run by hand. A job that cannot be claimed exits 1 having \
            launched nothing, one whose program cannot be launched exits 127, and otherwise it exits \
            with the program's status.
            """)

        @Argument(help: "The job id the other Mac was handed.")
        var job: String

        @Option(name: .long, help: "The offer token the other Mac was handed with the job.")
        var token: String?

        @OptionGroup var options: BasicOptions

        func run() throws {
            let socket = try SocketClient(path: options.socketPath()).connect()
            defer { close(socket) }
            let runner = OverlayJobRunner(socket: socket)
            let context: OverlayLaunchContext
            do {
                context = try runner.claim(job, token: token)
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                throw ExitCode.failure
            }
            // like a shell running a foreground command: the terminal's keys are the program's, and losing
            // the terminal or being told to stop cancels it
            signal(SIGINT, SIG_IGN)
            signal(SIGQUIT, SIG_IGN)
            signal(SIGTSTP, SIG_IGN)
            // taking the terminal back from the program's group happens from the background
            signal(SIGTTOU, SIG_IGN)
            var sources: [DispatchSourceSignal] = []
            for stop in [SIGHUP, SIGTERM] {
                signal(stop, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: stop, queue: .global())
                source.setEventHandler { runner.cancel() }
                source.resume()
                sources.append(source)
            }
            let bundled = TerminfoInstall.terminfoDirectory(clientPath: Version.clientPath(), environment: [:])
            let base = OverlayJobRunner.terminalEnvironment(ProcessInfo.processInfo.environment, bundledTerminfo: bundled)
            let status = runner.run(context, baseEnvironment: base)
            sources.forEach { $0.cancel() }
            throw ExitCode(status)
        }
    }
}
