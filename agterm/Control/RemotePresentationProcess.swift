import Foundation
import os
import agtermCore

private let processLogger = Logger(subsystem: "com.umputun.agterm", category: "RemotePresentation")

/// Runs the presentation bridge as a long-lived child process, the ssh to an origin in production.
@MainActor
final class RemotePresentationProcess: RemotePresentationTransport {
    func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
              onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
        ProcessLink(argv: argv, onLine: onLine, onClose: onClose)
    }
}

/// One child and its three pipes. Stdout is read a line at a time on a thread of its own and handed to the
/// main actor; stdin takes the client's frames; stderr goes to the log, where an ssh failure is worth reading.
@MainActor
private final class ProcessLink: RemotePresentationLink {
    private let process = Process()
    private let input = Pipe()
    /// Both readers poll its read end beside their own pipe and neither drains it, so one byte ends both.
    /// Closing a descriptor another thread is blocked reading is not an option: it does not reliably wake
    /// the reader and the number can be reused under it.
    private let wake = Pipe()
    private var closed = false
    private var exitReason: String?
    private var outputEnded = false
    private var readersEnded = false
    private let onClose: @MainActor (String) -> Void

    init(argv: [String], onLine: @escaping @MainActor (Data) -> Void, onClose: @escaping @MainActor (String) -> Void) {
        self.onClose = onClose
        let output = Pipe()
        let errors = Pipe()
        // env resolves `ssh` through PATH, so a user who put their own ahead of /usr/bin keeps it
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // a frame is a few hundred bytes and the pipe holds 64 KiB, so a write that would block means the
        // child stopped reading: fail it then, never stall the main actor on it
        let writeEnd = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(writeEnd, F_SETFL, fcntl(writeEnd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)

        process.terminationHandler = { [weak self] finished in
            let reason = "exit \(finished.terminationStatus)"
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(reason) } }
        }
        do {
            try process.run()
        } catch {
            let reason = "could not run \(argv.first ?? "the bridge"): \(error.localizedDescription)"
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.finish(reason) } }
            return
        }
        // the reader stops reading past this many undelivered lines, so a busy main actor backs the child
        // up into its own pipe and never into this app's memory
        let inbound = DispatchSemaphore(value: 64)
        Self.readLines(from: output.fileHandleForReading, wake: wake, deliver: { line in
            inbound.wait()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onLine(line) }
                inbound.signal()
            }
        }, ended: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.outputDidEnd() } }
        })
        Self.readLines(from: errors.fileHandleForReading, wake: wake, deliver: { line in
            processLogger.notice("presentation bridge: \(String(decoding: line, as: UTF8.self), privacy: .public)")
        }, ended: {})
    }

    func send(_ line: Data) {
        guard !closed else { return }
        let fd = input.fileHandleForWriting.fileDescriptor
        let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written != line.count else { return }
        processLogger.notice("presentation bridge stopped taking input; ending it")
        stop()
    }

    func stop() {
        // the client releases a link right after stopping it, so no later callback can end the readers
        endReaders()
        guard process.isRunning else { return }
        process.terminate()
    }

    /// The close waits for stdout's end, queued behind the last line, so the frames a child wrote just
    /// before exiting are delivered first. A descendant can hold the pipe open past the exit, hence the
    /// deadline.
    private func exited(_ reason: String) {
        exitReason = reason
        if outputEnded { finish(reason); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.finish(reason) }
        }
    }

    private func outputDidEnd() {
        outputEnded = true
        if let exitReason { finish(exitReason); return }
        stop() // nothing more can be read, so the child is of no use
    }

    /// A descendant of the child can hold its pipes open for good, so the readers never wait on their end.
    private func endReaders() {
        guard !readersEnded else { return }
        readersEnded = true
        try? wake.fileHandleForWriting.write(contentsOf: Data([0]))
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
        endReaders()
        onClose(reason)
    }

    /// Reads `handle` on a thread of its own, one line at a time, until its end or a byte on `wake`, then
    /// closes it and calls `ended`. A line over the frame limit ends the read undelivered, which the child
    /// sees as a closed pipe.
    private nonisolated static func readLines(from handle: FileHandle, wake: Pipe,
                                              deliver: @escaping @Sendable (Data) -> Void,
                                              ended: @escaping @Sendable () -> Void) {
        let thread = Thread {
            let fd = handle.fileDescriptor
            var polled = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                          pollfd(fd: wake.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            reading: while true {
                let ready = poll(&polled, 2, -1)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0, polled[1].revents == 0 else { break }
                let count = read(fd, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    guard newline - buffer.startIndex <= PresentationCodec.maxFrameBytes else { break reading }
                    deliver(Data(buffer[buffer.startIndex..<newline]))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                guard buffer.count <= PresentationCodec.maxFrameBytes else { break }
            }
            try? handle.close()
            ended()
        }
        thread.name = "com.umputun.agterm.presentation.read"
        thread.start()
    }
}
