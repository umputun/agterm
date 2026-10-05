import Foundation

/// RemoteEntry is one `destination [label...]` line of `remotes.conf`. The destination is the entry's
/// identity; the label equals it when the line gives none.
public struct RemoteEntry: Equatable, Sendable {
    public let destination: String
    public let label: String
    public let line: Int

    public init(destination: String, label: String, line: Int) {
        self.destination = destination
        self.label = label
        self.line = line
    }
}

/// Remotes is the parsed `remotes.conf`, entries in file order.
public struct Remotes: Equatable, Sendable {
    public let entries: [RemoteEntry]

    public init(entries: [RemoteEntry] = []) {
        self.entries = entries
    }
}

/// parseRemotesConf reads `remotes.conf`. Only a whole-line `#` is a comment: the rest of a line after
/// the destination is the label verbatim. A bad line is diagnosed and skipped; later lines still parse.
public func parseRemotesConf(_ text: String) -> (remotes: Remotes, diagnostics: [KeymapDiagnostic]) {
    var entries: [RemoteEntry] = []
    var seen: Set<String> = []
    var diagnostics: [KeymapDiagnostic] = []

    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    for (index, rawLine) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let lineNumber = index + 1
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }

        let destination = String(line.prefix(while: { !$0.isWhitespace }))
        guard RemoteSession.isHost(destination) else {
            diagnostics.append(KeymapDiagnostic(line: lineNumber, message: "invalid destination; remote skipped"))
            continue
        }
        let rest = line.dropFirst(destination.count).trimmingCharacters(in: .whitespaces)
        // a label reaches a terminal through `agtermctl zmx remotes`
        guard !rest.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7f }) else {
            diagnostics.append(KeymapDiagnostic(
                line: lineNumber, message: "label for '\(destination)' has control characters; remote skipped"))
            continue
        }
        guard seen.insert(destination).inserted else {
            diagnostics.append(KeymapDiagnostic(
                line: lineNumber, message: "remote '\(destination)' is already defined; remote skipped"))
            continue
        }
        entries.append(RemoteEntry(destination: destination, label: rest.isEmpty ? destination : rest, line: lineNumber))
    }
    return (Remotes(entries: entries), diagnostics)
}
