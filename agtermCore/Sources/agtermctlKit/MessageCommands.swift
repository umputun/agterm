import ArgumentParser
import Dispatch
import Foundation
import agtermCore

/// Msg is `agtermctl msg`: messages addressed to a pane, read and acknowledged by that pane.
struct Msg: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msg",
        abstract: "Send, read and acknowledge messages between panes.",
        subcommands: [Send.self, Read.self, Ack.self])

    /// emit writes one reply's output and fails the command when the output says so.
    static func emit(_ output: MessageOutput) throws {
        if !output.stdout.isEmpty { FileHandle.standardOutput.write(Data(output.stdout.utf8)) }
        if !output.stderr.isEmpty { FileHandle.standardError.write(Data(output.stderr.utf8)) }
        if output.failed { throw ExitCode.failure }
    }

    /// refused is the output of a reply whose `ok` is false.
    static func refused(_ reply: SocketReply, json: Bool) -> MessageOutput {
        if json { return MessageOutput(stdout: reply.line + "\n", failed: true) }
        return MessageOutput(stderr: "error: \(reply.response.error ?? "unknown error")\n", failed: true)
    }
}

/// MessageOutput is what one `msg` reply prints and whether the command fails.
struct MessageOutput: Equatable {
    var stdout = ""
    var stderr = ""
    var failed = false
}

/// MessageIdentityOptions names the pane a command acts as: `--as`, else the pane's own environment.
struct MessageIdentityOptions: ParsableArguments {
    @Option(name: .customLong("as"), help: "Act as this pane, SESSION:PANE-ID (defaults to AGTERM_SESSION_ID:AGTERM_PANE_ID).")
    var identity: String?

    /// resolve is nil only when neither variable is present, which makes a send anonymous. Any other
    /// combination short of two non-empty values is an error, so a broken environment never sends as nobody.
    func resolve(env: [String: String]) throws -> String? {
        if let identity { return identity }
        let session = env["AGTERM_SESSION_ID"], pane = env["AGTERM_PANE_ID"]
        if session == nil, pane == nil { return nil }
        guard let session, !session.isEmpty, let pane, !pane.isEmpty else {
            throw SocketClientError("incomplete pane identity: AGTERM_SESSION_ID and AGTERM_PANE_ID must both be set; "
                + "pass --as SESSION:PANE-ID")
        }
        return "\(session):\(pane)"
    }
}

struct MessageReadDependencies {
    let send: (ControlRequest) throws -> SocketReply
    let sleep: (TimeInterval) -> Void
    /// Monotonic seconds, so a wall-clock change cannot stretch or cut the timeout.
    let now: () -> TimeInterval

    static func live(socketPath: String) -> MessageReadDependencies {
        MessageReadDependencies(
            send: { request in try SocketClient(path: socketPath).send(request) },
            sleep: Thread.sleep(forTimeInterval:),
            now: { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 })
    }
}

enum MessageReadOutcome {
    case reply(SocketReply)
    case timedOut
}

extension Msg {
    struct Send: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a message to one or more panes.",
            discussion: """
            msg send "build done" --to SESSION:right
            msg send --stdin --all --workspace W < notes.txt

            A recipient is SESSION:PANE, where PANE is a pane id or left, right or scratch. --all reaches \
            every live pane in every open window except the sender. Prints the message id. Exit 1 when any \
            recipient was rejected; the copies that were delivered stay queued.
            """)

        @Argument(help: "Message body; use --stdin to read it instead.")
        var text: String?
        @Flag(name: .long, help: "Read the body from stdin.")
        var stdin = false
        @Option(name: .customLong("to"), help: "Recipient SESSION:PANE; repeat for several.")
        var recipients: [String] = []
        @Flag(name: .long, help: "Send to every live pane except the sender.")
        var all = false
        @Option(name: .long, help: "With --all, only the panes of this workspace.")
        var workspace: String?
        @OptionGroup var identity: MessageIdentityOptions
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard (text != nil) != stdin else { throw ValidationError("provide the body as TEXT or --stdin, exactly one") }
        }

        func makeRequest(body: String, env: [String: String]) throws -> ControlRequest {
            var args = ControlArgs()
            args.body = body
            args.recipients = recipients.isEmpty ? nil : recipients
            args.all = all ? true : nil
            args.workspace = workspace
            args.identity = try identity.resolve(env: env)
            return ControlRequest(cmd: .msgSend, args: args)
        }

        func run() throws {
            let body = try text ?? decodeTypedStdin(FileHandle.standardInput.readDataToEndOfFile())
            let request = try makeRequest(body: body, env: ProcessInfo.processInfo.environment)
            try Msg.emit(Self.output(SocketClient(path: options.socketPath()).send(request), json: options.json))
        }

        static func output(_ reply: SocketReply, json: Bool) -> MessageOutput {
            guard reply.response.ok else { return Msg.refused(reply, json: json) }
            let rejected = reply.response.result?.rejected ?? []
            if json { return MessageOutput(stdout: reply.line + "\n", failed: !rejected.isEmpty) }
            return MessageOutput(stdout: (reply.response.result?.messageID ?? "") + "\n",
                                 stderr: rejected.map { "rejected \($0.address): \($0.reason.rawValue)\n" }.joined(),
                                 failed: !rejected.isEmpty)
        }
    }

    struct Read: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read the oldest messages in this pane's mailbox.",
            discussion: """
            msg read [--ack] [--wait [--timeout N]]

            Prints each message as a line "ID from SENDER" followed by its body. Reading does not remove \
            anything; acknowledge with msg ack, or pass --ack to remove the printed batch in the same step. \
            --wait repeats the read until a message arrives; --timeout ends it with exit \(timeoutExitCode).
            """)

        static let timeoutExitCode: Int32 = 124
        static let pollDelay: TimeInterval = 0.25

        @Flag(name: .long, help: "Remove the messages this read returns.")
        var ack = false
        @Flag(name: .long, help: "Wait until a message arrives.")
        var wait = false
        @Option(name: .long, help: "With --wait, seconds before exiting \(timeoutExitCode).")
        var timeout: Double?
        @OptionGroup var identity: MessageIdentityOptions
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard let timeout else { return }
            guard wait else { throw ValidationError("--timeout needs --wait") }
            guard timeout.isFinite, timeout > 0 else { throw ValidationError("--timeout must be a positive number of seconds") }
        }

        func makeRequest(env: [String: String]) throws -> ControlRequest {
            var args = ControlArgs()
            args.identity = try identity.resolve(env: env)
            args.ack = ack ? true : nil
            return ControlRequest(cmd: .msgRead, args: args)
        }

        func run() throws {
            let request = try makeRequest(env: ProcessInfo.processInfo.environment)
            let watchdog = timeout.map { seconds in
                SessionWaitWatchdog(seconds: seconds) {
                    Self.reportTimeout()
                    Darwin.exit(Self.timeoutExitCode)
                }
            }
            defer { watchdog?.cancel() }
            switch try read(request, dependencies: .live(socketPath: options.socketPath())) {
            case .reply(let reply): try Msg.emit(output(reply))
            case .timedOut:
                Self.reportTimeout()
                throw ExitCode(Self.timeoutExitCode)
            }
        }

        /// read sends the read itself on every poll, `--ack` included: an empty read removes nothing, and a
        /// separate probe would leave a gap in which another reader could drain the mailbox.
        func read(_ request: ControlRequest, dependencies: MessageReadDependencies) throws -> MessageReadOutcome {
            let deadline = timeout.map { dependencies.now() + $0 }
            while true {
                let reply = try dependencies.send(request)
                let result = reply.response.result
                guard wait, reply.response.ok, result?.messages?.isEmpty ?? true, !ack || Self.ackConfirmed(result) else {
                    return .reply(reply)
                }
                guard let deadline else {
                    dependencies.sleep(Self.pollDelay)
                    continue
                }
                let left = deadline - dependencies.now()
                if left <= 0 { return .timedOut }
                dependencies.sleep(min(Self.pollDelay, left))
            }
        }

        func output(_ reply: SocketReply) -> MessageOutput {
            guard reply.response.ok else { return Msg.refused(reply, json: options.json) }
            let result = reply.response.result
            if ack, !Self.ackConfirmed(result) {
                return MessageOutput(stderr: "error: the app did not confirm which messages it removed; nothing was printed\n",
                                     failed: true)
            }
            if options.json { return MessageOutput(stdout: reply.line + "\n") }
            let remaining = result?.remaining ?? 0
            return MessageOutput(stdout: (result?.messages ?? []).map(Self.render).joined(),
                                 stderr: remaining > 0 ? "\(remaining) more pending\n" : "")
        }

        /// ackConfirmed holds when `acked` names exactly the returned messages, so an app that ignored the
        /// flag cannot pass for one that removed them.
        static func ackConfirmed(_ result: ControlResult?) -> Bool {
            guard let acked = result?.acked else { return false }
            return acked == (result?.messages ?? []).map(\.id.uuidString)
        }

        static func render(_ message: BusMessage) -> String {
            let body = message.body.hasSuffix("\n") ? message.body : message.body + "\n"
            return "\(message.id.uuidString) from \(message.from ?? "outside agterm")\n\(body)"
        }

        private static func reportTimeout() {
            FileHandle.standardError.write(Data("timed out\n".utf8))
        }
    }

    struct Ack: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove messages from this pane's mailbox by id.",
            discussion: "Unknown or already removed ids are not an error. Prints how many were removed.")

        @Argument(help: "Message ids from msg read.")
        var ids: [String]
        @OptionGroup var identity: MessageIdentityOptions
        @OptionGroup var options: BasicOptions

        func makeRequest(env: [String: String]) throws -> ControlRequest {
            var args = ControlArgs()
            args.identity = try identity.resolve(env: env)
            args.ids = ids
            return ControlRequest(cmd: .msgAck, args: args)
        }

        func run() throws {
            let request = try makeRequest(env: ProcessInfo.processInfo.environment)
            try Msg.emit(Self.output(SocketClient(path: options.socketPath()).send(request), json: options.json))
        }

        static func output(_ reply: SocketReply, json: Bool) -> MessageOutput {
            guard reply.response.ok else { return Msg.refused(reply, json: json) }
            if json { return MessageOutput(stdout: reply.line + "\n") }
            return MessageOutput(stdout: "acked \(reply.response.result?.acked?.count ?? 0)\n")
        }
    }
}
