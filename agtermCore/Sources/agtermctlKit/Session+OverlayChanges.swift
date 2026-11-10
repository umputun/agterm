import ArgumentParser
import agtermCore

extension Session.Overlay {
    struct Changes: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Step a diff page to its next or previous change.",
            discussion: "A change is one run of removed and added lines. A step prints the change it reached as N of M; "
                + "tree reads the count and the current change as htmlOverlays[].text.changes.")
        @Flag(name: .long, help: "Step to the next change.") var next = false
        @Flag(name: .long, help: "Step to the previous change.") var prev = false
        @Option(name: .long, help: "The pane overlay holding the page (primary/left/top or split/right/bottom).")
        var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            if next == prev { throw ValidationError("give exactly one of --next or --prev") }
            try Session.Overlay.validatePane(pane)
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionOverlayChanges, target: target.target,
                           args: options.withWindow(ControlArgs(pane: pane, to: next ? "next" : "prev")))
        }
    }
}
