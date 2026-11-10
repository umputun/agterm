import ArgumentParser
import agtermCore

extension Session.Overlay {
    struct Follow: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Follow a log page's end, pause it, or toggle between the two.",
            discussion: "Acts on a page opened with --tail or --follow-file, or a clicked .log or .out file. Prints the "
                + "state left behind, following or paused; tree reads it as htmlOverlays[].text.following.")
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
            ControlRequest(cmd: .sessionOverlayFollow, target: target.target,
                           args: options.withWindow(ControlArgs(mode: mode, pane: pane)))
        }
    }
}
