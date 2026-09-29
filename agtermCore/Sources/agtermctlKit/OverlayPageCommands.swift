import ArgumentParser
import Foundation
import agtermCore

extension Session.Overlay {
    /// absolutePath resolves a path the way the caller's shell sees it, since the app never learns the
    /// caller's directory. Symlinks are kept: `/tmp` stays `/tmp`, so a page and its `--cwd` compare as typed.
    static func absolutePath(_ path: String) -> String {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }

    struct Reload: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reload an HTML overlay: the file or URL it was opened with, or with --current the page shown now.")
        @Flag(name: .long, help: "Reload the page the overlay shows now instead of the original file or URL.") var current = false
        @Option(name: .long, help: "Reload that split pane's page (primary/left/top or split/right/bottom); omit for the session-wide overlay.")
        var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws { try Session.Overlay.validatePane(pane) }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionOverlayReload, target: target.target,
                           args: options.withWindow(ControlArgs(pane: pane, current: current ? true : nil)))
        }
    }

    struct Submit: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Answer an HTML overlay with a value and close it, as its page would; a waiting --block prints the value.")
        @Option(name: .long, help: "The answer handed back to the caller; empty is a real answer.") var value: String
        @Option(name: .long, help: "Answer that split pane's page (primary/left/top or split/right/bottom); omit for the session-wide overlay.")
        var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws { try Session.Overlay.validatePane(pane) }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionOverlaySubmit, target: target.target,
                           args: options.withWindow(ControlArgs(pane: pane, value: value)))
        }
    }

    struct Navigate: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Step an HTML overlay's history, open it in the browser, or reveal its current file in Finder.")
        @Argument(help: "back, forward, browser, or finder (file pages only).") var step: String
        @Option(name: .long, help: "Navigate that split pane's page (primary/left/top or split/right/bottom); omit for the session-wide overlay.")
        var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard HtmlNavigation(rawValue: step) != nil else {
                throw ValidationError("step must be back, forward, browser, or finder")
            }
            try Session.Overlay.validatePane(pane)
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionOverlayNavigate, target: target.target,
                           args: options.withWindow(ControlArgs(pane: pane, to: step)))
        }
    }
}

extension Session.Overlay.Open {
    static let blockHelp: ArgumentHelp = """
        Block until COMMAND exits and exit with its status (the program renders normally; capture its output via the \
        program's own output file). With --html, wait for the page to submit or close, print its outcome JSON, and \
        exit 0 when submitted, 2 when dismissed, 1 on error.
        """
}

// a page read prints its outcome and exits like pick; a program read keeps the plain request output
extension Session.Overlay.Result {
    func validate() throws {
        try Session.Overlay.validatePane(pane)
        if page != nil, pane != nil { throw ValidationError("--page cannot be combined with --pane") }
    }

    func makeRequest() throws -> ControlRequest {
        if let page { return ControlRequest(cmd: .sessionOverlayResult, args: ControlArgs(page: page)) }
        return ControlRequest(cmd: .sessionOverlayResult, target: target.target,
                              args: options.withWindow(pane.map { ControlArgs(pane: $0) }))
    }

    func run() throws {
        guard let page else { return try defaultRun() }
        try HtmlPageRunner(json: options.json, send: SocketClient(path: options.socketPath()).send).read(page)
    }
}

/// HtmlPageRunner is the page side of `session overlay open --html --block` and `result --page`, with the
/// transport, sleep and output injected so every outcome and exit status is testable without a socket. It
/// polls by the page id the open reply names, never by session, so a page reopened in the same slot cannot
/// answer for this one.
struct HtmlPageRunner {
    let json: Bool
    let send: (ControlRequest) throws -> SocketReply
    let sleep: (TimeInterval) -> Void
    let output: (String) -> Void
    let errorOutput: (String) -> Void

    init(json: Bool, send: @escaping (ControlRequest) throws -> SocketReply,
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         output: @escaping (String) -> Void = { print($0) },
         errorOutput: @escaping (String) -> Void = ModalCommandRunner.writeStandardError) {
        self.json = json
        self.send = send
        self.sleep = sleep
        self.output = output
        self.errorOutput = errorOutput
    }

    func block(_ open: ControlRequest) throws {
        let opened = try send(open)
        try requireSuccess(opened)
        guard let pageID = opened.response.result?.pageID else {
            errorOutput("error: session.overlay.open result missing pageID")
            throw ExitCode.failure
        }
        var pendingPolls = 0
        while true {
            let polled = try poll(pageID)
            if polled.outcome.outcome == .pending {
                pendingPolls += 1
                sleep(SocketClient.pickPollDelay(afterPendingPoll: pendingPolls))
                continue
            }
            try finish(polled)
            return
        }
    }

    func read(_ pageID: String) throws {
        try finish(try poll(pageID))
    }

    private func poll(_ pageID: String) throws -> (reply: SocketReply, outcome: ControlHtmlPageOutcome) {
        let reply = try send(ControlRequest(cmd: .sessionOverlayResult, args: ControlArgs(page: pageID)))
        try requireSuccess(reply)
        guard let outcome = reply.response.result?.pageOutcome else {
            errorOutput("error: session.overlay.result missing the page outcome")
            throw ExitCode.failure
        }
        return (reply, outcome)
    }

    private func finish(_ polled: (reply: SocketReply, outcome: ControlHtmlPageOutcome)) throws {
        output(json ? polled.reply.line : String(decoding: try JSONEncoder().encode(polled.outcome), as: UTF8.self))
        let code = SocketClient.pageExitCode(for: polled.outcome.outcome)
        if code.rawValue != 0 { throw code }
    }

    private func requireSuccess(_ reply: SocketReply) throws {
        guard !reply.response.ok else { return }
        if json { output(reply.line) } else { errorOutput(SocketClient.formatResponse(reply.response)) }
        throw ExitCode.failure
    }
}
