import Foundation
import agtermCore

/// ServerControlSocket serves agterm-server's control socket: one newline-delimited request and one reply per
/// connection, handled inline on a single accept thread, as the Mac app serves its own.
public final class ServerControlSocket: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    static let readTimeoutSeconds = 5
    static let writeTimeoutSeconds = 5
    /// Bounds a whole request read, since the receive timeout bounds each `read` alone.
    static let readDeadlineSeconds = 10

    private let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var loop: ControlAcceptLoop?

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// start binds the socket, mode 0600, and starts accepting. The caller holds the state-directory lock, which
    /// is what makes removing a stale file at the path safe.
    public func start() throws {
        let fd = try UnixSocket.listening(path: path)
        guard let loop = ControlAcceptLoop(listenFD: fd) else {
            close(fd)
            unlink(path)
            throw UnixSocket.Failure.system("accept loop setup failed: \(String(cString: strerror(errno)))")
        }
        lock.withLock { self.loop = loop }
        let handler = handler
        let thread = Thread {
            while let conn = loop.next() { Self.serve(conn, handler: handler) }
            loop.finish()
        }
        thread.name = "agterm-server.control.accept"
        thread.start()
    }

    /// stop ends the accept loop and removes the socket file.
    public func stop() {
        let loop = lock.withLock { () -> ControlAcceptLoop? in
            defer { self.loop = nil }
            return self.loop
        }
        guard let loop else { return }
        loop.stop()
        unlink(path)
    }

    static func serve(_ conn: Int32, handler: @escaping Handler) {
        defer { close(conn) }
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var readTimeout = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
        var writeTimeout = timeval(tv_sec: writeTimeoutSeconds, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))

        guard let line = readLine(conn) else {
            _ = write(conn, ControlResponse(ok: false, error: "request too large or read failed"))
            return
        }
        let request: ControlRequest
        do {
            request = try JSONDecoder().decode(ControlRequest.self, from: line)
        } catch {
            _ = write(conn, ControlResponse(ok: false, error: ControlWire.invalidRequestMessage(error)))
            return
        }
        _ = write(conn, runBlocking { await handler(request) })
    }

    /// readLine reads up to the first newline; nil on EOF before any byte, a read error, the size cap or the
    /// overall deadline.
    static func readLine(_ conn: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        let deadline = DispatchTime.now() + .seconds(readDeadlineSeconds)
        while true {
            if DispatchTime.now() > deadline { return nil }
            let count = read(conn, &byte, 1)
            if count == 0 { return buffer.isEmpty ? nil : buffer }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if byte == UInt8(ascii: "\n") { return buffer }
            buffer.append(byte)
            if buffer.count > ControlWire.maxRequestLineBytes { return nil }
        }
    }

    /// write sends `response` as one line. A client that hung up fails it with EPIPE instead of SIGPIPE.
    static func write(_ conn: Int32, _ response: ControlResponse) -> Bool {
        guard var data = try? JSONEncoder().encode(response) else { return false }
        data.append(UInt8(ascii: "\n"))
        return data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                #if canImport(Darwin)
                let count = Darwin.write(conn, base + offset, data.count - offset)
                #else
                let count = Glibc.send(conn, base + offset, data.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    /// runBlocking runs `body` on a fresh task and blocks the accept thread until it finishes.
    static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}
