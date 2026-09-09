import Darwin
import Foundation
import SessionHostRuntime

do {
    let arguments = CommandLine.arguments
    if arguments.count == 3, arguments[1] == "host" {
        try SessionHostRuntime.Host.run(socketDirectory: arguments[2])
    } else if arguments.count >= 7, arguments[1] == "client", arguments[3] == "--" {
        try Client.run(name: arguments[2], argv: Array(arguments.dropFirst(4)))
    } else {
        try? FileHandle.standardError.write(contentsOf: Data("usage: agterm-session-host host SOCKET_DIR | client NAME -- ZMX attach NAME [COMMAND...]\n".utf8))
        exit(2)
    }
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("session host failed: \(error)\n".utf8))
    exit(1)
}
