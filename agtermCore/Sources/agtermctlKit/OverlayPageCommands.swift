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
            abstract: "Reload an HTML overlay: the file it was opened with, or with --current the page shown now.")
        @Flag(name: .long, help: "Reload the page the overlay shows now instead of the original file.") var current = false
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

    struct Navigate: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Step an HTML overlay's history back or forward, or open its current page in the default browser.")
        @Argument(help: "back, forward, or browser.") var step: String
        @Option(name: .long, help: "Navigate that split pane's page (primary/left/top or split/right/bottom); omit for the session-wide overlay.")
        var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard HtmlNavigation(rawValue: step) != nil else {
                throw ValidationError("step must be back, forward, or browser")
            }
            try Session.Overlay.validatePane(pane)
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionOverlayNavigate, target: target.target,
                           args: options.withWindow(ControlArgs(pane: pane, to: step)))
        }
    }
}
