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
    private(set) var launches: [[String]] = []
    private(set) var origins: [FakePageOrigin] = []
    private(set) var helpers: [Helper] = []

    init(files: [String: (String, Data)] = [:]) { self.files = files }

    func launch(_ argv: [String], onExit: @escaping @MainActor () -> Void) throws -> RemotePageHelper {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
        launches.append(argv)
        let origin = FakePageOrigin(fd: pair[1], files: files, held: held, chunkSize: chunkSize, reply: reply,
                                    holdCancels: holdCancels)
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
