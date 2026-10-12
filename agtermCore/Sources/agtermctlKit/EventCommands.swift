import ArgumentParser
import Foundation
import agtermCore

struct EventStreamError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct EventStreamDependencies {
    let send: (ControlRequest) throws -> ControlResponse
    let sleep: (TimeInterval) -> Void
    let writeLine: (String) throws -> Void

    static func live(socketPath: String) -> EventStreamDependencies {
        EventStreamDependencies(
            send: { request in try SocketClient(path: socketPath).send(request).response },
            sleep: Thread.sleep(forTimeInterval:),
            writeLine: { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
        )
    }
}

struct EventStreamState {
    static let firstRetryDelay: TimeInterval = 0.25
    static let maxRetryDelay: TimeInterval = 4
    /// Seconds of consecutive refused connects before the stream gives up, so it never waits forever on an
    /// app that is gone.
    static let retryBudget: TimeInterval = 30

    private(set) var cursor: ControlEventCursor?
    let kinds: Set<ControlEventKind>?
    let limit: Int?
    private var nextRetryDelay = firstRetryDelay
    private var retriedFor: TimeInterval = 0

    init(cursor: ControlEventCursor? = nil, kinds: Set<ControlEventKind>?, limit: Int?) {
        self.cursor = cursor
        self.kinds = kinds
        self.limit = limit
    }

    func makeRequest() -> ControlRequest {
        let rawKinds = kinds.map { selected in
            ControlEventKind.allCases.filter(selected.contains).map(\.rawValue)
        }
        let args = ControlArgs(after: cursor.map { String($0.after) }, run: cursor?.run.uuidString,
                               kinds: rawKinds, limit: limit)
        if cursor == nil, rawKinds == nil, limit == nil { return ControlRequest(cmd: .eventsRead) }
        return ControlRequest(cmd: .eventsRead, args: args)
    }

    /// The wait before reading again after `error`, nil when the error ends the stream. Only a refused
    /// connect is retried: on Darwin a live server whose backlog is full refuses, while a missing
    /// socket means the app quit, and a relaunch is a new run the cursor cannot resume. Without a cursor
    /// there is nothing to keep, so the first read still fails fast.
    mutating func retryDelay(after error: Error) -> TimeInterval? {
        guard cursor != nil, let failure = (error as? SocketClientError)?.connectErrno,
              failure == ECONNREFUSED, retriedFor < Self.retryBudget else { return nil }
        let delay = nextRetryDelay
        retriedFor += delay
        nextRetryDelay = min(delay * 2, Self.maxRetryDelay)
        return delay
    }

    mutating func consume(_ response: ControlResponse) throws -> [ControlEvent] {
        nextRetryDelay = Self.firstRetryDelay
        retriedFor = 0
        guard response.ok else { throw EventStreamError(response.error ?? "events.read failed") }
        guard let batch = response.result?.events else { throw EventStreamError("events.read response missing events") }
        cursor = ControlEventCursor(run: batch.run, after: batch.next)
        return batch.items
    }
}

enum EventFormatter {
    static func json(_ event: ControlEvent) throws -> String {
        String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    }

    static func human(_ event: ControlEvent, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: Date(timeIntervalSince1970: event.ts))
        let name = event.payload.name ?? event.window ?? "-"
        switch event.kind {
        case .status:
            var parts = [time, event.kind.rawValue, name, event.payload.status ?? "idle"]
            if let previous = event.payload.previous { parts.append("previous=\(previous)") }
            if let pane = event.payload.pane { parts.append("pane=\(pane)") }
            if event.payload.blink == true { parts.append("blink") }
            if let color = event.payload.color { parts.append("color=\(color)") }
            if let shape = event.payload.shape { parts.append("shape=\(shape)") }
            return parts.joined(separator: " ")
        case .notify:
            return "\(time) \(event.kind.rawValue) \(name) \(event.payload.title ?? name): \(event.payload.body ?? "")"
        case .sessionCreated, .sessionClosed, .treeChanged:
            return "\(time) \(event.kind.rawValue) \(name)"
        case .sessionSelected:
            return "\(time) \(event.kind.rawValue) \(name) previous=\(event.payload.previous ?? "-")"
        case .paneSplit, .paneScratch:
            return "\(time) \(event.kind.rawValue) \(name) \(event.payload.status ?? "")"
        case .remoteOpened, .remoteClosed:
            return "\(time) \(event.kind.rawValue) \(name) host=\(event.payload.host ?? "")"
        case .appLaunched:
            return "\(time) \(event.kind.rawValue)"
        }
    }
}

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Continuously print control events.")

    @OptionGroup var options: BasicOptions
    @Option(name: .customLong("kind"), help: "Event kind; repeat or comma-separate values.")
    var kindFields: [String] = []
    @Option(name: .customLong("run"), help: "App-run UUID paired with --after.") var runID: String?
    @Option(name: .long, help: "Sequence cursor paired with --run.") var after: String?
    @Option(name: .long, help: "Events per read (1...1000).") var limit: Int?

    private var rawKinds: [String] {
        kindFields.flatMap { field in
            field.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    private var normalizedKinds: [ControlEventKind] { rawKinds.compactMap(ControlEventKind.init(rawValue:)) }

    mutating func validate() throws {
        guard (runID == nil) == (after == nil) else {
            throw ValidationError(ControlEventRequestError.cursorPair)
        }
        if let runID, UUID(uuidString: runID) == nil { throw ValidationError(ControlEventRequestError.invalidRun) }
        if let after, UInt64(after) == nil { throw ValidationError(ControlEventRequestError.invalidCursor) }
        if let limit, !(1...1_000).contains(limit) { throw ValidationError(ControlEventRequestError.invalidLimit) }
        for raw in rawKinds {
            guard ControlEventKind(rawValue: raw) != nil else {
                throw ValidationError(ControlEventRequestError.invalidKind(raw))
            }
        }
    }

    func makeInitialRequest() throws -> ControlRequest {
        makeState().makeRequest()
    }

    func run() throws {
        var state = makeState()
        let dependencies = EventStreamDependencies.live(socketPath: options.socketPath())
        while true { try poll(state: &state, dependencies: dependencies) }
    }

    func poll(state: inout EventStreamState, dependencies: EventStreamDependencies) throws {
        let response: ControlResponse
        do {
            response = try dependencies.send(state.makeRequest())
        } catch {
            guard let delay = state.retryDelay(after: error) else { throw error }
            dependencies.sleep(delay)
            return
        }
        let events = try state.consume(response)
        for event in events {
            let line = try options.json ? EventFormatter.json(event) : EventFormatter.human(event)
            try dependencies.writeLine(line)
        }
        if events.isEmpty { dependencies.sleep(0.25) }
    }

    func makeState() -> EventStreamState {
        let cursor = runID.flatMap(UUID.init(uuidString:)).flatMap { run in
            after.flatMap(UInt64.init).map { ControlEventCursor(run: run, after: $0) }
        }
        let kinds = normalizedKinds.isEmpty ? nil : Set(normalizedKinds)
        return EventStreamState(cursor: cursor, kinds: kinds, limit: limit)
    }
}
