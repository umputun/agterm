import Darwin
import Foundation
import agtermCore

protocol ClientPeer: AnyObject {
    func send(_ frame: Data, deadline: TimeInterval) throws
    func receive(deadline: TimeInterval) throws -> SessionHost.Response
    func close()
}

public final class Client {
    private let connect: () throws -> any ClientPeer
    private let diagnostic: (String) -> Void
    private let execute: ([String], [String: String]) throws -> Void

    init(connect: @escaping () throws -> any ClientPeer, diagnostic: @escaping (String) -> Void,
         execute: @escaping ([String], [String: String]) throws -> Void) {
        self.connect = connect
        self.diagnostic = diagnostic
        self.execute = execute
    }

    func run(request: SessionHost.Ensure) throws {
        guard request.argv.count >= 3, request.argv[1] == "attach", request.argv[2] == request.name else { throw HostFailure.invalidRequest }
        var phase = SessionHost.DispatchPhase.beforeDispatch
        var reply: SessionHost.Response?
        do {
            let frame = try SessionHost.encodeFrame(SessionHost.Request.ensure(request))
            let peer = try connect()
            defer { peer.close() }
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            phase = .afterDispatch
            try peer.send(frame, deadline: deadline)
            reply = try peer.receive(deadline: deadline)
        } catch {}
        let outcome = SessionHost.ClientOutcome.decide(phase: phase, reply: reply)
        if let message = outcome.diagnostic { diagnostic(message) }
        try execute(outcome == .fullAttach ? request.argv : Array(request.argv.prefix(3)), request.env)
    }

    public static func run(name: String, argv: [String]) throws {
        let environment = ProcessInfo.processInfo.environment
        var size = winsize()
        if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) != 0 { _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) }
        let request = SessionHost.Ensure(name: name, argv: argv, cwd: FileManager.default.currentDirectoryPath,
                                         env: environment, rows: size.ws_row == 0 ? 24 : size.ws_row, cols: size.ws_col == 0 ? 80 : size.ws_col)
        let client = Client(connect: {
            let connector = try ClientConnector(socketDirectory: environment["ZMX_DIR"] ?? "", environment: environment)
            return try connector.ensureRunning()
        }, diagnostic: { message in
            try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
        }, execute: exec)
        try client.run(request: request)
    }

    private static func exec(_ argv: [String], _ environment: [String: String]) throws {
        guard let executable = argv.first, executable.hasPrefix("/"), argv.allSatisfy({ !$0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            throw HostFailure.invalidRequest
        }
        let arguments = argv.map { strdup($0) } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in arguments + variables { free(pointer) } }
        guard arguments.dropLast().allSatisfy({ $0 != nil }), variables.dropLast().allSatisfy({ $0 != nil }) else { throw HostFailure.system(ENOMEM) }
        arguments.withUnsafeBufferPointer { args in
            variables.withUnsafeBufferPointer { env in _ = execve(executable, args.baseAddress, env.baseAddress) }
        }
        throw HostFailure.system(errno)
    }
}
