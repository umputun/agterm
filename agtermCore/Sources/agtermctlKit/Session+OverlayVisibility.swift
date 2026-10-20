import ArgumentParser
import agtermCore

extension Session.Overlay {
    static let visibilityScope =
        "Without --pane this acts on every overlay of the session: the session-wide one and both pane overlays."
    static let visibilityPaneHelp = "Only that split pane's overlay (primary/left/top or split/right/bottom)."

    struct Hide: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Hide the session's overlays without closing them.",
            discussion: "A hidden overlay keeps running and stays in `tree` (hiddenOverlays); the terminal under it "
                + "takes input. \(visibilityScope)")
        @Option(name: .long, help: ArgumentHelp(stringLiteral: visibilityPaneHelp)) var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws { try Session.Overlay.validatePane(pane) }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionOverlayHide, target: target.target,
                           args: options.withWindow(pane.map { ControlArgs(pane: $0) }))
        }
    }

    struct Show: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the session's hidden overlays again.",
            discussion: visibilityScope)
        @Option(name: .long, help: ArgumentHelp(stringLiteral: visibilityPaneHelp)) var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws { try Session.Overlay.validatePane(pane) }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionOverlayShow, target: target.target,
                           args: options.withWindow(pane.map { ControlArgs(pane: $0) }))
        }
    }

    struct Toggle: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Hide the session's overlays if any is shown, otherwise show them all.",
            discussion: "Prints the state left behind, hidden or shown. \(visibilityScope)")
        @Option(name: .long, help: ArgumentHelp(stringLiteral: visibilityPaneHelp)) var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws { try Session.Overlay.validatePane(pane) }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionOverlayToggle, target: target.target,
                           args: options.withWindow(pane.map { ControlArgs(pane: $0) }))
        }
    }
}
