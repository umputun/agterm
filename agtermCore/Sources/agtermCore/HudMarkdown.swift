import Foundation

/// HudMarkdown turns a markdown HUD message into logical rows: Foundation parses standard markdown, and this
/// walks the parsed block structure into prefixed rows of styled runs. Wrapping, clipping and SGR belong to
/// `HudLayout`, which consumes these rows.
enum HudMarkdown {
    struct Style: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
        static let strikethrough = Style(rawValue: 4)
        static let dim = Style(rawValue: 8)
    }

    struct Run: Equatable, Sendable {
        var text: String
        var style: Style
    }

    /// Line is one logical row. `lead` prefixes its first wrapped row (indent, quote bars, list marker) and `hang`
    /// every continuation, so wrapped list text hangs under the item rather than under the marker.
    struct Line: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case text
            /// rule is a thematic break, drawn across whatever width the row is laid out at.
            case rule
        }

        var lead: String
        var hang: String
        var runs: [Run]
        var kind: Kind = .text

        static let blank = Line(lead: "", hang: "", runs: [])
    }

    static let codeIndent = "  "
    static let quoteBar = "│ "
    static let bullet = "• "
    static let cellSeparator = " │ "
    static let tabWidth = 4

    /// lines parses `source` as standard markdown. Blocks are separated by one blank row, except blocks
    /// sharing a list, since the parser does not say whether a list was tight or loose.
    static func lines(_ source: String) -> [Line] {
        let text = source.precomposedStringWithCanonicalMapping
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return text.split(separator: "\n", omittingEmptySubsequences: false).map {
                Line(lead: "", hang: "", runs: [Run(text: sanitized(String($0)), style: [])])
            }
        }
        var walker = Walker()
        for run in parsed.runs {
            walker.add(Segment(text: String(parsed[run.range].characters),
                               inline: run.inlinePresentationIntent ?? []),
                       block: run.presentationIntent?.components ?? [])
        }
        return walker.finish()
    }

    /// sanitized replaces control characters the parser decoded from entities (`&#27;`, `&#10;`) so none can
    /// reach the terminal or split a row. A tab in running text becomes a space; code blocks expand theirs
    /// before this runs.
    static func sanitized(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09: out.append(" ")
            case 0..<0x20, 0x7f: out.append("\u{FFFD}")
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// expandTabs replaces tabs with spaces up to the next `tabWidth` stop, counted from the line start.
    static func expandTabs(_ line: String) -> String {
        var out = ""
        var column = 0
        for scalar in line.unicodeScalars {
            if scalar == "\t" {
                let pad = tabWidth - column % tabWidth
                out += String(repeating: " ", count: pad)
                column += pad
                continue
            }
            out.unicodeScalars.append(scalar)
            column += 1
        }
        return out
    }

    fileprivate struct Segment {
        let text: String
        let inline: InlinePresentationIntent
    }

    /// Block is one parsed block: consecutive runs sharing the innermost block identity.
    fileprivate struct Block {
        /// components run innermost first, as Foundation orders them.
        let components: [PresentationIntent.IntentType]
        var segments: [Segment]

        var kind: PresentationIntent.Kind? { components.first?.kind }

        var listIDs: Set<Int> {
            Set(components.compactMap { component in
                switch component.kind {
                case .orderedList, .unorderedList: return component.identity
                default: return nil
                }
            })
        }

        /// tableID is the enclosing table's identity when this block is a cell.
        var tableID: Int? {
            components.first { if case .table = $0.kind { return true } else { return false } }?.identity
        }

        /// tableColumns is the enclosing table's declared column count when this block is a cell.
        var tableColumns: Int {
            for component in components { if case .table(let columns) = component.kind { return columns.count } }
            return 0
        }
    }

    /// PendingTable collects a table's cells by position: Foundation emits no run for an empty cell, nor for
    /// a body row whose cells are all empty, so arrival order alone would shift later cells left.
    fileprivate struct PendingTable {
        let id: Int
        let first: Block
        let columns: Int
        var header: [Int: [Run]]?
        /// body rows keyed by the parser's 1-based row index, cells by column index
        var rows: [Int: [Int: [Run]]] = [:]

        var grid: [[[Run]]] {
            let last = rows.keys.max() ?? 0
            let body = last > 0 ? (1...last).map { rows[$0] ?? [:] } : []
            return ((header.map { [$0] } ?? []) + body).map { row in (0..<columns).map { row[$0] ?? [] } }
        }
    }

    fileprivate struct Walker {
        var out: [Line] = []
        var current: Block?
        var table: PendingTable?
        var seenItems: Set<Int> = []
        var lastListIDs: Set<Int>?

        mutating func add(_ segment: Segment, block components: [PresentationIntent.IntentType]) {
            // a run with no block intent (a raw HTML block) never merges with its neighbor
            let key = components.first?.identity
            if let current, key != nil, current.components.first?.identity == key {
                self.current?.segments.append(segment)
                return
            }
            flushBlock()
            current = Block(components: components, segments: [segment])
        }

        mutating func finish() -> [Line] {
            flushBlock()
            flushTable()
            return out
        }

        private mutating func flushBlock() {
            guard let block = current else { return }
            current = nil
            if case .tableCell = block.kind, let tableID = block.tableID {
                addCell(block, tableID: tableID)
                return
            }
            flushTable()
            emit(render(block), for: block)
        }

        private mutating func addCell(_ block: Block, tableID: Int) {
            if table?.id != tableID { flushTable() }
            guard case .tableCell(let column) = block.kind, let row = block.components.dropFirst().first else { return }
            var pending = table ?? PendingTable(id: tableID, first: block, columns: block.tableColumns)
            switch row.kind {
            case .tableHeaderRow:
                pending.header = (pending.header ?? [:]).merging([column: cellRuns(block, base: .bold)]) { $1 }
            case .tableRow(let index):
                pending.rows[index, default: [:]][column] = cellRuns(block, base: [])
            default:
                return
            }
            table = pending
        }

        private func cellRuns(_ block: Block, base: Style) -> [Run] {
            inlineRows(block.segments, base: base).flatMap { $0 }
        }

        private mutating func flushTable() {
            guard let pending = table else { return }
            table = nil
            let grid = pending.grid
            var widths = [Int](repeating: 0, count: pending.columns)
            for row in grid {
                for (index, cell) in row.enumerated() {
                    widths[index] = max(widths[index], cell.reduce(0) { $0 + HudLayout.cellCount($1.text) })
                }
            }
            let (lead, hang) = prefixes(pending.first.components.dropFirst(3))
            let lines = grid.enumerated().map { offset, row -> Line in
                var runs: [Run] = []
                for (index, cell) in row.enumerated() {
                    if index > 0 { runs.append(Run(text: HudMarkdown.cellSeparator, style: [])) }
                    runs += cell
                    let pad = widths[index] - cell.reduce(0) { $0 + HudLayout.cellCount($1.text) }
                    if pad > 0, index < row.count - 1 { runs.append(Run(text: String(repeating: " ", count: pad), style: [])) }
                }
                return Line(lead: offset == 0 ? lead : hang, hang: hang, runs: runs)
            }
            emit(lines, for: pending.first)
        }

        private mutating func emit(_ lines: [Line], for block: Block) {
            guard !lines.isEmpty else { return }
            let listIDs = block.listIDs
            if let last = lastListIDs, last.isDisjoint(with: listIDs) || listIDs.isEmpty {
                out.append(.blank)
            }
            lastListIDs = listIDs
            out += lines
        }

        private mutating func render(_ block: Block) -> [Line] {
            let (lead, hang) = prefixes(block.components.dropFirst())
            switch block.kind {
            case .codeBlock:
                var body = block.segments.map(\.text).joined().split(separator: "\n", omittingEmptySubsequences: false)
                if body.last?.isEmpty == true { body.removeLast() }
                return body.enumerated().map { index, raw in
                    Line(lead: (index == 0 ? lead : hang) + HudMarkdown.codeIndent, hang: hang + HudMarkdown.codeIndent,
                         runs: [Run(text: sanitized(expandTabs(String(raw))), style: [])])
                }
            case .thematicBreak:
                return [Line(lead: lead, hang: hang, runs: [], kind: .rule)]
            case .header:
                return textLines(inlineRows(block.segments, base: .bold), lead: lead, hang: hang)
            case nil:
                // a raw HTML block: its source, one row per line
                var body = block.segments.map(\.text).joined().split(separator: "\n", omittingEmptySubsequences: false)
                while body.last?.isEmpty == true { body.removeLast() }
                return textLines(body.map { [Run(text: sanitized(String($0)), style: [])] }, lead: lead, hang: hang)
            default:
                return textLines(inlineRows(block.segments, base: []), lead: lead, hang: hang)
            }
        }

        private func textLines(_ rows: [[Run]], lead: String, hang: String) -> [Line] {
            rows.enumerated().map { Line(lead: $0.offset == 0 ? lead : hang, hang: hang, runs: $0.element) }
        }

        /// inlineRows maps inline intents onto styles and splits at hard breaks; a soft break is a space.
        private func inlineRows(_ segments: [Segment], base: Style) -> [[Run]] {
            var rows: [[Run]] = [[]]
            for segment in segments {
                if segment.inline.contains(.lineBreak) {
                    rows.append([])
                    continue
                }
                var style = base
                if segment.inline.contains(.stronglyEmphasized) { style.insert(.bold) }
                if segment.inline.contains(.emphasized) { style.insert(.italic) }
                if segment.inline.contains(.strikethrough) { style.insert(.strikethrough) }
                let text = segment.inline.contains(.softBreak) ? " " : sanitized(segment.text)
                rows[rows.count - 1].append(Run(text: text, style: style))
            }
            return rows
        }

        /// prefixes walks the containers outermost first: a quote adds a bar to both prefixes, and a list
        /// item adds its marker to `lead` only for the item's first block, spaces of the same width otherwise.
        private mutating func prefixes(_ containers: ArraySlice<PresentationIntent.IntentType>) -> (String, String) {
            var lead = ""
            var hang = ""
            var ordered = false
            for component in containers.reversed() {
                switch component.kind {
                case .blockQuote:
                    lead += HudMarkdown.quoteBar
                    hang += HudMarkdown.quoteBar
                case .orderedList:
                    ordered = true
                case .unorderedList:
                    ordered = false
                case .listItem(let ordinal):
                    let marker = ordered ? "\(ordinal). " : HudMarkdown.bullet
                    let pad = String(repeating: " ", count: HudLayout.cellCount(marker))
                    lead += seenItems.insert(component.identity).inserted ? marker : pad
                    hang += pad
                default:
                    break
                }
            }
            return (lead, hang)
        }
    }
}
