import Foundation

private let jobLog = CoreLog(category: "OverlayJobs")

/// OverlayJobStreamHost keeps the connections of claimed remote overlay jobs: the Mac's control server and
/// agterm-server. Claiming, adoption and cancel are shared through this protocol's extension.
@MainActor
public protocol OverlayJobStreamHost: AnyObject {
    var overlayJobs: OverlayJobs { get }
    var overlayJobStreams: [String: OverlayJobStream] { get set }
    /// pendingJobCancels are cancels that arrived before their job's connection was adopted.
    var pendingJobCancels: Set<String> { get set }
}

/// One helper's connection to a claimed remote overlay job. The origin speaks first, with the launch
/// context; the helper reports `started` and one terminal outcome, and the origin can send `cancel`.
/// The helper runs on the presenting Mac, so its process dying closes the socket, which is what ends a job whose
/// helper went away.
@MainActor
public final class OverlayJobStream {
    public static let limits = ControlStreamOwner.Limits(maxLineBytes: PresentationCodec.maxFrameBytes,
                                                         maxPendingLines: 16, writeTimeoutSeconds: 5)

    public let job: String
    private let owner: ControlStreamOwner
    private weak var host: (any OverlayJobStreamHost)?

    init(job: String, owner: ControlStreamOwner, host: any OverlayJobStreamHost) {
        self.job = job
        self.owner = owner
        self.host = host
    }

    func send(_ frame: OverlayJobFrame) {
        guard let line = try? frame.line(), owner.send(line) else {
            jobLog.error("closing a job helper connection that cannot take a frame")
            owner.shutdown()
            return
        }
    }

    func receive(_ line: Data) {
        guard let jobs = host?.overlayJobs else { return }
        guard let frame = try? JSONDecoder().decode(OverlayJobFrame.self, from: line) else {
            jobLog.error("closing a job helper connection on a bad frame")
            owner.shutdown()
            return
        }
        switch frame {
        case .started: jobs.started(job)
        case .exited(let code): jobs.finish(job, .exited(code))
        case .canceled: jobs.finish(job, .canceled)
        case .launchFailed(let reason):
            jobLog.notice("remote overlay job failed to launch: \(reason)")
            jobs.finish(job, .launchFailed)
        case .context, .cancel: owner.shutdown()
        }
    }

    public func shutdown() { owner.shutdown() }

    func closed() {
        host?.overlayJobs.helperGone(job)
        if host?.overlayJobStreams[job] === self { host?.overlayJobStreams[job] = nil }
    }
}

extension OverlayJobStreamHost {
    /// claimJobStream answers `session.overlay.job.run`: the request is the claim, so an ok here is the one winner
    /// of the race against the job's launch deadline.
    public func claimJobStream(_ job: String, token: String? = nil) -> ControlResponse {
        let claimed = overlayJobs.claim(job, token: token) { [weak self] in self?.cancelJobHelper(job) }
        guard claimed != nil else { return ControlResponse(ok: false, error: "job not claimable") }
        scheduleOverlayJobExpiry(after: OverlayJobs.startWindow)
        return ControlResponse(ok: true, result: ControlResult(id: job))
    }

    /// adoptOverlayJobStream takes over the connection of a job whose claim was just answered ok, and sends its
    /// launch context.
    public func adoptOverlayJobStream(descriptor: Int32, job: String) {
        let owner = ControlStreamOwner(descriptor: descriptor, limits: OverlayJobStream.limits)
        let stream = OverlayJobStream(job: job, owner: owner, host: self)
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
        // a job that ended between its claim and this adoption must not launch, its queued cancel gone with it
        guard let claimed = overlayJobs.job(job), case .claimed = claimed.state else {
            stream.shutdown()
            return
        }
        stream.send(.context(claimed.context))
        if pendingJobCancels.remove(job) != nil { stream.send(.cancel) }
    }

    /// cancelJobHelper reaches a claimed job's helper. A cancel that arrives before its connection is adopted is held
    /// for it.
    public func cancelJobHelper(_ job: String) {
        guard let stream = overlayJobStreams[job] else {
            pendingJobCancels.insert(job)
            return
        }
        stream.send(.cancel)
    }

    /// scheduleOverlayJobExpiry runs the table's expiry once `seconds` have passed, which ends whatever deadline fell
    /// in between.
    public func scheduleOverlayJobExpiry(after seconds: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.1) * 1_000_000_000))
            self?.overlayJobs.expire()
        }
    }
}
