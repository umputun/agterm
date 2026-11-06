import ArgumentParser
import Foundation
import agtermCore

extension Session.Overlay {
    struct PageAttach: RequestCommand {
        static let configuration = CommandConfiguration(
            commandName: "page-attach",
            abstract: "Hand out one attachment of a page companion to another Mac.",
            discussion: """
            Run on this Mac by the agterm on another Mac, over ssh, when it shows one of this app's page companions: \
            the reply carries the page and a single-use token its `page-serve` claims. It is not meant to be run by \
            hand.
            """)

        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionCompanionPageAttach, target: target.target, args: options.withWindow())
        }
    }
}
