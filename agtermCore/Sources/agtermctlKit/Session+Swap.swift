import ArgumentParser
import agtermCore

extension Session {
    struct Swap: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Exchange a split session's two panes, including their live roles and state.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions
        @OptionGroup var operation: OperationOptions

        func makeRequest() throws -> ControlRequest {
            operation.stamp(ControlRequest(cmd: .sessionSwap, target: target.target, args: options.withWindow()))
        }
    }
}
