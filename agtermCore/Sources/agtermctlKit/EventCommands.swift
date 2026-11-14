#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import ArgumentParser
import Foundation
import agtermCore

struct EventStreamError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// What the stream loop needs from one open stream; `EventStreamConnection` is the live socket one.
protocol EventStreamHandle {
    var reply: ControlResponse { get }
    /// The next framed event, nil at EOF.
    func nextEvent() throws -> ControlEvent?
    func closeStream()
}

/// One live events.stream connection: the anchor reply already read, then one framed ControlEvent
/// per line until EOF. Chunked reads keep whatever follows a newline for the next line — the reply
/// and the first frame can share one packet, so a read that swallowed the byte after the newline
/// would lose it.
final class EventStreamConnection: EventStreamHandle {
    let reply: ControlResponse
    private let fd: Int32
    private var buffer = Data()

    init(socketPath: String, request: ControlRequest) throws {
        fd = try SocketClient(path: socketPath).connect()
        do {
            var data = try JSONEncoder().encode(request)
            guard data.count <= ControlWire.maxRequestLineBytes else {
                throw SocketClientError("request too large (\(data.count) bytes)")
            }
            data.append(UInt8(ascii: "\n"))
            try Self.writeAll(fd, data)
            guard let line = try Self.readLine(into: &buffer, fd: fd) else {
                throw SocketClientError("no response from \(socketPath)")
            }
            reply = try JSONDecoder().decode(ControlResponse.self, from: line)
        } catch {
            close(fd)
            throw error
        }
    }

    func nextEvent() throws -> ControlEvent? {
        guard let line = try Self.readLine(into: &buffer, fd: fd) else { return nil }
        do {
            return try JSONDecoder().decode(ControlEvent.self, from: line)
        } catch {
            throw SocketClientError("could not decode event frame: \(error.localizedDescription)")
        }
    }

    func closeStream() {
        close(fd)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let n = UnixSocket.write(fd, base + offset, data.count - offset)
                if n <= 0 {
                    if errno == EINTR { continue }
                    throw SocketClientError("event stream write failed: \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
    }

    private static func readLine(into buffer: inout Data, fd: Int32) throws -> Data? {
        if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            return line
        }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { return nil }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketClientError("event stream read failed: \(String(cString: strerror(errno)))")
            }
            buffer.append(contentsOf: chunk[0..<n])
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            guard buffer.count <= ControlWire.maxRequestLineBytes else {
                throw SocketClientError("event stream frame exceeds \(ControlWire.maxRequestLineBytes) bytes")
            }
        }
    }
}

struct EventStreamDependencies {
    let send: (ControlRequest) throws -> ControlResponse
    let sleep: (TimeInterval) -> Void
    let writeLine: (String) throws -> Void
    /// One-line diagnostics for a degraded mode; stdout stays event lines only.
    var writeNotice: (String) -> Void = { _ in }
    /// Opens one events.stream connection; the throwing default keeps poll-only call sites working.
    var openStream: (ControlRequest) throws -> any EventStreamHandle = { _ in
        throw SocketClientError("event stream transport unavailable")
    }

    static func live(socketPath: String) -> EventStreamDependencies {
        EventStreamDependencies(
            send: { request in try SocketClient(path: socketPath).send(request).response },
            sleep: Thread.sleep(forTimeInterval:),
            writeLine: { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            },
            writeNotice: { notice in
                FileHandle.standardError.write(Data((notice + "\n").utf8))
            },
            openStream: { request in try EventStreamConnection(socketPath: socketPath, request: request) }
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

    func makeRequest(cmd: Command = .eventsRead) -> ControlRequest {
        let rawKinds = kinds.map { selected in
            ControlEventKind.allCases.filter(selected.contains).map(\.rawValue)
        }
        let args = ControlArgs(after: cursor.map { String($0.after) }, run: cursor?.run.uuidString,
                               kinds: rawKinds, limit: limit)
        if cursor == nil, rawKinds == nil, limit == nil { return ControlRequest(cmd: cmd) }
        return ControlRequest(cmd: cmd, args: args)
    }

    /// Advance the resume cursor past one framed event; the anchor reply set the run.
    mutating func advanced(past event: ControlEvent) {
        nextRetryDelay = Self.firstRetryDelay
        retriedFor = 0
        guard let run = cursor?.run else { return }
        cursor = ControlEventCursor(run: run, after: event.seq)
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
        case .sessionCreated:
            return "\(time) \(event.kind.rawValue) \(name)" + (event.payload.parent.map { " parent=\($0)" } ?? "")
        case .sessionClosed, .treeChanged:
            return "\(time) \(event.kind.rawValue) \(name)"
        case .sessionSelected:
            return "\(time) \(event.kind.rawValue) \(name) previous=\(event.payload.previous ?? "-")"
        case .paneSplit, .paneScratch:
            return "\(time) \(event.kind.rawValue) \(name) \(event.payload.status ?? "")"
        case .paneFocused:
            return "\(time) \(event.kind.rawValue) \(name) \(event.payload.pane ?? "") pane-id=\(event.payload.paneID ?? "-")"
        case .remoteOpened, .remoteClosed:
            return "\(time) \(event.kind.rawValue) \(name) host=\(event.payload.host ?? "")"
                + " remote-session-id=\(event.payload.remoteSessionID ?? "-")"
        case .appLaunched:
            return "\(time) \(event.kind.rawValue)"
        case .message:
            return "\(time) \(event.kind.rawValue) \(name) pane-id=\(event.payload.paneID ?? "-")"
                + " from=\(event.payload.from ?? "-") id=\(event.payload.messageID ?? "-")"
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
    @Flag(name: .long, help: "Poll with events.read; skip the events.stream push transport.") var poll = false

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
        if poll {
            while true { try poll(state: &state, dependencies: dependencies) }
        }
        // the push transport first, falling back to polling for a server without events.stream
        var useStream = true
        while true {
            if useStream {
                switch try streamCycle(state: &state, dependencies: dependencies) {
                case .fellBack: useStream = false
                case .retry(let delay): dependencies.sleep(delay)
                }
            } else {
                try poll(state: &state, dependencies: dependencies)
            }
        }
    }

    enum StreamCycleOutcome: Equatable {
        /// the server has no events.stream; polling events.read takes over for the rest of the run
        case fellBack
        /// wait, then open the stream again
        case retry(TimeInterval)
    }

    /// One stream connection: anchor, framed events until EOF, reconnect. A refused connect goes
    /// through the same retry budget as polling; an error reply carrying no events payload is not a
    /// cursor verdict but the server rejecting the command, so polling takes over instead. Only a
    /// capacity refusal says so — an older server without the command falls back silently.
    func streamCycle(state: inout EventStreamState, dependencies: EventStreamDependencies) throws -> StreamCycleOutcome {
        let stream: any EventStreamHandle
        do {
            stream = try dependencies.openStream(state.makeRequest(cmd: .eventsStream))
        } catch {
            guard let delay = state.retryDelay(after: error) else { throw error }
            return .retry(delay)
        }
        guard stream.reply.ok || stream.reply.result?.events != nil else {
            if stream.reply.error == EventStreamHub.capacityRefusal {
                dependencies.writeNotice(
                    "agtermctl: server refused the event stream (\(EventStreamHub.capacityRefusal)); polling events.read instead")
            }
            stream.closeStream()
            return .fellBack
        }
        defer { stream.closeStream() }
        for event in try state.consume(stream.reply) {
            try dependencies.writeLine(try options.json ? EventFormatter.json(event) : EventFormatter.human(event))
        }
        while let event = try stream.nextEvent() {
            try dependencies.writeLine(try options.json ? EventFormatter.json(event) : EventFormatter.human(event))
            state.advanced(past: event)
        }
        // EOF: reconnect; the pause keeps a crash-looping peer from spinning the loop
        return .retry(0.05)
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
