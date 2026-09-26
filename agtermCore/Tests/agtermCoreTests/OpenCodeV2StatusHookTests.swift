import Foundation
import Testing

@Suite(.enabled(if: OpenCodeStatusHookSupport.node != nil,
                "Node.js 22.7+ (or 20.19+ on the 20.x line) is required to exercise the OpenCode v2 plugin"))
struct OpenCodeV2StatusHookTests {
    @Test func cliPluginLifecycleAndRouting() throws {
        let node = try #require(OpenCodeStatusHookSupport.node)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--test", root.appendingPathComponent("scripts/tests/opencode-v2-status.mjs").path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: data, as: UTF8.self)))
    }
}
