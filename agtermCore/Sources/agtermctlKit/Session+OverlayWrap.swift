import ArgumentParser
import agtermCore

extension Session.Overlay {
    struct Wrap: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Wrap a text page's long lines, unwrap them, or toggle between the two.",
            discussion: "Acts on a text, log or diff page. Prints the state left behind, wrapped or unwrapped; tree reads "
                + "it as htmlOverlays[].text.wrap.")
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
            ControlRequest(cmd: .sessionOverlayWrap, target: target.target,
                           args: options.withWindow(ControlArgs(mode: mode, pane: pane)))
        }
    }
}
