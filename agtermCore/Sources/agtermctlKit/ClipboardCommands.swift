import ArgumentParser
import Foundation
import agtermCore

// MARK: - clipboard

/// Clipboard is local-only: it never touches the control socket, so there is no protocol command and no `--json`.
/// `control-api.md` records the exemption.
struct Clipboard: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The clipboard of the terminals showing this pane.",
        subcommands: [Set.self]
    )

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy text to the clipboard of every terminal showing this pane.",
            discussion: """
            Run it inside a main or split pane started under Live sessions. The text goes out through the pane itself, \
            so it reaches the Mac you are looking at: for a session attached from another Mac that is \
            the Mac showing it, where pbcopy would fill the clipboard of the Mac it runs on. Every \
            terminal attached to the pane receives it, the origin included.

            The text is the argument, or standard input when there is none, copied byte for byte. Text \
            that starts with a dash would be read as an option: pipe it on standard input, or put -- \
            before it. It \
            needs no terminal, so an agent's shell tool can run it. Each receiving terminal applies its \
            own clipboard-write setting, so one set to ask prompts and one set to deny drops the copy; \
            exit status 0 does not confirm that the session or any terminal received it. A pane that is not \
            backed by a live session is refused, and so is text over about 6 MB.
            """)
        @Argument(help: "The text to copy. Read from standard input when omitted. Put -- before text that starts with a dash.")
        var text: String?

        func run() throws {
            let data: Data
            if let text {
                data = Data(text.utf8)
            } else {
                guard isatty(STDIN_FILENO) == 0 else {
                    throw ValidationError("give the text as an argument or pipe it on standard input")
                }
                data = FileHandle.standardInput.readDataToEndOfFile()
            }
            do {
                try TerminalClipboard.copy(data, clientPath: Version.clientPath(),
                                           environment: ProcessInfo.processInfo.environment)
            } catch let failure as TerminalClipboard.Failure {
                throw SocketClientError(Self.message(for: failure))
            }
        }

        static func message(for failure: TerminalClipboard.Failure) -> String {
            switch failure {
            case .emptyText:
                "nothing to copy"
            case .tooLarge(let encodedBytes):
                "text is too large to copy through the terminal: \(encodedBytes) bytes encoded, "
                    + "the limit is \(TerminalClipboard.maxEncodedBytes)"
            case .notLivePane:
                "this pane has no zmx daemon; run it in a main or split pane started under Live sessions"
            case .zmxNotFound(let path):
                "no zmx next to this agtermctl" + (path.map { "; looked for \($0)" } ?? "")
            case .printFailed(let status, let stderr):
                "zmx print exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }
}
