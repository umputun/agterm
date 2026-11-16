import Foundation

/// JSONLines lays out a JSON Lines file for reading: each line holding a JSON object or array is spread over
/// indented rows built from its own tokens, so key order, duplicate keys, escapes and number literals are kept.
enum JSONLines {
    /// Formatted is the laid-out text and, for each source line from 0, the formatted line it starts on, then the
    /// formatted line count, so a gutter numbers source lines.
    struct Formatted: Equatable {
        let text: String
        let starts: [Int]
    }

    /// format lays out `text` within `budget` UTF-8 bytes. A line that is not an object or array, fails to parse,
    /// or would overrun the budget stays as written; the budget reserves room for the raw lines still to come.
    /// CR and CRLF end a line, as they do on any text page.
    static func format(_ text: String, budget: Int) -> Formatted {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = Array(normalized.utf8).split(separator: 0x0A, omittingEmptySubsequences: false)
        let trailing = lines.count > 1 && lines.last?.isEmpty == true
        if trailing { lines.removeLast() }
        var out: [UInt8] = []
        out.reserveCapacity(normalized.utf8.count)
        var starts: [Int] = []
        starts.reserveCapacity(lines.count + 1)
        var row = 0
        var rest = normalized.utf8.count
        for (index, line) in lines.enumerated() {
            starts.append(row)
            let separator = index < lines.count - 1 || trailing ? 1 : 0
            rest -= line.count + separator
            if let laid = laidOut(line, limit: budget - out.count - rest - separator) {
                out += laid.bytes
                row += laid.rows
            } else {
                out += line
                row += 1
            }
            if separator == 1 { out.append(0x0A) }
        }
        starts.append(row)
        return Formatted(text: String(decoding: out, as: UTF8.self), starts: starts)
    }

    // the reindent walks tokens only after JSONSerialization accepted the line, so brackets and strings are balanced;
    // nil once the output passes `limit`, checked as it grows rather than after
    private static func laidOut(_ line: ArraySlice<UInt8>, limit: Int) -> (bytes: [UInt8], rows: Int)? {
        guard let first = line.first(where: { !isSpace($0) }), first == 0x7B || first == 0x5B,
              (try? JSONSerialization.jsonObject(with: Data(line))) != nil else { return nil }
        var out: [UInt8] = []
        var rows = 1
        var depth = 0
        var inString = false
        var escaped = false
        let newline = {
            out.append(0x0A)
            out += repeatElement(0x20, count: depth * 2)
            rows += 1
        }
        var index = line.startIndex
        while index < line.endIndex {
            let byte = line[index]
            index += 1
            if inString {
                out.append(byte)
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case _ where isSpace(byte):
                continue
            case 0x22:
                inString = true
                out.append(byte)
            case 0x7B, 0x5B:
                out.append(byte)
                let close: UInt8 = byte == 0x7B ? 0x7D : 0x5D
                if let next = line[index...].firstIndex(where: { !isSpace($0) }), line[next] == close {
                    out.append(close)
                    index = next + 1
                } else {
                    depth += 1
                    newline()
                }
            case 0x7D, 0x5D:
                depth -= 1
                newline()
                out.append(byte)
            case 0x2C:
                // reject the trailing comma JSONSerialization accepts
                if let next = line[index...].first(where: { !isSpace($0) }), next == 0x7D || next == 0x5D { return nil }
                out.append(byte)
                newline()
            case 0x3A:
                out += [0x3A, 0x20]
            default:
                out.append(byte)
            }
            if out.count > limit { return nil }
        }
        return out.count > limit ? nil : (out, rows)
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
