import Foundation

/// A child process's stdout and stderr, each drained while the child runs so a full pipe cannot block
/// its exit. The read ends belong to their `PipeReader` from the start; the parent's write ends are
/// released by `didLaunch` or `cancel`, whichever comes first.
final class ProcessOutputCapture {
    struct Output {
        let stdout: String
        let stderr: String
    }

    struct SetupError: LocalizedError {
        let errorDescription: String?
    }

    private var writeFDs: [Int32]
    private let stdoutReader: PipeReader
    private let stderrReader: PipeReader

    init(attachingTo process: Process) throws {
        var fds: [Int32] = []
        func pipePair() throws -> (read: Int32, write: Int32) {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else { throw ProcessOutputCapture.setupError("pipe", unwinding: fds) }
            fds += pair
            // libghostty spawns surface commands from its io thread with plain inheritance, and a write end
            // carried into a long-lived surface child holds our EOF back for that child's lifetime
            for fd in pair where fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 {
                throw ProcessOutputCapture.setupError("FD_CLOEXEC", unwinding: fds)
            }
            return (pair[0], pair[1])
        }
        let out = try pipePair()
        let err = try pipePair()
        writeFDs = [out.write, err.write]
        stdoutReader = PipeReader(fileDescriptor: out.read)
        stderrReader = PipeReader(fileDescriptor: err.read)
        process.standardOutput = FileHandle(fileDescriptor: out.write, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: err.write, closeOnDealloc: false)
    }

    /// Releases the parent's write ends once the child holds its own copies; EOF cannot arrive until then.
    func didLaunch() {
        closeWriteEnds()
    }

    /// Abandons both streams: the launch failed, or the child was killed and its output is unwanted.
    func cancel() {
        stdoutReader.cancel()
        stderrReader.cancel()
        closeWriteEnds()
    }

    /// Both streams through EOF, or nil when either missed `deadline` or failed. A miss cancels both, so an
    /// inherited write end costs neither a parked thread nor the read descriptor.
    func collect(until deadline: DispatchTime) -> Output? {
        guard let stdout = stdoutReader.wait(until: deadline), let stderr = stderrReader.wait(until: deadline) else {
            cancel()
            return nil
        }
        return Output(stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }

    private func closeWriteEnds() {
        for fd in writeFDs { close(fd) }
        writeFDs = []
    }

    private static func setupError(_ step: String, unwinding fds: [Int32]) -> SetupError {
        let message = String(cString: strerror(errno))
        for fd in fds { close(fd) }
        return SetupError(errorDescription: "\(step): \(message)")
    }
}

/// One pipe read end drained through a `DispatchIO` channel, which owns the descriptor and alone closes
/// it. Cancelling interrupts a read the peer still holds open, where a blocking read would park a thread
/// for that peer's lifetime.
final class PipeReader: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private let channel: DispatchIO
    // written only by the read handler before `finished` is signalled, and read only after a successful wait
    private var data = Data()
    private var failure: Int32 = 0

    init(fileDescriptor fd: Int32) {
        let queue = DispatchQueue(label: "com.umputun.agterm.pipe-reader")
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue,
                                 cleanupHandler: { @Sendable _ in close(fd) })
        self.channel = channel
        channel.read(offset: 0, length: Int.max, queue: queue) { @Sendable [self] done, chunk, error in
            if let chunk, !chunk.isEmpty { data.append(contentsOf: chunk) }
            guard done else { return }
            failure = error
            channel.close()
            finished.signal()
        }
    }

    /// Everything read through EOF, or nil when `deadline` passed first or the read failed.
    func wait(until deadline: DispatchTime) -> Data? {
        guard finished.wait(timeout: deadline) == .success else { return nil }
        finished.signal()
        return failure == 0 ? data : nil
    }

    func cancel() {
        channel.close(flags: .stop)
    }
}
