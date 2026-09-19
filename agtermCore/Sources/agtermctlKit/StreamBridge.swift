import Foundation
import agtermCore

/// Bridges a streaming control command between a pair of descriptors and the app's socket: the request
/// goes out, its one ordinary reply comes back, and after an ok everything is copied both ways untouched.
///
/// Run on the origin by the viewer's ssh, so `output` is what the viewer parses: only frames are ever
/// written to it.
struct StreamBridge: Sendable {
    let socket: Int32
    let input: Int32
    let output: Int32

    /// Sends `request` and reads its reply. Throws the server's error, or a description of a reply that
    /// never came, and in both cases has written nothing to `output`.
    func open(_ request: ControlRequest) throws {
        var line = try JSONEncoder().encode(request)
        line.append(UInt8(ascii: "\n"))
        guard Self.writeAll(socket, line) else { throw SocketClientError("could not send the request") }
        guard let reply = readReplyLine() else { throw SocketClientError("the app closed the connection without answering") }
        let response: ControlResponse
        do {
            response = try JSONDecoder().decode(ControlResponse.self, from: reply)
        } catch {
            throw SocketClientError("could not decode the reply: \(error.localizedDescription)")
        }
        guard response.ok else { throw SocketClientError(response.error ?? "the app refused the stream") }
    }

    /// Copies both ways until either side ends. `input` ending shuts the socket down, which is how the app
    /// learns the viewer went away; the socket ending returns.
    ///
    /// Both directions have stopped by the time this returns. The caller closes `socket` next, and a worker
    /// still blocked reading `input` would later write into whatever reused that descriptor number.
    func pump() {
        var wake: [Int32] = [-1, -1]
        guard pipe(&wake) == 0 else { return }
        defer {
            close(wake[0])
            close(wake[1])
        }
        let socket = socket
        let input = input
        let cancel = wake[0]
        let finished = DispatchSemaphore(value: 0)
        let upstream = Thread {
            Self.copyUntilCancelled(from: input, to: socket, cancel: cancel)
            finished.signal()
        }
        upstream.name = "agtermctl.stream.upstream"
        upstream.start()
        Self.copy(from: socket, to: output)
        var byte: UInt8 = 1
        _ = write(wake[1], &byte, 1)
        finished.wait()
    }

    /// One byte at a time: a frame can sit right behind the reply in the same packet, and a chunked read
    /// would swallow it.
    private func readReplyLine() -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let count = read(socket, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { return line }
            line.append(byte)
            guard line.count <= ControlWire.maxRequestLineBytes else { return nil }
        }
    }

    /// `source` ending shuts `destination` down. `cancel` becoming readable just stops.
    private static func copyUntilCancelled(from source: Int32, to destination: Int32, cancel: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            var pollers = [pollfd(fd: source, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: cancel, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&pollers, 2, -1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, pollers[1].revents == 0 else { return }
            let count = chunk.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0, writeAll(destination, Data(chunk[0..<count])) else {
                shutdown(destination, Int32(SHUT_RDWR))
                return
            }
        }
    }

    private static func copy(from source: Int32, to destination: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0, writeAll(destination, Data(chunk[0..<count])) else { return }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let count = write(fd, base + offset, data.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
