import Foundation

/// OverlayJobOutcome is how a remote overlay job ended. `unknown` means nobody can say: the helper never
/// reported starting, or went away without a terminal report. It never means the program exited.
public enum OverlayJobOutcome: Equatable, Sendable {
    case exited(Int)
    case canceled
    case launchFailed
    case unknown

    /// The name a caller reads for an outcome with no exit code.
    public var failureName: String? {
        switch self {
        case .exited: return nil
        case .canceled: return "canceled"
        case .launchFailed: return "launch-failed"
        case .unknown: return "unknown"
        }
    }
}

/// OverlayJobState is where a remote job is between its open and its outcome.
public enum OverlayJobState: Equatable, Sendable {
    /// Handed to the presenter, waiting for a helper to claim it before the launch deadline.
    case unclaimed(deadline: Date)
    /// A helper holds it and has the launch context, waiting for `started` before the deadline.
    case claimed(deadline: Date)
    case running
    case finished(OverlayJobOutcome)
}

/// OverlayJob is one overlay the origin handed to a presenter to show, run by a helper on the origin.
public struct OverlayJob: Equatable, Sendable {
    public let id: String
    public let session: UUID
    /// The pane the overlay covers, nil for the session-wide slot.
    public let pane: OverlayPane?
    /// The presenter generation the job was handed to.
    public let owner: Int
    public let context: OverlayLaunchContext
    public internal(set) var state: OverlayJobState
}

/// OverlayJobs is the origin's private table of remote overlay jobs. It settles the one race that matters,
/// a claim against its launch deadline, with one winner, and keeps each job's first terminal outcome so a
/// late report can change nothing. Nothing here is a public command.
@MainActor
public final class OverlayJobs {
    /// Open to claim: an ssh connect and authentication on the viewer, with room to spare.
    public static let launchWindow: TimeInterval = 30
    /// Claim to `started`: the helper spawning a local child.
    public static let startWindow: TimeInterval = 10

    /// Called once per job with its first terminal outcome.
    public var onFinished: ((OverlayJob) -> Void)?
    private let now: () -> Date
    private var jobs: [String: OverlayJob] = [:]
    /// How to reach a claimed job's helper. Cleared with the job's outcome.
    private var cancelHooks: [String: () -> Void] = [:]

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func job(_ id: String) -> OverlayJob? { jobs[id] }

    /// Registers a job handed to a presenter. Returns its id.
    @discardableResult
    public func register(session: UUID, pane: OverlayPane?, owner: Int, context: OverlayLaunchContext) -> String {
        let id = UUID().uuidString
        jobs[id] = OverlayJob(id: id, session: session, pane: pane, owner: owner, context: context,
                              state: .unclaimed(deadline: now().addingTimeInterval(Self.launchWindow)))
        return id
    }

    /// A helper claims the job. Single use: the context is handed out once, only to a claim that beats the
    /// launch deadline. `cancel` is how the table reaches that helper later.
    public func claim(_ id: String, cancel: @escaping () -> Void) -> OverlayLaunchContext? {
        guard var job = jobs[id], case .unclaimed(let deadline) = job.state, now() < deadline else {
            expire()
            return nil
        }
        job.state = .claimed(deadline: now().addingTimeInterval(Self.startWindow))
        jobs[id] = job
        cancelHooks[id] = cancel
        return job.context
    }

    /// The helper launched the program. Once running, no timeout can end the job; a start reported after the
    /// claim's deadline is too late and ends it `unknown`, as the expiry would have.
    public func started(_ id: String) {
        guard var job = jobs[id], case .claimed(let deadline) = job.state else { return }
        guard now() < deadline else {
            finish(id, .unknown)
            return
        }
        job.state = .running
        jobs[id] = job
    }

    /// Records a terminal outcome. Only the first counts; false for a later one or an unknown job.
    @discardableResult
    public func finish(_ id: String, _ outcome: OverlayJobOutcome) -> Bool {
        guard var job = jobs[id] else { return false }
        if case .finished = job.state { return false }
        job.state = .finished(outcome)
        jobs[id] = job
        cancelHooks[id] = nil
        onFinished?(job)
        return true
    }

    /// The helper's connection ended. Without a terminal report first, nobody can say how the job ended.
    public func helperGone(_ id: String) {
        finish(id, .unknown)
    }

    /// Cancels a job. An unclaimed one ends `canceled` here and a late claim is refused; a claimed or
    /// running one is cancelled through its helper, which reports the outcome. False when it is already over.
    @discardableResult
    public func cancel(_ id: String) -> Bool {
        guard let job = jobs[id] else { return false }
        switch job.state {
        case .unclaimed:
            finish(id, .canceled)
        case .claimed, .running:
            cancelHooks[id]?()
        case .finished:
            return false
        }
        return true
    }

    /// Ends every job whose deadline passed: an unclaimed one as `launch-failed`, a claimed one that never
    /// reported starting as `unknown`. The owner calls this at each deadline it scheduled.
    public func expire() {
        let current = now()
        for (id, job) in jobs {
            switch job.state {
            case .unclaimed(let deadline) where current >= deadline: finish(id, .launchFailed)
            case .claimed(let deadline) where current >= deadline: finish(id, .unknown)
            default: break
            }
        }
    }
}

/// OverlayJobFrame is one line on a helper's connection, after the ordinary reply to its claim.
public enum OverlayJobFrame: Equatable, Sendable {
    /// Origin to helper, first: what to run.
    case context(OverlayLaunchContext)
    /// Origin to helper: stop the program.
    case cancel
    /// Helper to origin: the program is running.
    case started
    case exited(Int)
    case canceled
    case launchFailed(String)
}

extension OverlayJobFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, context, code, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "context": self = .context(try container.decode(OverlayLaunchContext.self, forKey: .context))
        case "cancel": self = .cancel
        case "started": self = .started
        case "exited": self = .exited(try container.decode(Int.self, forKey: .code))
        case "canceled": self = .canceled
        case "launch-failed": self = .launchFailed(try container.decode(String.self, forKey: .reason))
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .context(let context):
            try container.encode("context", forKey: .kind)
            try container.encode(context, forKey: .context)
        case .cancel: try container.encode("cancel", forKey: .kind)
        case .started: try container.encode("started", forKey: .kind)
        case .exited(let code):
            try container.encode("exited", forKey: .kind)
            try container.encode(code, forKey: .code)
        case .canceled: try container.encode("canceled", forKey: .kind)
        case .launchFailed(let reason):
            try container.encode("launch-failed", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    /// One newline-terminated line.
    public func line() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
