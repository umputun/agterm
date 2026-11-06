import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

final class ServerControlSocketTests {
    private let path = "/tmp/agts-sock-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    private var socket: ServerControlSocket?

    deinit {
        socket?.stop()
        unlink(path)
    }

    private final class Adopted: @unchecked Sendable {
        let lock = NSLock()
        var calls: [(cmd: Command, ok: Bool, written: Bool)] = []
        var owners: [ControlStreamOwner] = []
    }

    private func serve(reply: ControlResponse, adopted: Adopted) throws {
        let socket = ServerControlSocket(path: path, handler: { _ in reply }, adopter: { conn, request, response, written in
            adopted.lock.withLock { adopted.calls.append((request.cmd, response.ok, written)) }
            guard response.ok, written else { return false }
            let owner = ControlStreamOwner(descriptor: conn, limits: .init(maxLineBytes: 1024, maxPendingLines: 4,
                                                                          writeTimeoutSeconds: 2))
            owner.start(onLine: { line in _ = owner.send(Data("echo:".utf8) + line + Data("\n".utf8)) }, onClose: {})
            adopted.lock.withLock { adopted.owners.append(owner) }
            return true
        })
        try socket.start()
        self.socket = socket
    }

    // the server reads a request with a 5 s timeout, so connecting, writing and reading stay on one thread
    private func connect(_ request: ControlRequest) async throws -> (fd: Int32, reply: String) {
        let path = path
        let line = try JSONEncoder().encode(request) + Data("\n".utf8)
        let connected: (fd: Int32, reply: String)? = try await offPool {
            guard let fd = UnixSocket.connected(path: path) else { return nil }
            var timeout = timeval(tv_sec: 60, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            do { try sendNoSignal(fd, line) } catch { close(fd); throw error }
            return (fd, Self.readLine(fd) ?? "")
        }
        return try #require(connected)
    }

    private func exchange(_ fd: Int32, sending data: Data? = nil) async throws -> String? {
        try await offPool {
            if let data { try sendNoSignal(fd, data) }
            return Self.readLine(fd)
        }
    }

    private static func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    @Test func aStreamingCommandAnsweredOkKeepsItsConnection() async throws {
        let adopted = Adopted()
        try serve(reply: ControlResponse(ok: true, result: ControlResult(id: "s1")), adopted: adopted)

        let (fd, reply) = try await connect(ControlRequest(cmd: .zmxPresent, target: "s1"))
        defer { close(fd) }
        let echo = try await exchange(fd, sending: Data("frame\n".utf8))

        #expect(reply.contains(#""ok":true"#))
        #expect(echo == "echo:frame")
        #expect(adopted.lock.withLock { adopted.calls.map(\.cmd) } == [.zmxPresent])
    }

    @Test func aRefusedStreamingCommandClosesItsConnection() async throws {
        let adopted = Adopted()
        try serve(reply: ControlResponse(ok: false, error: "no such session"), adopted: adopted)

        let (fd, reply) = try await connect(ControlRequest(cmd: .sessionOverlayPageServe, target: "t1"))
        defer { close(fd) }

        #expect(reply.contains("no such session"))
        #expect(try await exchange(fd) == nil)
        #expect(adopted.lock.withLock { adopted.calls.map { "\($0.cmd.rawValue) \($0.ok) \($0.written)" } }
            == ["session.overlay.page.serve false true"])
    }

    @Test func anOrdinaryCommandNeverReachesTheAdopter() async throws {
        let adopted = Adopted()
        try serve(reply: ControlResponse(ok: true), adopted: adopted)

        let (fd, _) = try await connect(ControlRequest(cmd: .tree))
        defer { close(fd) }

        #expect(try await exchange(fd) == nil)
        #expect(adopted.lock.withLock { adopted.calls.isEmpty })
    }
}
