import Foundation
import Testing
@testable import agtermCore
@testable import agtermctlKit

final class StreamBridgeTests {
    private var server: Int32 = -1
    private var stdinWrite: Int32 = -1
    private var stdoutRead: Int32 = -1
    private let bridge: StreamBridge
    private var owned: [Int32] = []

    init() throws {
        var sockets: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        for fd in sockets {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        try #require(pipe(&input) == 0)
        try #require(pipe(&output) == 0)
        server = sockets[1]
        stdinWrite = input[1]
        stdoutRead = output[0]
        bridge = StreamBridge(socket: sockets[0], input: input[0], output: output[1])
        owned = [sockets[0], sockets[1], input[0], input[1], output[0], output[1]]
    }

    deinit {
        for fd in owned { close(fd) }
    }

    private func send(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    private func receive(from fd: Int32, timeout: Int32 = 2000) -> String {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, timeout) > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        return count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
    }

    private func closeOwned(_ fd: Int32) {
        close(fd)
        owned.removeAll { $0 == fd }
    }

    private func run(_ request: ControlRequest) -> (done: DispatchSemaphore, result: ResultBox) {
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        let bridge = bridge
        Thread {
            do {
                try bridge.open(request)
                bridge.pump()
            } catch {
                result.error = "\(error)"
            }
            done.signal()
        }.start()
        return (done, result)
    }

    final class ResultBox: @unchecked Sendable { var error: String? }

    private static let present = ControlRequest(cmd: .zmxPresent, target: "s1")

    @Test func theRequestGoesFirstAndFramesThenPassBothWaysUnmodified() throws {
        let running = run(Self.present)

        let request = receive(from: server)
        #expect(request.hasSuffix("\n"))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: Data(request.utf8)) == Self.present)

        send(#"{"ok":true,"result":{"id":"s1"}}"# + "\n" + #"{"kind":"ping","gen":1,"rev":0}"# + "\n", to: server)
        #expect(receive(from: stdoutRead) == #"{"kind":"ping","gen":1,"rev":0}"# + "\n",
                "the reply line is consumed, and a frame sent right behind it is not lost")

        send(#"{"kind":"ack","gen":1,"rev":0}"# + "\n", to: stdinWrite)
        #expect(receive(from: server) == #"{"kind":"ack","gen":1,"rev":0}"# + "\n")

        closeOwned(server)
        #expect(running.done.wait(timeout: .now() + 3) == .success, "the app closing ends the bridge")
        #expect(running.result.error == nil)
    }

    // pump once returned with its stdin worker still reading, and late input went to a reused descriptor
    @Test func afterTheAppClosesNothingReadsStdinAnyMore() throws {
        let running = run(Self.present)
        _ = receive(from: server)
        send(#"{"ok":true}"# + "\n", to: server)

        closeOwned(server)
        #expect(running.done.wait(timeout: .now() + 3) == .success)
        closeOwned(bridge.socket)
        var reused: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &reused) == 0)
        owned += reused
        send("late input\n", to: stdinWrite)

        #expect(receive(from: reused[0], timeout: 300) == "")
        #expect(receive(from: reused[1], timeout: 300) == "")
    }

    @Test func stdinClosingEndsTheBridgeAndTheAppSeesEndOfStream() {
        let running = run(Self.present)
        _ = receive(from: server)
        send(#"{"ok":true}"# + "\n", to: server)

        closeOwned(stdinWrite)

        #expect(running.done.wait(timeout: .now() + 3) == .success)
        #expect(receive(from: server) == "")
    }

    @Test func aRefusedOpeningRequestThrowsTheServersErrorAndWritesNothingToStdout() {
        let running = run(Self.present)
        _ = receive(from: server)

        send(#"{"ok":false,"error":"no such session"}"# + "\n", to: server)

        #expect(running.done.wait(timeout: .now() + 3) == .success)
        #expect(running.result.error?.contains("no such session") == true)
        #expect(receive(from: stdoutRead, timeout: 200) == "")
    }

    @Test func aServerThatClosesWithoutAnsweringIsAnError() {
        let running = run(Self.present)
        _ = receive(from: server)

        closeOwned(server)

        #expect(running.done.wait(timeout: .now() + 3) == .success)
        #expect(running.result.error != nil)
    }
}
