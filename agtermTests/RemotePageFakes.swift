import Foundation
@testable import agterm
import agtermCore

final class FakePageOrigin: @unchecked Sendable {
    private let fd: Int32
    private let state = NSCondition()
    private let writing = NSLock()
    private let workers = DispatchGroup()
    private var frames: [PageServeFrame] = []
    private var cancelled: Set<Int> = []
    private var heldIDs: Set<Int> = []
    private var heldCancels: [Int] = []
    private var chunksWritten = 0
    private var descriptorClosed = false
    private let files: [String: (String, Data)]
    private let held: Set<String>
    private let chunkSize: Int
    private let reply: String?
    private let holdCancels: Bool
    var log: BoundedFile.TailRead?

    init(fd: Int32, files: [String: (String, Data)], held: Set<String>, chunkSize: Int, reply: String?,
         holdCancels: Bool) {
        self.fd = fd
        self.files = files
        self.held = held
        self.chunkSize = chunkSize
        self.reply = reply
        self.holdCancels = holdCancels
    }

    var received: [PageServeFrame] { state.withLock { frames } }
    var written: Int { state.withLock { chunksWritten } }

    func start() {
        Thread { [self] in readLoop() }.start()
    }

    func answerCancels() {
        for id in state.withLock({ () -> [Int] in defer { heldCancels.removeAll() }; return heldCancels }) {
            write(.failure(id: id, error: PageServeFrame.cancelled))
        }
    }

    func close() {
        state.withLock {
            if !descriptorClosed { Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }

    private func readLoop() {
        defer {
            workers.wait()
            state.withLock {
                descriptorClosed = true
                Darwin.close(fd)
            }
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let frame = try? PageServeCodec.decode(line) { handle(frame) }
            }
        }
    }

    private func handle(_ frame: PageServeFrame) {
        var answerCancel = false
        state.withLock {
            frames.append(frame)
            if case .cancel(let id) = frame {
                cancelled.insert(id)
                answerCancel = heldIDs.remove(id) != nil
                if answerCancel, holdCancels {
                    heldCancels.append(id)
                    answerCancel = false
                }
            }
            if case .resource(let id, let path) = frame, held.contains(path) { heldIDs.insert(id) }
        }
        switch frame {
        case .resource(let id, let path):
            guard !held.contains(path) else { return }
            workers.enter()
            Thread { [self] in
                serve(id, path)
                workers.leave()
            }.start()
        case .cancel(let id):
            if answerCancel { write(.failure(id: id, error: PageServeFrame.cancelled)) }
        case .bridge(let id, _):
            if let reply { write(.reply(id: id, response: reply)) }
        case .logTail(let id, let stamp):
            answerLog(id, stamp)
        default:
            return
        }
    }

    private func serve(_ id: Int, _ path: String) {
        guard let (mime, data) = files[path] else {
            write(.failure(id: id, error: "no such file"))
            return
        }
        write(.head(id: id, mimeType: mime))
        var offset = 0
        while offset < data.count {
            if state.withLock({ cancelled.contains(id) }) {
                write(.failure(id: id, error: PageServeFrame.cancelled))
                return
            }
            let end = min(offset + chunkSize, data.count)
            guard write(.chunk(id: id, data: data.subdata(in: offset..<end))) else { return }
            state.withLock { chunksWritten += 1 }
            offset = end
        }
        write(.end(id: id))
    }

    private func answerLog(_ id: Int, _ stamp: BoundedFile.FileStamp?) {
        guard let log else {
            write(.failure(id: id, error: "not a log page"))
            return
        }
        guard log.stamp != stamp else {
            write(.logUnchanged(id: id))
            return
        }
        write(.logHead(id: id, stamp: log.stamp, offset: log.offset))
        for start in stride(from: 0, to: log.data.count, by: chunkSize) {
            write(.chunk(id: id, data: log.data.subdata(in: start..<min(start + chunkSize, log.data.count))))
        }
        write(.end(id: id))
    }

    @discardableResult
    private func write(_ frame: PageServeFrame) -> Bool {
        guard let line = try? PageServeCodec.encode(frame) else { return false }
        writing.lock()
        defer { writing.unlock() }
        return line.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            var offset = 0
            while offset < line.count {
                let count = Darwin.write(fd, base + offset, line.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

@MainActor
final class FakePageLauncher: RemotePageLauncher {
    final class Helper: RemotePageHelper {
        let descriptor: Int32
        private(set) var terminated = false
        private let onExit: @MainActor () -> Void

        init(descriptor: Int32, onExit: @escaping @MainActor () -> Void) {
            self.descriptor = descriptor
            self.onExit = onExit
        }

        func terminate() { terminated = true }
        func exit() { onExit() }
    }

    var files: [String: (String, Data)]
    var held: Set<String> = []
    var chunkSize = 1024
    var reply: String? = #"{"ok":true,"result":{}}"#
    var holdCancels = false
    var failsLaunch = false
    var failsNextLaunch = false
    var log: BoundedFile.TailRead?
    private(set) var launches: [[String]] = []
    private(set) var origins: [FakePageOrigin] = []
    private(set) var helpers: [Helper] = []

    init(files: [String: (String, Data)] = [:]) { self.files = files }

    func launch(_ argv: [String], onExit: @escaping @MainActor () -> Void) throws -> RemotePageHelper {
        if failsLaunch { throw POSIXError(.ENOENT) }
        if failsNextLaunch {
            failsNextLaunch = false
            throw POSIXError(.ENOENT)
        }
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
        launches.append(argv)
        let origin = FakePageOrigin(fd: pair[1], files: files, held: held, chunkSize: chunkSize, reply: reply,
                                    holdCancels: holdCancels)
        origin.log = log
        origins.append(origin)
        origin.start()
        let helper = Helper(descriptor: pair[0], onExit: onExit)
        helpers.append(helper)
        return helper
    }

    func closeAll() {
        for origin in origins { origin.close() }
    }
}

/// ScriptedRunner answers each ssh call with the next scripted result, so one remote flow's several calls are covered.
final class ScriptedRunner: RemoteCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [RemoteCommandResult]
    private var recorded: [[String]] = []
    var beforeCall: (@Sendable (Int) async -> Void)?

    var invocations: [[String]] { lock.withLock { recorded } }

    init(_ results: [RemoteCommandResult]) {
        self.results = results
    }

    func run(_ argv: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
        await beforeCall?(invocations.count)
        await Task.yield()
        return lock.withLock {
            recorded.append(argv)
            return results.isEmpty ? RemoteCommandResult(status: 255, stdout: "", stderr: "unscripted call") : results.removeFirst()
        }
    }
}

@MainActor
final class FakeForwardLauncher: RemoteForwardLauncher {
    final class Process: RemoteForwardProcess {
        private(set) var terminated = false
        var onExit: (@MainActor (String) -> Void)?
        var listener: Int32 = -1

        func terminate() {
            terminated = true
            if listener >= 0 { close(listener) }
            listener = -1
        }
    }

    var listens = true
    private(set) var launches: [[String]] = []
    private(set) var processes: [Process] = []

    func launch(_ argv: [String], onExit: @escaping @MainActor (String) -> Void) throws -> RemoteForwardProcess {
        launches.append(argv)
        let process = Process()
        process.onExit = onExit
        if listens, let port = Self.forwardPort(argv) {
            process.listener = Self.listen(port)
        }
        processes.append(process)
        return process
    }

    var localPort: Int? {
        launches.last.flatMap(Self.forwardPort)
    }

    static func forwardPort(_ argv: [String]) -> Int? {
        let words = argv.first == "/bin/sh" && argv.count == 3
            ? argv[2].components(separatedBy: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            : argv
        guard let index = words.lastIndex(of: "-L"), index + 1 < words.count else { return nil }
        return Int(words[index + 1].split(separator: ":")[1])
    }

    static func listen(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }
}
