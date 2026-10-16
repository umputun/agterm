import ArgumentParser
import Dispatch
import Foundation
import agtermCore

/// The result of a `session wait`: a status in the `--until` set, the session leaving the open tree, or
/// the deadline passing first.
enum SessionWaitOutcome: Equatable {
    case matched(id: UUID, status: AgentStatus)
    case closed
    case timedOut
}

struct SessionWaitDependencies {
    let send: (ControlRequest) throws -> ControlResponse
    let sleep: (TimeInterval) -> Void
    /// Monotonic seconds, so a wall-clock change cannot stretch or cut the timeout.
    let now: () -> TimeInterval

    static func live(socketPath: String) -> SessionWaitDependencies {
        SessionWaitDependencies(
            send: { request in try SocketClient(path: socketPath).send(request).response },
            sleep: Thread.sleep(forTimeInterval:),
            now: { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
        )
    }
}

/// Ends a `session wait` at its deadline even while a socket call is blocked, which the poll loop's own
/// deadline check cannot reach: the client has no receive timeout and the app may never answer.
/// The timer runs on its own serial queue: the global queue gets no new worker once its pool is
/// exhausted, and a handler queued there can start long after the deadline.
final class SessionWaitWatchdog {
    private let timer: DispatchSourceTimer

    init(seconds: TimeInterval, fire: @escaping @Sendable () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "agtermctl.session-wait.watchdog"))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: fire)
        timer.resume()
    }

    func cancel() { timer.cancel() }
}

extension Session {
    struct Wait: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Block until a session's agent status is one of the given values.",
            discussion: """
            session wait --target ID --until completed --until blocked --timeout 600

            Returns at once when the session's current status is already in the set, otherwise on the \
            first later status event for it that is. A status set before the wait started still \
            matches, so after reusing a session wait for active first, or the previous run's completed \
            answers immediately. A completed that auto-reset cleared before the wait started is gone.

            Prints the matched status, or {"id":"…","status":"…"} with --json. Exit 0 on a match, 2 when \
            the session leaves the open tree (closed, soft-closed or its window closed), \(timeoutExitCode) \
            when --timeout passes first, 1 on any other failure.
            """)

        static let timeoutExitCode: Int32 = 124
        static let closedExitCode: Int32 = 2
        static let pollDelay: TimeInterval = 0.25

        @Option(name: .long, help: "Status to wait for (idle, active, completed, blocked); repeat for several.")
        var until: [String] = []
        @Option(name: .long, help: "Seconds to wait before exiting \(timeoutExitCode); omit to wait indefinitely.")
        var timeout: Double?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: BasicOptions

        private var statuses: Set<AgentStatus> { Set(until.compactMap(AgentStatus.init(rawValue:))) }

        func validate() throws {
            guard !until.isEmpty else { throw ValidationError("provide at least one --until status") }
            for raw in until where AgentStatus(rawValue: raw) == nil {
                throw ValidationError("invalid status: \(raw) (expected idle, active, completed or blocked)")
            }
            if let timeout, !(timeout.isFinite && timeout > 0) {
                throw ValidationError("--timeout must be a positive number of seconds")
            }
        }

        func run() throws {
            let watchdog = timeout.map { seconds in
                SessionWaitWatchdog(seconds: seconds) {
                    Self.reportTimeout()
                    Darwin.exit(Self.timeoutExitCode)
                }
            }
            defer { watchdog?.cancel() }
            switch try wait(dependencies: .live(socketPath: options.socketPath())) {
            case .matched(let id, let status):
                FileHandle.standardOutput.write(Data((try output(id: id, status: status) + "\n").utf8))
            case .closed:
                FileHandle.standardError.write(Data("session closed\n".utf8))
                throw ExitCode(Self.closedExitCode)
            case .timedOut:
                Self.reportTimeout()
                throw ExitCode(Self.timeoutExitCode)
            }
        }

        /// Anchor the event cursor, then read the current status, then replay events from the anchor, so a
        /// status set between the two reads is still seen.
        func wait(dependencies: SessionWaitDependencies) throws -> SessionWaitOutcome {
            let deadline = timeout.map { dependencies.now() + $0 }
            var stream = EventStreamState(kinds: [.status, .sessionClosed], limit: nil)
            _ = try stream.consume(dependencies.send(stream.makeRequest()))
            let (id, current) = try resolveSession(send: dependencies.send)
            if statuses.contains(current) { return .matched(id: id, status: current) }

            func pause(_ delay: TimeInterval) {
                guard let deadline else { return dependencies.sleep(delay) }
                dependencies.sleep(min(delay, max(0, deadline - dependencies.now())))
            }

            while true {
                if let deadline, dependencies.now() >= deadline { return .timedOut }
                let response: ControlResponse
                do {
                    response = try dependencies.send(stream.makeRequest())
                } catch {
                    guard let delay = stream.retryDelay(after: error) else { throw error }
                    pause(delay)
                    continue
                }
                let events = try stream.consume(response)
                for event in events where event.session.flatMap(UUID.init(uuidString:)) == id {
                    if event.kind == .sessionClosed { return .closed }
                    if let status = event.payload.status.flatMap(AgentStatus.init(rawValue:)), statuses.contains(status) {
                        return .matched(id: id, status: status)
                    }
                }
                if events.isEmpty { pause(Self.pollDelay) }
            }
        }

        /// Resolve `--target` the way the server does, across every open window's tree: `active` is the
        /// frontmost window's selected session, an id or unique prefix matches in any open window. An
        /// absent status reads as idle.
        func resolveSession(send: (ControlRequest) throws -> ControlResponse) throws -> (UUID, AgentStatus) {
            let list = try send(ControlRequest(cmd: .windowList))
            guard list.ok, let windows = list.result?.windows else {
                throw SocketClientError(list.error ?? "window.list response missing windows")
            }
            var sessions: [ControlSessionNode] = []
            var active: UUID?
            for window in windows where window.open {
                var args = ControlArgs()
                args.window = window.id
                let reply = try send(ControlRequest(cmd: .tree, args: args))
                guard reply.ok, let tree = reply.result?.tree else {
                    throw SocketClientError(reply.error ?? "tree response missing tree")
                }
                let nodes = tree.workspaces.flatMap(\.sessions)
                sessions += nodes
                if window.active { active = nodes.first(where: \.active).flatMap { UUID(uuidString: $0.id) } }
            }
            let resolution = ControlResolve.resolve(target.target, candidates: sessions.compactMap { UUID(uuidString: $0.id) },
                                                    active: active)
            guard case .resolved(let id) = resolution,
                  let node = sessions.first(where: { UUID(uuidString: $0.id) == id }) else {
                throw SocketClientError(ControlResolve.errorMessage(noun: "session", target: target.target, resolution: resolution))
            }
            return (id, node.status.flatMap(AgentStatus.init(rawValue:)) ?? .idle)
        }

        func output(id: UUID, status: AgentStatus) throws -> String {
            guard options.json else { return status.rawValue }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return String(decoding: try encoder.encode(["id": id.uuidString, "status": status.rawValue]), as: UTF8.self)
        }

        private static func reportTimeout() {
            FileHandle.standardError.write(Data("timed out\n".utf8))
        }
    }
}
