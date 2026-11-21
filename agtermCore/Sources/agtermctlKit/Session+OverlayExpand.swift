import ArgumentParser
import agtermCore

extension Session.Overlay {
    struct Expand: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Lay a JSON Lines page's records out over indented rows, show them as written, or toggle.",
            discussion: "Acts on a .jsonl or .ndjson text page, not a log page. Prints the state left behind, expanded or "
                + "collapsed; tree reads it as htmlOverlays[].text.expand.")
        @Argument(help: "on, off or toggle.") var mode: String
        @Option(name: .long, help: "The pane overlay holding the page (primary/left/top or split/right/bottom).")
        var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard ControlToggleMode.parse(mode) != nil else { throw ValidationError("mode must be on, off or toggle") }
            try Session.Overlay.validatePane(pane)
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionOverlayExpand, target: target.target,
                           args: options.withWindow(ControlArgs(mode: mode, pane: pane)))
        }
    }
}
