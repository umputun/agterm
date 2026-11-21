import ArgumentParser
import agtermCore

extension Session.Overlay {
    struct Files: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Jump a diff page to one of its files.",
            discussion: "A file is named by its number from 1 or by its path as the page's file list shows it. "
                + "The jump prints the file it reached as N of M: path; tree reads the file in view as "
                + "htmlOverlays[].text.files.")
        @Option(name: .long, help: "The file to show: its number from 1, or its path as the page lists it.")
        var go: String
        @Option(name: .long, help: "The pane overlay holding the page (primary/left/top or split/right/bottom).")
        var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            if go.isEmpty { throw ValidationError("--go needs a file number or path") }
            try Session.Overlay.validatePane(pane)
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionOverlayFiles, target: target.target,
                           args: options.withWindow(ControlArgs(pane: pane, to: go)))
        }
    }
}
