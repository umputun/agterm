import ArgumentParser
import agtermCore

extension Session {
    struct Lead: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Take the lead of a pane's terminal for this Mac.",
            discussion: """
                A session attached from another Mac has one leading client per pane, whose window size the \
                program sees. A pane that does not lead is covered; this uncovers it, as pressing a key on \
                the cover does, and covers it on the other Mac. Read each pane's `lead` from `tree`.
                """)
        @Option(name: .long, help: "Which pane: primary/left/top or split/right/bottom. Defaults to primary.") var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws { try validatePaneArgument(pane) }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionLead, target: target.target, args: options.withWindow(ControlArgs(pane: pane)))
        }
    }
}
