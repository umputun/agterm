import Darwin
import Foundation

// A stand-in for `nc -U` inside the test bundle. The fixtures need a client whose executable sits
// beside the host's, so the host's peer check resolves the same bundle identity. `/usr/bin/nc` cannot
// serve: a plain copy of it is killed by AMFI on exec, and re-signing the copy rescued it on macOS
// 26.6.2 but not on 26.0.1, so the fixture depends on neither (issue #577).

let arguments = CommandLine.arguments
guard arguments.count == 3, arguments[1] == "-U" else {
    FileHandle.standardError.write(Data("usage: session-host-test-client -U SOCKET\n".utf8))
    exit(2)
}

let connection = socket(AF_UNIX, SOCK_STREAM, 0)
guard connection >= 0 else { exit(1) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let path = arguments[2].utf8CString
guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { exit(1) }
withUnsafeMutableBytes(of: &address.sun_path) { buffer in path.withUnsafeBytes { buffer.copyMemory(from: $0) } }
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { exit(1) }

// the host closes mid-write when it rejects an oversized frame, and a default-fatal SIGPIPE would kill
// this client with no output, which a strict fixture then reads as a failed run.
var noSigPipe: Int32 = 1
setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

// Both directions stay live at once: a stalled peer keeps stdin open forever, and the run must still
// end when the host closes its side.
var input = Int32(STDIN_FILENO)
var buffer = [UInt8](repeating: 0, count: 65536)
while true {
    var entries = [pollfd(fd: connection, events: Int16(POLLIN), revents: 0)]
    if input >= 0 { entries.append(pollfd(fd: input, events: Int16(POLLIN), revents: 0)) }
    guard poll(&entries, nfds_t(entries.count), -1) >= 0 || errno == EINTR else { break }
    if entries[0].revents != 0 {
        let count = read(connection, &buffer, buffer.count)
        if count <= 0 { break }
        var written = 0
        while written < count {
            let step = buffer.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress!.advanced(by: written), count - written) }
            if step <= 0 { exit(0) }
            written += step
        }
    }
    if entries.count > 1, entries[1].revents != 0 {
        let count = read(input, &buffer, buffer.count)
        if count <= 0 {
            // stdin is done; half-close so the host sees the request end, and keep reading the reply.
            shutdown(connection, SHUT_WR)
            input = -1
        } else {
            var written = 0
            while written < count {
                let step = buffer.withUnsafeBytes { write(connection, $0.baseAddress!.advanced(by: written), count - written) }
                if step <= 0 {
                    // rejection closes the connection without a response frame
                    let failure = step < 0 ? errno : 0
                    exit(failure == EPIPE || failure == ECONNRESET || failure == ENOTCONN ? 0 : 1)
                }
                written += step
            }
        }
    }
}
close(connection)
exit(0)
