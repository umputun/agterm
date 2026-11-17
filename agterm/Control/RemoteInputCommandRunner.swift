import Foundation
import agtermCore

/// RemoteInputCommandRunner runs an ssh invocation with the file at `input` on its standard input. It is separate
/// from `RemoteCommandRunner`, whose conformers (the agterm-linux fork's among them) send no input.
protocol RemoteInputCommandRunner: Sendable {
    func run(_ argv: [String], deadline: TimeInterval, input: URL) async -> RemoteCommandResult
}
