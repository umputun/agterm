import Darwin
import Foundation
import SessionHostRuntime

guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "host" else {
    try? FileHandle.standardError.write(contentsOf: Data("usage: agterm-session-host host SOCKET_DIR\n".utf8))
    exit(2)
}
do {
    try SessionHostRuntime.Host.run(socketDirectory: CommandLine.arguments[2])
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("session host failed: \(error)\n".utf8))
    exit(1)
}
