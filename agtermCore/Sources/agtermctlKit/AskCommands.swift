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
        static let configuration = CommandConfiguration(
            abstract: "Ask a question and wait for its button answer.",
            discussion: "--input adds a text field and --choice a radio list (checkboxes with --multiple); either form defaults "
                + "its buttons to ok=OK and cancel=Cancel, Cancel ending like Esc. The answer carries the field's text or the selected ids, "
                + "plus the --other row's text when it is selected."
        )
        @Argument(help: "Dialog title.") var title: String
        @Option(name: .long, help: "Optional message below the title.") var message: String?
        @Option(name: .customLong("button"), help: "Button ID=LABEL, or one token for both. Repeat for each button (max 6).")
        var buttons: [String] = []
        @Option(name: .customLong("hotkey"), help: "Button ID=LETTER. Repeat for more buttons.")
        var hotkeys: [String] = []
        @Option(name: .customLong("default"), help: "ID of the initially highlighted button.") var defaultButton: String?
        @Option(name: .long, help: "Dialog style: terminal or gui.") var style = "terminal"
        @Option(name: .long, help: "Button block alignment: left, center, or right.") var align = "right"
        @Option(name: .long, parsing: .unconditional, help: "Panel width as an integer percent of the anchor (10...100); omit for automatic sizing.")
        var width: String?
        @Option(name: .customLong("destructive"), help: "ID of the destructive button.") var destructiveButton: String?
        @Option(name: .customLong("cancel"), help: "ID of the button that ends the dialog like Esc, returning nothing.") var cancelButton: String?
        @Option(name: .long, help: "Add a text field: line or multiline.") var input: String?
        @Option(name: .long, help: "Initial text of the --input field.") var value: String?
        @Option(name: .long, help: "Hint shown while the --input field is empty.") var placeholder: String?
        @Option(name: .customLong("choice"), help: "List item ID=LABEL, or one token for both. Repeat for each item (max 50).")
        var choices: [String] = []
        @Option(name: .customLong("choice-subtitle"), help: "Item description ID=TEXT, drawn dimmed under its label.")
        var choiceSubtitles: [String] = []
        @Flag(name: .long, help: "Make the --choice list checkboxes instead of radio buttons.") var multiple = false
        @Option(name: .customLong("checked"), help: "ID of an item selected at open. Repeat with --multiple.") var checked: [String] = []
        @Option(name: .long, help: "Add a free-form row after the --choice list, with this placeholder; its text answers as `text`.")
        var other: String?
        @Option(name: .long, help: "Session id, prefix, or 'active'. Default: selected session for terminal, window-centered for gui.") var target: String?
        @Option(name: .long, help: "Anchor to the session's left or right pane. GUI style requires --target.") var pane: String?
        @Option(name: .customLong("pane-id"), help: "Stable pane token; overrides --pane. GUI style requires --target.") var paneID: String?
        @Flag(name: .long, help: "Raise the owning window.") var follow = false
        @Flag(name: .long, help: "Print the dialog id and return without waiting.") var noBlock = false
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("ask.open requires a title")
            }
            if style == "gui", pane != nil || paneID != nil, target == nil {
                throw ValidationError("--pane requires a session")
            }
            if let pane, OverlayPane(controlName: pane) == nil {
                throw ValidationError("--pane must be left or right")
            }
            guard ControlAskStyle(rawValue: style) != nil else { throw ValidationError("unknown style") }
            guard ControlAskAlignment(rawValue: align) != nil else { throw ValidationError("unknown align") }
            _ = try parsedWidth()
            _ = try parsedButtons()
            _ = try parsedChoices()
        }

        func makeRequest() throws -> ControlRequest {
            let args = ControlArgs(follow: follow ? true : nil, message: message, buttons: try parsedButtons(),
                                   defaultButton: defaultButton, destructiveButton: destructiveButton, style: style, align: align,
                                   pane: pane, paneID: paneID, title: title, width: try parsedWidth(), value: value,
                                   cancelButton: cancelButton, input: input, placeholder: placeholder, choices: try parsedChoices(),
                                   multiple: multiple ? true : nil, checked: checked.isEmpty ? nil : checked, other: other)
            return ControlRequest(cmd: .askOpen, target: target, args: options.withWindow(args))
        }

        private func parsedWidth() throws -> Int? {
            guard let width else { return nil }
            guard let value = Int(width), (10...100).contains(value) else {
                throw ValidationError("width must be 10 to 100")
            }
            return value
        }

        private func parsedButtons() throws -> [ControlAskButton]? {
            guard !buttons.isEmpty else {
                guard input == nil, choices.isEmpty else {
                    guard hotkeys.isEmpty else { throw ValidationError("--hotkey requires --button") }
                    return nil
                }
                throw ValidationError("ask requires at least one --button")
            }
            var parsed = buttons.map { token -> ControlAskButton in
                guard let equals = token.firstIndex(of: "=") else { return ControlAskButton(id: token, label: token) }
                return ControlAskButton(id: String(token[..<equals]), label: String(token[token.index(after: equals)...]))
            }
            var assigned = Set<String>()
            for token in hotkeys {
                guard let equals = token.firstIndex(of: "=") else {
                    throw ValidationError("--hotkey requires ID=LETTER")
                }
                let id = String(token[..<equals])
                guard let index = parsed.firstIndex(where: { $0.id == id }) else {
                    throw ValidationError("unknown hotkey button: \(id)")
                }
                guard assigned.insert(id).inserted else {
                    throw ValidationError("hotkey already assigned to button: \(id)")
                }
                parsed[index] = ControlAskButton(id: id, label: parsed[index].label,
                                                 hotkey: String(token[token.index(after: equals)...]))
            }
            return parsed
        }

        private func parsedChoices() throws -> [ControlAskChoice]? {
            guard !choices.isEmpty else {
                guard choiceSubtitles.isEmpty else { throw ValidationError("--choice-subtitle requires --choice") }
                guard other == nil else { throw ValidationError("--other requires --choice") }
                return nil
            }
            let items = choices.map { token -> (id: String, label: String) in
                guard let equals = token.firstIndex(of: "=") else { return (token, token) }
                return (String(token[..<equals]), String(token[token.index(after: equals)...]))
            }
            var subtitles: [String: String] = [:]
            for token in choiceSubtitles {
                guard let equals = token.firstIndex(of: "=") else { throw ValidationError("--choice-subtitle requires ID=TEXT") }
                let id = String(token[..<equals])
                guard items.contains(where: { $0.id == id }) else { throw ValidationError("unknown subtitle choice: \(id)") }
                guard subtitles[id] == nil else { throw ValidationError("subtitle already set for choice: \(id)") }
                subtitles[id] = String(token[token.index(after: equals)...])
            }
            return items.map { ControlAskChoice(id: $0.id, label: $0.label, subtitle: subtitles[$0.id]) }
        }

        func run() throws {
            try execute(send: SocketClient(path: options.socketPath()).send,
                        sleep: Thread.sleep(forTimeInterval:), output: { print($0) })
        }

        func execute(send: @escaping (ControlRequest) throws -> SocketReply,
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

        func execute(send: @escaping (ControlRequest) throws -> SocketReply,
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
