import Darwin
import Foundation
import agtermCore

/// A failure talking to the control socket (connect/write/read/decode), distinct from a server-side
/// `{"ok":false}` response (which is a valid decoded `ControlResponse`).
struct SocketClientError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A blocking, one-request-per-connection client for the agterm control socket: connect to a unix domain
/// socket, write the request line, read the single response line, decode it.
struct SocketClient {
    let path: String

    /// 64 MiB cap on a response line. Requests stay small; a `session.text --all` response carries the
    /// whole scrollback and can reach several MiB. It comes from our own server, so the cap only guards
    /// against a runaway read (ghostty scrollback tops out near 10 MiB).
    private static let maxLineBytes = 64 << 20

    /// Connect, send `request` as one newline-terminated JSON line, read the response line, decode it.
    func send(_ request: ControlRequest) throws -> ControlResponse {
        let fd = try connect()
        defer { close(fd) }

        var data = try JSONEncoder().encode(request)
        data.append(UInt8(ascii: "\n"))
        try Self.writeAll(fd, data)

        guard let line = Self.readLine(fd) else {
            throw SocketClientError("no response from \(path)")
        }
        do {
            return try JSONDecoder().decode(ControlResponse.self, from: line)
        } catch {
            throw SocketClientError("could not decode response: \(error.localizedDescription)")
        }
    }

    /// Open and connect a `AF_UNIX` stream socket to `path`.
    private func connect() throws -> Int32 {
        guard path.utf8.count < 104 else {
            throw SocketClientError("socket path too long (\(path.utf8.count) bytes): \(path)")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError("socket() failed: \(String(cString: strerror(errno)))") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                pathBytes.withUnsafeBufferPointer { src in
                    buf.update(from: src.baseAddress!, count: src.count)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw SocketClientError("connect(\(path)) failed: \(message) — is agterm running?")
        }
        return fd
    }

    /// Write all of `data` to `fd`, looping over short writes.
    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n <= 0 { throw SocketClientError("write failed: \(String(cString: strerror(errno)))") }
                offset += n
            }
        }
    }

    /// Read up to (and excluding) the first newline, capping at `maxLineBytes`. Returns nil on
    /// EOF-before-newline, error, or cap exceeded. Reads in 64 KiB chunks so a multi-MB
    /// `session.text --all` response takes a handful of syscalls instead of one per byte.
    private static func readLine(_ fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { return buffer.isEmpty ? nil : buffer }
            if n < 0 { return nil }
            if let idx = chunk[0..<n].firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(contentsOf: chunk[0..<idx])
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > maxLineBytes { return nil }
        }
    }

    /// Print a response: the raw JSON line with `json: true`, otherwise a human-readable summary. An error
    /// response (`ok == false`, non-`--json`) goes to stderr; everything else to stdout.
    static func printResponse(_ response: ControlResponse, json: Bool, echoID: Bool = false) {
        if !json, !response.ok {
            FileHandle.standardError.write(Data((formatResponse(response, json: false) + "\n").utf8))
            return
        }
        print(formatResponse(response, json: json, echoID: echoID))
    }

    /// Render a response to a single string (no trailing newline): the raw JSON line with `json: true`,
    /// otherwise a human-readable summary — an `error:` line, the tree listing, the selected text, the
    /// affected id (only when `echoID`, i.e. for the create commands), or a bare `ok`. Pure so it can be
    /// unit-tested directly; `printResponse` routes it to stdout/stderr.
    static func formatResponse(_ response: ControlResponse, json: Bool, echoID: Bool = false) -> String {
        if json {
            if let data = try? JSONEncoder().encode(response), let line = String(data: data, encoding: .utf8) {
                return line
            }
            return ""
        }
        if !response.ok {
            return "error: " + (response.error ?? "unknown error")
        }
        if let tree = response.result?.tree {
            return formatTree(tree)
        }
        if let windows = response.result?.windows {
            return formatWindows(windows)
        }
        if let themes = response.result?.themes {
            return formatThemes(themes, current: response.result?.theme)
        }
        if let text = response.result?.text {
            return text
        }
        if let exitCode = response.result?.exitCode {
            return "exit \(exitCode)"
        }
        if let count = response.result?.count {
            // keymap.reload reports its parse-diagnostic count; 0 reads as a clean reload.
            return count == 0 ? "ok" : "\(count) diagnostic(s)"
        }
        if let ratio = response.result?.ratio {
            // session.resize echoes the applied (clamped) left-pane fraction, scriptable as a bare number.
            return String(format: "%.3f", ratio)
        }
        if echoID, let id = response.result?.id {
            return id
        }
        return "ok"
    }

    /// Render the `theme.list` payload as one theme name per line, the current theme marked with `* `
    /// and a leading "default ghostty" entry for the no-theme (ghostty built-in) case (no trailing newline).
    static func formatThemes(_ themes: [String], current: String?) -> String {
        func line(_ name: String?, _ label: String) -> String { (name == current ? "* " : "  ") + label }
        return ([line(nil, "default ghostty")] + themes.map { line($0, $0) }).joined(separator: "\n")
    }

    /// Render the `window.list` payload as one `id  name  [open]  [active]` line per window (no trailing
    /// newline). Closed/inactive windows still list, with the bracket tag absent.
    static func formatWindows(_ windows: [ControlWindowNode]) -> String {
        windows.map { window in
            let tags = (window.open ? " [open]" : "") + (window.active ? " [active]" : "")
            return "\(window.id)  \(window.name)\(tags)"
        }.joined(separator: "\n")
    }

    /// Render a tree as an indented workspace → session listing (no trailing newline).
    private static func formatTree(_ tree: ControlTree) -> String {
        var lines: [String] = []
        for workspace in tree.workspaces {
            let mark = workspace.active ? "*" : " "
            lines.append("\(mark) \(workspace.name)  [\(workspace.id)]")
            for session in workspace.sessions {
                let smark = session.active ? "*" : " "
                let tags = (session.split ? " (split)" : "") + (session.overlay ? " (overlay)" : "")
                    + (session.scratch ? " (scratch)" : "")
                let titleSuffix = session.title.map { "  title: \($0)" } ?? ""
                lines.append("  \(smark) \(session.name)\(tags)  [\(session.id)]  \(session.cwd)\(titleSuffix)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
