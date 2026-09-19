import Foundation
import os
import agtermCore

private let jobLogger = Logger(subsystem: "com.umputun.agterm", category: "OverlayJobs")

/// One helper's connection to a claimed remote overlay job. The origin speaks first, with the launch
/// context; the helper reports `started` and one terminal outcome, and the origin can send `cancel`.
/// The helper runs on this Mac, so its process dying closes the socket, which is what ends a job whose
/// helper went away.
@MainActor
final class OverlayJobStream {
    let job: String
    private let owner: ControlStreamOwner
    private weak var server: ControlServer?

    init(job: String, owner: ControlStreamOwner, server: ControlServer) {
        self.job = job
        self.owner = owner
        self.server = server
    }

    func send(_ frame: OverlayJobFrame) {
        guard let line = try? frame.line(), owner.send(line) else {
            jobLogger.error("closing a job helper connection that cannot take a frame")
            owner.shutdown()
            return
        }
    }

    func receive(_ line: Data) {
        guard let jobs = server?.overlayJobs else { return }
        guard let frame = try? JSONDecoder().decode(OverlayJobFrame.self, from: line) else {
            jobLogger.error("closing a job helper connection on a bad frame")
            owner.shutdown()
            return
        }
        switch frame {
        case .started: jobs.started(job)
        case .exited(let code): jobs.finish(job, .exited(code))
        case .canceled: jobs.finish(job, .canceled)
        case .launchFailed(let reason):
            jobLogger.notice("remote overlay job failed to launch: \(reason, privacy: .public)")
            jobs.finish(job, .launchFailed)
        case .context, .cancel: owner.shutdown()
        }
    }

    func shutdown() { owner.shutdown() }

    func closed() {
        server?.overlayJobs.helperGone(job)
        if server?.overlayJobStreams[job] === self { server?.overlayJobStreams[job] = nil }
    }
}

extension ControlServer {
    static let overlayJobLimits = ControlStreamOwner.Limits(maxLineBytes: PresentationCodec.maxFrameBytes,
                                                            maxPendingLines: 16, writeTimeoutSeconds: 5)

    /// Answers `session.overlay.job.run`: the request is the claim, so an ok here is the one winner of the
    /// race against the job's launch deadline.
    func claimOverlayJob(_ job: String) -> ControlResponse {
        let claimed = overlayJobs.claim(job) { [weak self] in self?.cancelJobHelper(job) }
        guard claimed != nil else { return ControlResponse(ok: false, error: "job not claimable") }
        scheduleOverlayJobExpiry(after: OverlayJobs.startWindow)
        return ControlResponse(ok: true, result: ControlResult(id: job))
    }

    /// Takes over the connection of a job whose claim was just answered ok, and sends its launch context.
    func adoptOverlayJobStream(descriptor: Int32, job: String) {
        let owner = ControlStreamOwner(descriptor: descriptor, limits: Self.overlayJobLimits)
        let stream = OverlayJobStream(job: job, owner: owner, server: self)
        overlayJobStreams[job] = stream
        owner.start(
            onLine: { [weak stream] line in
                let copy = Data(line)
                DispatchQueue.main.async { MainActor.assumeIsolated { stream?.receive(copy) } }
            },
            onClose: { [weak stream] in
                DispatchQueue.main.async { MainActor.assumeIsolated { stream?.closed() } }
            }
        )
        guard let context = overlayJobs.job(job)?.context else {
            stream.shutdown()
            return
        }
        stream.send(.context(context))
        if pendingJobCancels.remove(job) != nil { stream.send(.cancel) }
    }

    /// Reaches a claimed job's helper. A cancel that arrives before its connection is adopted is held for it.
    func cancelJobHelper(_ job: String) {
        guard let stream = overlayJobStreams[job] else {
            pendingJobCancels.insert(job)
            return
        }
        stream.send(.cancel)
    }

    /// Runs the table's expiry once `seconds` have passed, which ends whatever deadline fell in between.
    func scheduleOverlayJobExpiry(after seconds: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.1) * 1_000_000_000))
            self?.overlayJobs.expire()
        }
    }
}
