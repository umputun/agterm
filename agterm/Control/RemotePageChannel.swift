import Foundation
import os
import agtermCore

private let channelLogger = Logger(subsystem: "com.umputun.agterm", category: "RemotePage")

/// RemotePageHelper is a started helper carrying one page channel: this Mac's end of the channel, whose
/// descriptor passes to the channel, and the process behind it.
@MainActor
protocol RemotePageHelper: AnyObject {
    var descriptor: Int32 { get }
    func terminate()
}

/// RemotePageLauncher starts the helper for a page channel. `onExit` runs once when the helper ends by itself.
@MainActor
protocol RemotePageLauncher {
    func launch(_ argv: [String], onExit: @escaping @MainActor () -> Void) throws -> RemotePageHelper
}

/// RemotePageProcess runs the helper as a child whose stdin and stdout are one end of a socket pair, so the
/// channel gets one descriptor that a stream owner reads and writes off the main actor.
@MainActor
struct RemotePageProcess: RemotePageLauncher {
    func launch(_ argv: [String], onExit: @escaping @MainActor () -> Void) throws -> RemotePageHelper {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        // the child must not inherit this Mac's end, or the channel would not see EOF when the child exits
        _ = fcntl(pair[0], F_SETFD, FD_CLOEXEC)
        let process = Process()
        let errors = Pipe()
        // env resolves `ssh` through PATH, as the presentation bridge does
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        let child = FileHandle(fileDescriptor: pair[1], closeOnDealloc: false)
        process.standardInput = child
        process.standardOutput = child
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            channelLogger.notice("page helper: \(String(decoding: data, as: UTF8.self), privacy: .public)")
        }
        process.terminationHandler = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { onExit() } } }
        do {
            try process.run()
        } catch {
            close(pair[0])
            close(pair[1])
            errors.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        close(pair[1])
        return ProcessHelper(process: process, descriptor: pair[0])
    }

    private final class ProcessHelper: RemotePageHelper {
        let descriptor: Int32
        private let process: Process

        init(process: Process, descriptor: Int32) {
            self.process = process
            self.descriptor = descriptor
        }

        func terminate() {
            guard process.isRunning else { return }
            process.terminate()
        }
    }
}

/// RemotePagePermits bounds the inbound lines a page channel holds: the reader takes one per line and stops
/// at the bound, a line gives its permit back once handled, and a file chunk only once the page consumed it.
final class RemotePagePermits: @unchecked Sendable {
    private let state = NSCondition()
    private var free: Int
    private var closed = false

    init(_ count: Int) { free = count }

    /// take waits for a permit; false once closed, when nothing more is delivered.
    func take() -> Bool {
        state.lock()
        defer { state.unlock() }
        while !closed, free == 0 { state.wait() }
        guard !closed else { return false }
        free -= 1
        return true
    }

    func give() {
        state.lock()
        defer { state.unlock() }
        free += 1
        state.broadcast()
    }

    func close() {
        state.lock()
        defer { state.unlock() }
        closed = true
        state.broadcast()
    }
}

/// RemotePageChannel is this Mac's end of a page's channel to the Mac that opened it: page files are fetched
/// and bridge requests relayed through it. At most `ControlServer.pageServeResourceLimit` resource requests are
/// in flight, the rest wait here; a request's slot is freed only by its terminal frame, which a cancel also
/// produces. Bridge calls have slots of their own.
@MainActor
final class RemotePageChannel {
    enum Failure: Error, LocalizedError {
        case closed
        case tooLarge
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .closed: return "page channel closed"
            case .tooLarge: return "request too large for the page channel"
            case .refused(let reason): return reason
            }
        }
    }

    static let inboundLimit = 64
    static let limits = ControlStreamOwner.Limits(maxLineBytes: PageServeCodec.maxFrameBytes, maxPendingLines: 32,
                                                  writeTimeoutSeconds: 5)

    private final class Transfer {
        let revision: @MainActor () -> Bool
        var head: CheckedContinuation<String, Error>?
        var buffer: [Data] = []
        var pull: CheckedContinuation<Data?, Error>?
        var terminal: Result<Void, Error>?
        var cancelled = false

        init(revision: @escaping @MainActor () -> Bool) { self.revision = revision }
    }

    private enum Kind: Sendable { case resource, bridge }

    private struct Slots {
        let limit: Int
        var used = 0
        var waiting: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    }

    /// onClose runs once when the channel ends, whichever side ended it.
    var onClose: (@MainActor () -> Void)?
    private var helper: RemotePageHelper?
    private var owner: ControlStreamOwner?
    private let permits = RemotePagePermits(RemotePageChannel.inboundLimit)
    private var nextID = 1
    private var transfers: [Int: Transfer] = [:]
    private var bridges: [Int: CheckedContinuation<String, Error>] = [:]
    private var slots: [Kind: Slots] = [.resource: Slots(limit: ControlServer.pageServeResourceLimit),
                                        .bridge: Slots(limit: ControlServer.pageServeBridgeLimit)]
    private var closed = false

    /// start launches the helper and starts reading; a helper that cannot start closes the channel at once.
    func start(_ argv: [String], launcher: RemotePageLauncher) {
        let helper: RemotePageHelper
        do {
            helper = try launcher.launch(argv) { [weak self] in self?.close("helper exited") }
        } catch {
            close("helper could not start: \(error.localizedDescription)")
            return
        }
        self.helper = helper
        let owner = ControlStreamOwner(descriptor: helper.descriptor, limits: Self.limits)
        self.owner = owner
        let permits = permits
        owner.start(
            onLine: { [weak self] line in
                guard permits.take() else { return }
                let copy = Data(line)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return permits.give() }
                        self.receive(copy)
                    }
                }
            },
            onClose: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.close("channel ended") } }
            })
    }

    /// fetch asks for the file at `path` on the origin. `current` says whether the page still shows the load
    /// that asked, and an answer for one it no longer shows is dropped. The returned chunks are pulled one at
    /// a time, so a chunk's inbound permit is held until the page takes it.
    func fetch(_ path: String, current: @escaping @MainActor () -> Bool) async throws -> HtmlPageResource {
        let id = allocate()
        try await admit(id, into: .resource)
        guard !Task.isCancelled else {
            release(.resource)
            throw CancellationError()
        }
        do {
            try send(.resource(id: id, path: path))
        } catch {
            if !closed { release(.resource) }
            throw error
        }
        let transfer = Transfer(revision: current)
        transfers[id] = transfer
        let mimeType: String
        do {
            mimeType = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<String, Error>) in transfer.head = waiter }
            } onCancel: {
                DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.cancel(id) } }
            }
        } catch {
            // a cancelled transfer stays until the origin's terminal frame frees its slot; any other ends here
            if transfers[id] === transfer, transfer.terminal != nil || !transfer.cancelled { transfers[id] = nil }
            throw error
        }
        let handle = TransferHandle(id: id, channel: self)
        let chunks = AsyncThrowingStream<Data, Error>(unfolding: { [weak self] in
            guard let self else { throw Failure.closed }
            return try await self.pull(handle.id)
        })
        return HtmlPageResource(mimeType: mimeType, chunks: chunks)
    }

    // a resource dropped before its last chunk was read, by a page that stopped the request before reading or
    // part way, cancels its transfer, or what it buffered would hold the reader's permits for good
    private final class TransferHandle: Sendable {
        let id: Int
        private weak let channel: RemotePageChannel?

        init(id: Int, channel: RemotePageChannel) {
            self.id = id
            self.channel = channel
        }

        deinit {
            let id = id, channel = channel
            DispatchQueue.main.async { MainActor.assumeIsolated { channel?.cancel(id) } }
        }
    }

    /// bridge relays a page's request and returns the origin's reply as the JSON text it sent.
    func bridge(_ request: Data) async throws -> String {
        let id = allocate()
        try await admit(id, into: .bridge)
        do {
            try send(.bridge(id: id, request: String(decoding: request, as: UTF8.self)))
        } catch {
            if !closed { release(.bridge) }
            throw error
        }
        return try await withCheckedThrowingContinuation { bridges[id] = $0 }
    }

    /// close ends the channel once: the helper is stopped, every waiter fails and every held permit is freed.
    func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        channelLogger.notice("page channel closed: \(reason, privacy: .public)")
        permits.close()
        owner?.shutdown()
        helper?.terminate()
        for (_, transfer) in transfers { finish(transfer, with: .failure(Failure.closed)) }
        transfers.removeAll()
        for (_, waiter) in bridges { waiter.resume(throwing: Failure.closed) }
        bridges.removeAll()
        for kind in [Kind.resource, .bridge] {
            for entry in slots[kind]?.waiting ?? [] { entry.continuation.resume(throwing: Failure.closed) }
            slots[kind]?.waiting.removeAll()
        }
        onClose?()
        onClose = nil
    }

    private func allocate() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func admit(_ id: Int, into kind: Kind) async throws {
        guard !closed, var entry = slots[kind] else { throw Failure.closed }
        if entry.used < entry.limit {
            entry.used += 1
            slots[kind] = entry
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                slots[kind]?.waiting.append((id, waiter))
            }
        } onCancel: {
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.leaveQueue(id, kind) } }
        }
    }

    // a request cancelled while it waits here was never sent, so it leaves without a trace on the origin
    private func leaveQueue(_ id: Int, _ kind: Kind) {
        guard let index = slots[kind]?.waiting.firstIndex(where: { $0.id == id }),
              let entry = slots[kind]?.waiting.remove(at: index) else { return }
        entry.continuation.resume(throwing: CancellationError())
    }

    // a freed slot passes straight to the first request waiting for one
    private func release(_ kind: Kind) {
        guard let next = slots[kind]?.waiting.first else {
            slots[kind]?.used -= 1
            return
        }
        slots[kind]?.waiting.removeFirst()
        next.continuation.resume()
    }

    private func pull(_ id: Int) async throws -> Data? {
        guard let transfer = transfers[id] else { throw Failure.closed }
        if transfer.cancelled { throw CancellationError() }
        guard transfer.revision() else {
            cancel(id)
            throw CancellationError()
        }
        if !transfer.buffer.isEmpty {
            permits.give()
            return transfer.buffer.removeFirst()
        }
        if let terminal = transfer.terminal {
            transfers[id] = nil
            try terminal.get()
            return nil
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Data?, Error>) in transfer.pull = waiter }
        } onCancel: {
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.cancel(id) } }
        }
    }

    // a cancelled transfer keeps its slot until the origin's terminal frame; what it buffered is dropped now,
    // freeing those permits so the reader can reach that frame
    private func cancel(_ id: Int) {
        guard let transfer = transfers[id], !transfer.cancelled else { return }
        transfer.cancelled = true
        if transfer.terminal == nil { try? send(.cancel(id: id)) }
        drop(transfer.buffer)
        transfer.buffer.removeAll()
        transfer.head?.resume(throwing: CancellationError())
        transfer.head = nil
        transfer.pull?.resume(throwing: CancellationError())
        transfer.pull = nil
        if transfer.terminal != nil { transfers[id] = nil }
    }

    private func receive(_ line: Data) {
        guard !closed else { return permits.give() }
        guard let frame = try? PageServeCodec.decode(line) else {
            permits.give()
            return close("a malformed frame")
        }
        switch frame {
        case .head(let id, let mimeType):
            defer { permits.give() }
            guard let transfer = live(id) else { return }
            transfer.head?.resume(returning: mimeType)
            transfer.head = nil
        case .chunk(let id, let data):
            guard let transfer = live(id) else { return permits.give() }
            if let waiter = transfer.pull {
                transfer.pull = nil
                permits.give()
                waiter.resume(returning: data)
            } else {
                transfer.buffer.append(data)
            }
        case .end(let id):
            defer { permits.give() }
            end(id, .success(()))
        case .failure(let id, let error):
            defer { permits.give() }
            if let waiter = bridges.removeValue(forKey: id) {
                release(.bridge)
                return waiter.resume(throwing: Failure.refused(error))
            }
            end(id, .failure(Failure.refused(error)))
        case .reply(let id, let response):
            defer { permits.give() }
            guard let waiter = bridges.removeValue(forKey: id) else { return }
            release(.bridge)
            waiter.resume(returning: response)
        case .resource, .cancel, .bridge:
            permits.give()
            close("a frame only this Mac sends")
        }
    }

    // a transfer whose answer the page still wants; one for a load the page left is cancelled here
    private func live(_ id: Int) -> Transfer? {
        guard let transfer = transfers[id], !transfer.cancelled else { return nil }
        guard transfer.revision() else {
            cancel(id)
            return nil
        }
        return transfer
    }

    private func end(_ id: Int, _ result: Result<Void, Error>) {
        guard let transfer = transfers[id], transfer.terminal == nil else { return }
        release(.resource)
        if transfer.cancelled {
            transfers[id] = nil
            return
        }
        finish(transfer, with: result)
    }

    private func finish(_ transfer: Transfer, with result: Result<Void, Error>) {
        transfer.terminal = result
        if let head = transfer.head {
            transfer.head = nil
            switch result {
            case .success: head.resume(throwing: Failure.refused("empty answer"))
            case .failure(let error): head.resume(throwing: error)
            }
        }
        if closed {
            drop(transfer.buffer)
            transfer.buffer.removeAll()
        }
        guard let waiter = transfer.pull, transfer.buffer.isEmpty else { return }
        transfer.pull = nil
        switch result {
        case .success: waiter.resume(returning: nil)
        case .failure(let error): waiter.resume(throwing: error)
        }
    }

    private func drop(_ chunks: [Data]) {
        for _ in chunks { permits.give() }
    }

    // a frame over the codec's cap fails that one call; the channel itself stays up
    private func send(_ frame: PageServeFrame) throws {
        guard !closed, let owner else { throw Failure.closed }
        guard let line = try? PageServeCodec.encode(frame) else { throw Failure.tooLarge }
        guard owner.send(line) else {
            close("the channel stopped taking requests")
            throw Failure.closed
        }
    }
}
