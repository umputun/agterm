import Darwin
import Foundation
import SessionHostRuntime

do {
    let arguments = CommandLine.arguments
    if arguments.count == 3, arguments[1] == "host" {
        try SessionHostRuntime.Host.run(socketDirectory: arguments[2])
    } else if arguments.count == 5, arguments[1] == "host" {
        try SessionHostRuntime.Host.run(socketDirectory: arguments[2], job: (key: arguments[3], label: arguments[4]))
    } else if arguments.count == 2, arguments[1] == "key" {
        print(try SessionHostRuntime.Host.endpointKey())
    } else if arguments.count == 3, arguments[1] == "stop" {
        for (endpoint, outcome) in try HostRetirement.run(socketDirectory: arguments[2]) { print("\(endpoint) \(outcome)") }
    } else if arguments.count >= 7, arguments[1] == "client", arguments[3] == "--" {
        try Client.run(name: arguments[2], argv: Array(arguments.dropFirst(4)))
    } else if arguments.count >= 8, arguments[1] == "client", arguments[3] == "--ends-pane", arguments[4] == "--" {
        try Client.run(name: arguments[2], argv: Array(arguments.dropFirst(5)), endsPane: true)
    } else {
        let usage = "usage: agterm-session-host host SOCKET_DIR [KEY LABEL] | key | stop SOCKET_DIR"
            + " | client NAME [--ends-pane] -- ZMX attach NAME [COMMAND...]\n"
        try? FileHandle.standardError.write(contentsOf: Data(usage.utf8))
        exit(2)
    }
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("session host failed: \(error)\n".utf8))
    exit(1)
}
