import ArgumentParser
import Foundation
import agtermCore

struct Ask: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open, poll, or cancel a themed question dialog.",
        discussion: "Use ask open TITLE when the title is 'open', 'result', or 'cancel'.",
        subcommands: [Open.self, Result.self, Cancel.self],
        defaultSubcommand: Open.self
    )

    struct Open: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Ask a question and wait for its button answer.")
        @Argument(help: "Dialog title.") var title: String
        @Option(name: .long, help: "Optional message below the title.") var message: String?
        @Option(name: .customLong("button"), help: "Button ID=LABEL, or one token for both. Repeat for each button (max 6).")
        var buttons: [String] = []
        @Option(name: .customLong("hotkey"), help: "Button ID=LETTER. Repeat for more buttons.")
        var hotkeys: [String] = []
        @Option(name: .customLong("default"), help: "ID of the initially highlighted button.") var defaultButton: String?
        @Option(name: .customLong("cancel"), help: "Button ID returned on Esc or Command-W.") var cancelButton: String?
        @Option(name: .customLong("destructive"), help: "ID of the destructive button.") var destructiveButton: String?
        @Option(name: .long, help: "Visible session id, prefix, or 'active'. Omit to center in the window.") var target: String?
        @Option(name: .long, help: "Anchor to the session's left or right pane.") var pane: String?
        @Option(name: .customLong("pane-id"), help: "Stable pane token; takes precedence over --pane.") var paneID: String?
        @Flag(name: .long, help: "Raise the owning window.") var follow = false
        @Flag(name: .long, help: "Print the dialog id and return without waiting.") var noBlock = false
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("ask.open requires a title")
            }
            if pane != nil || paneID != nil, target == nil {
                throw ValidationError("--pane requires a session")
            }
            if let pane, OverlayPane(controlName: pane) == nil {
                throw ValidationError("--pane must be left or right")
            }
            _ = try parsedButtons()
        }

        func makeRequest() throws -> ControlRequest {
            let args = ControlArgs(follow: follow ? true : nil, message: message, buttons: try parsedButtons(),
                                   defaultButton: defaultButton, cancelButton: cancelButton, destructiveButton: destructiveButton,
                                   pane: pane, paneID: paneID, title: title)
            return ControlRequest(cmd: .askOpen, target: target, args: options.withWindow(args))
        }

        private func parsedButtons() throws -> [ControlAskButton] {
            guard !buttons.isEmpty else { throw ValidationError("ask requires at least one --button") }
            var choices = buttons.map { token -> ControlAskButton in
                guard let equals = token.firstIndex(of: "=") else { return ControlAskButton(id: token, label: token) }
                return ControlAskButton(id: String(token[..<equals]), label: String(token[token.index(after: equals)...]))
            }
            var assigned = Set<String>()
            for token in hotkeys {
                guard let equals = token.firstIndex(of: "=") else {
                    throw ValidationError("--hotkey requires ID=LETTER")
                }
                let id = String(token[..<equals])
                guard let index = choices.firstIndex(where: { $0.id == id }) else {
                    throw ValidationError("unknown hotkey button: \(id)")
                }
                guard assigned.insert(id).inserted else {
                    throw ValidationError("hotkey already assigned to button: \(id)")
                }
                choices[index] = ControlAskButton(id: id, label: choices[index].label,
                                                 hotkey: String(token[token.index(after: equals)...]))
            }
            return choices
        }

        func run() throws {
            try execute(send: SocketClient(path: options.socketPath()).send,
                        sleep: Thread.sleep(forTimeInterval:), output: { print($0) })
        }

        func execute(send: @escaping (ControlRequest) throws -> ControlResponse,
                     sleep: @escaping (TimeInterval) -> Void, output: @escaping (String) -> Void,
                     errorOutput: @escaping (String) -> Void = ModalCommandRunner.writeStandardError) throws {
            let runner = ModalCommandRunner(family: .ask, json: options.json, send: send, sleep: sleep,
                                            output: output, errorOutput: errorOutput)
            try runner.open(makeRequest(), noBlock: noBlock)
        }
    }

    struct Result: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Print a dialog's current or terminal result as JSON.")
        @Argument(help: "Exact dialog id returned by ask open.") var id: String
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .askResult, target: id, args: options.withWindow())
        }

        func run() throws {
            try execute(send: SocketClient(path: options.socketPath()).send, output: { print($0) })
        }

        func execute(send: @escaping (ControlRequest) throws -> ControlResponse,
                     output: @escaping (String) -> Void,
                     errorOutput: @escaping (String) -> Void = ModalCommandRunner.writeStandardError) throws {
            let runner = ModalCommandRunner(family: .ask, json: options.json, send: send, sleep: { _ in },
                                            output: output, errorOutput: errorOutput)
            try runner.read(makeRequest())
        }
    }

    struct Cancel: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Cancel a dialog without answering a button.")
        @Argument(help: "Exact dialog id returned by ask open.") var id: String
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .askCancel, target: id, args: options.withWindow())
        }
    }
}
