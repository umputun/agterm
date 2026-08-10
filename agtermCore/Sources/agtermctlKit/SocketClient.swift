#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
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
        var data = try JSONEncoder().encode(request)
        // the server rejects a request line over the shared cap (newline excluded, matching this count)
        // and closes the connection; check before writing so the caller gets this error instead of a
        // write failure against the closing peer.
        guard data.count <= ControlWire.maxRequestLineBytes else {
            throw SocketClientError(
                "request too large (\(data.count) bytes, cap \(ControlWire.maxRequestLineBytes)) — "
                    + "split the input into smaller requests")
        }
        data.append(UInt8(ascii: "\n"))

        let fd = try connect()
        defer { close(fd) }

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
        var addr = sockaddr_un()
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < pathCapacity else {
            throw SocketClientError("socket path too long (\(path.utf8.count) bytes): \(path)")
        }
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw SocketClientError("socket() failed: \(String(cString: strerror(errno)))") }

        // a write after the server closes the connection (e.g. it rejected an oversized request) would
        // raise the default-fatal SIGPIPE and kill the process with no output; SO_NOSIGPIPE turns it into
        // a normal EPIPE write error, mirroring the server side of the socket. Darwin-only — Glibc has no
        // SO_NOSIGPIPE.
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

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
                systemConnect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
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

    /// Render the immediate `pick.open` response as the documented `{"id":"…"}` JSON object.
    static func formatPickID(_ id: String) throws -> String {
        String(decoding: try JSONEncoder().encode(ControlResult(id: id)), as: UTF8.self)
    }

    /// Render the nested `pick.result` payload itself, rather than the enclosing control response.
    static func formatPickResult(_ result: ControlPickResult) throws -> String {
        String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }

    /// Map every picker state to a process status. `pending` is non-terminal in the blocking loop; if
    /// observed by the one-shot `pick result` verb it uses the generic failure status.
    static func pickExitCode(for outcome: ControlPickOutcome) -> ExitCode {
        switch outcome {
        case .picked, .custom: .success
        case .pending: .failure
        case .cancelled: ExitCode(rawValue: 2)
        }
    }

    /// Human choices may take minutes, so poll quickly only for the first second (ten 100 ms waits),
    /// then back off to 500 ms rather than hammering the server's serial accept loop indefinitely.
    static func pickPollDelay(afterPendingPoll poll: Int) -> TimeInterval {
        poll <= 10 ? 0.1 : 0.5
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
            return formatThemes(themes, current: response.result?.theme, sync: response.result?.sync ?? false,
                                light: response.result?.light, dark: response.result?.dark)
        }
        if let keymap = response.result?.keymap {
            return formatKeymap(keymap)
        }
        if let text = response.result?.text {
            return text
        }
        if let exitCode = response.result?.exitCode {
            return "exit \(exitCode)"
        }
        if let affected = response.result?.affected {
            return affected == 1 ? "1 session" : "\(affected) sessions"
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

    /// Render the `theme.list` payload as one theme name per line (no trailing newline), the active
    /// theme(s) marked `* `, with a leading "default ghostty" entry for the no-theme (ghostty built-in)
    /// case. With `sync` on, both the light and dark themes are marked under a header naming the
    /// appearance pair; otherwise the single `current` theme is marked.
    static func formatThemes(_ themes: [String], current: String?, sync: Bool = false,
                             light: String? = nil, dark: String? = nil) -> String {
        let active: (String?) -> Bool = sync ? { $0 != nil && ($0 == light || $0 == dark) } : { $0 == current }
        func line(_ name: String?, _ label: String) -> String { (active(name) ? "* " : "  ") + label }
        let body = ([line(nil, "default ghostty")] + themes.map { line($0, $0) }).joined(separator: "\n")
        guard sync else { return body }
        let header = "syncing with macOS appearance — light: \(light ?? "default ghostty"), dark: \(dark ?? "default ghostty")"
        return header + "\n" + body
    }

    /// Render the `keymap.list` payload as sections: the resolved built-ins, then custom commands, parse
    /// diagnostics, and the live menu key equivalents (no trailing newline). An overridden built-in is
    /// marked `*`, a keyless one prints `-` rather than being dropped, so the listing is the full action set.
    ///
    /// The menu section is the point of the command: comparing it against the actions above is what shows
    /// a chord the keymap resolved but the menu is not carrying. Menu items print in menu-bar order.
    static func formatKeymap(_ keymap: ControlKeymap) -> String {
        var lines = ["keymap: \(keymap.path)", "", "actions:"]
        let width = keymap.actions.map(\.action.count).max() ?? 0
        for action in keymap.actions {
            let mark = action.overridden == true ? "*" : " "
            let name = action.action.padding(toLength: max(width, action.action.count), withPad: " ", startingAt: 0)
            lines.append("  \(mark) \(name)  \(action.chord ?? "-")")
        }
        if !keymap.commands.isEmpty {
            lines.append(contentsOf: ["", "commands:"])
            lines.append(contentsOf: keymap.commands.map { "    \($0.name)  \($0.shortcut ?? "(palette only)")" })
        }
        if !keymap.diagnostics.isEmpty {
            lines.append(contentsOf: ["", "diagnostics:"])
            // line 0 is the whole-file / cross-section sentinel, not a real line — drop the number
            // rather than sending the reader looking for it, matching SettingsView.diagnosticLine.
            lines.append(contentsOf: keymap.diagnostics.map {
                $0.line > 0 ? "    line \($0.line): \($0.message)" : "    \($0.message)"
            })
        }
        if let menu = keymap.menu {
            lines.append(contentsOf: ["", "menu:"])
            // mark a disabled item: its chord is inert (AppKit consumes the key and fires nothing, not
            // even a same-chord sibling), and the default non-JSON output is the documented human
            // workflow — an unmarked row reads as a live binding.
            lines.append(contentsOf: menu.map {
                "    \($0.chord)  \($0.menu) ▸ \($0.title)" + ($0.enabled == false ? "  (disabled)" : "")
            })
        }
        return lines.joined(separator: "\n")
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
                // a hidden split still owns a live pane, so it needs a tag of its own: without one it
                // reads exactly like a session that has no split at all.
                let splitTag = session.split ? " (split)" : (session.hasSplit == true ? " (split hidden)" : "")
                // a session whose main pane has no terminal looks identical to a working one here, which is
                // the whole complaint in #416 — it is listed, named, and does nothing.
                let realizedTag = session.realized == false ? " (not realized)" : ""
                let tags = splitTag + realizedTag + (session.overlay ? " (overlay)" : "")
                    + (session.scratch ? " (scratch)" : "")
                let titleSuffix = session.title.map { "  title: \($0)" } ?? ""
                lines.append("  \(smark) \(session.name)\(tags)  [\(session.id)]  \(session.cwd)\(titleSuffix)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

private func systemConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, addr, len)
    #else
    return Glibc.connect(fd, addr, len)
    #endif
}
