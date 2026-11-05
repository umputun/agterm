import Foundation
import Testing
@testable import agtermCore

struct LogTailTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let bytes: [UInt8]
        let fromFileStart: Bool
        let maxLines: Int
        let expected: LogTail.Snapshot?

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "whole file", bytes: Array("a\nb\n".utf8), fromFileStart: true, maxLines: 10,
             expected: .init(text: "a\nb\n", lines: 2, clipped: false)),
        Case(name: "partial first line dropped", bytes: Array("xx\na\nb\n".utf8), fromFileStart: false, maxLines: 10,
             expected: .init(text: "a\nb\n", lines: 2, clipped: false)),
        Case(name: "window starting on a line boundary keeps that line", bytes: Array("\na\nb\n".utf8), fromFileStart: false,
             maxLines: 10, expected: .init(text: "a\nb\n", lines: 2, clipped: false)),
        Case(name: "no LF in the window keeps the clipped line", bytes: Array("tail of a line".utf8), fromFileStart: false,
             maxLines: 10, expected: .init(text: "tail of a line", lines: 1, clipped: true)),
        Case(name: "line longer than the window ending in LF at its last byte", bytes: Array("end of a long line\n".utf8),
             fromFileStart: false, maxLines: 10, expected: .init(text: "end of a long line\n", lines: 1, clipped: true)),
        Case(name: "clipped line starts at a whole character", bytes: [0xA9] + Array("é line".utf8), fromFileStart: false,
             maxLines: 10, expected: .init(text: "é line", lines: 1, clipped: true)),
        Case(name: "trailing partial character left for the next read", bytes: Array("a\nb".utf8) + [0xC3], fromFileStart: true,
             maxLines: 10, expected: .init(text: "a\nb", lines: 2, clipped: false)),
        Case(name: "trailing partial four-byte character", bytes: Array("a\n".utf8) + [0xF0, 0x9F, 0x98], fromFileStart: true,
             maxLines: 10, expected: .init(text: "a\n", lines: 1, clipped: false)),
        Case(name: "trailing partial three-byte character", bytes: Array("a\n".utf8) + [0xE2, 0x82], fromFileStart: true,
             maxLines: 10, expected: .init(text: "a\n", lines: 1, clipped: false)),
        Case(name: "trailing C0 never starts a character", bytes: [0x61, 0xC0], fromFileStart: true, maxLines: 10, expected: nil),
        Case(name: "trailing F5 never starts a character", bytes: [0x61, 0xF5, 0x80], fromFileStart: true, maxLines: 10,
             expected: nil),
        Case(name: "trailing E0 80 is already invalid", bytes: [0x61, 0xE0, 0x80], fromFileStart: true, maxLines: 10,
             expected: nil),
        Case(name: "trailing ED A0 is a surrogate", bytes: [0x61, 0xED, 0xA0], fromFileStart: true, maxLines: 10, expected: nil),
        Case(name: "trailing F4 90 is past the last scalar", bytes: [0x61, 0xF4, 0x90], fromFileStart: true, maxLines: 10,
             expected: nil),
        Case(name: "final line without LF counts", bytes: Array("a\nb".utf8), fromFileStart: true, maxLines: 10,
             expected: .init(text: "a\nb", lines: 2, clipped: false)),
        Case(name: "only the last maxLines lines", bytes: Array("1\n2\n3\n4\n".utf8), fromFileStart: true, maxLines: 2,
             expected: .init(text: "3\n4\n", lines: 2, clipped: false)),
        Case(name: "CRLF counts the same lines and keeps the CR", bytes: Array("a\r\nb\r\n".utf8), fromFileStart: true,
             maxLines: 10, expected: .init(text: "a\r\nb\r\n", lines: 2, clipped: false)),
        Case(name: "empty data", bytes: [], fromFileStart: false, maxLines: 10, expected: .init(text: "", lines: 0, clipped: false)),
        Case(name: "NUL in a dropped line is not binary", bytes: Array("a\u{0}b\n".utf8) + Array("c\nd\n".utf8),
             fromFileStart: true, maxLines: 2, expected: .init(text: "c\nd\n", lines: 2, clipped: false)),
        Case(name: "truncation hole ahead of the first line is dropped", bytes: [0, 0, 0] + Array("new\n".utf8),
             fromFileStart: true, maxLines: 10, expected: .init(text: "new\n", lines: 1, clipped: false)),
        Case(name: "a window of nothing but NUL stays binary", bytes: [0, 0, 0, 0], fromFileStart: true, maxLines: 10, expected: nil),
        Case(name: "a hole followed only by more NUL after a line feed stays binary", bytes: [0, 0] + Array("\n".utf8) + [0],
             fromFileStart: true, maxLines: 10, expected: nil),
        Case(name: "a NUL inside a kept line stays binary", bytes: Array("ok\nbad\u{0}line\n".utf8), fromFileStart: true,
             maxLines: 10, expected: nil),
        Case(name: "NUL marks binary", bytes: Array("a\n".utf8) + [0] + Array("b\n".utf8), fromFileStart: true, maxLines: 10,
             expected: nil),
        Case(name: "invalid UTF-8 marks binary", bytes: Array("a\n".utf8) + [0xFF, 0xFE] + Array("b\n".utf8), fromFileStart: true,
             maxLines: 10, expected: nil),
    ]

    @Test(arguments: cases)
    func snapshotKeepsTheLastWholeLines(_ testCase: Case) {
        let snapshot = LogTail.snapshot(Data(testCase.bytes), offset: testCase.fromFileStart ? 0 : 100, maxLines: testCase.maxLines)

        #expect(snapshot.map { LogTail.Snapshot(text: $0.text, lines: $0.lines, clipped: $0.clipped) } == testCase.expected)
    }

    struct OffsetCase: Sendable, CustomTestStringConvertible {
        let name: String
        let bytes: [UInt8]
        let offset: Int
        let maxLines: Int
        let start: Int

        var testDescription: String { name }
    }

    static let offsetCases: [OffsetCase] = [
        OffsetCase(name: "whole file starts at zero", bytes: Array("a\nb\n".utf8), offset: 0, maxLines: 10, start: 0),
        OffsetCase(name: "the partial first line is past the start", bytes: Array("xx\na\nb\n".utf8), offset: 40, maxLines: 10, start: 43),
        OffsetCase(name: "a window on a line boundary starts after the byte before it", bytes: Array("\na\n".utf8), offset: 40,
                   maxLines: 10, start: 41),
        OffsetCase(name: "the line cap moves the start", bytes: Array("1\n2\n3\n".utf8), offset: 0, maxLines: 1, start: 4),
        OffsetCase(name: "a clipped line starts at its first whole character", bytes: [0xA9] + Array("é line".utf8), offset: 40,
                   maxLines: 10, start: 41),
        OffsetCase(name: "a trimmed unfinished character leaves the start alone", bytes: Array("xx\na\nb".utf8) + [0xC3], offset: 40,
                   maxLines: 10, start: 43),
        OffsetCase(name: "a dropped NUL hole moves the start", bytes: [0, 0] + Array("new\n".utf8), offset: 0, maxLines: 10, start: 2),
    ]

    @Test(arguments: offsetCases)
    func startOffsetIsTheFilePositionOfTheFirstShownByte(_ testCase: OffsetCase) throws {
        let snapshot = try #require(LogTail.snapshot(Data(testCase.bytes), offset: testCase.offset, maxLines: testCase.maxLines))

        #expect(snapshot.startOffset == testCase.start)
    }
}
