import ArgumentParser
import agtermCore

extension Session.Overlay {
    struct Search: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search a text or log page: set the query, step to the next or previous match, or close it.",
            discussion: "Not session search, which searches a terminal. A step prints the match it reached as N of M "
                + "and pauses a log page that follows; tree reads the query and counts as htmlOverlays[].text.search.")
        @Argument(help: "Text to find, case-insensitive.") var text: String?
        @Flag(name: .long, help: "Step to the next match.") var next = false
        @Flag(name: .long, help: "Step to the previous match.") var prev = false
        @Flag(name: .long, help: "Close the search.") var close = false
        @Option(name: .long, help: "The pane overlay holding the page (primary/left/top or split/right/bottom).")
        var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            let steps = [next, prev, close].filter { $0 }.count
            if steps > 1 { throw ValidationError("--next, --prev and --close are mutually exclusive") }
            if steps == 1, text != nil { throw ValidationError("text cannot be combined with --next, --prev or --close") }
            if steps == 0, text == nil { throw ValidationError("give text, --next, --prev or --close") }
            if text?.isEmpty == true { throw ValidationError("text must not be empty") }
            try Session.Overlay.validatePane(pane)
        }

        func makeRequest() throws -> ControlRequest {
            let to = next ? "next" : prev ? "prev" : close ? "close" : nil
            return ControlRequest(cmd: .sessionOverlaySearch, target: target.target,
                                  args: options.withWindow(ControlArgs(text: text, pane: pane, to: to)))
        }
    }
}
