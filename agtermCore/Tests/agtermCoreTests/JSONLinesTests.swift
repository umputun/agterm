import Testing
@testable import agtermCore

struct JSONLinesTests {
    @Test func aRecordIsLaidOutFromItsOwnTokens() {
        let formatted = JSONLines.format(#"{"b":1,"2":12345678901234567890,"b":1.50e3,"s":"a\"b,{c}:"}"#, budget: 1 << 20)

        #expect(formatted.text == """
        {
          "b": 1,
          "2": 12345678901234567890,
          "b": 1.50e3,
          "s": "a\\"b,{c}:"
        }
        """)
        #expect(formatted.starts == [0, 6])
    }

    @Test func nestedContainersIndentAndEmptyOnesStayClosed() {
        let formatted = JSONLines.format(#"[ {"a": [1, 2], "e": { }, "l": [ ]}, null ]"#, budget: 1 << 20)

        #expect(formatted.text == """
        [
          {
            "a": [
              1,
              2
            ],
            "e": {},
            "l": []
          },
          null
        ]
        """)
        #expect(formatted.starts == [0, 11])
    }

    @Test func eachSourceLineKeepsItsOwnSlot() {
        let text = "{\"a\":1}\n\nnot json\n42\n{\"b\":[]}\n"
        let formatted = JSONLines.format(text, budget: 1 << 20)

        #expect(formatted.text == "{\n  \"a\": 1\n}\n\nnot json\n42\n{\n  \"b\": []\n}\n")
        #expect(formatted.starts == [0, 3, 4, 5, 6, 9])
    }

    @Test(arguments: ["{\"a\":1}\r\n{\"b\":2}", "{\"a\":1}\r{\"b\":2}"])
    func carriageReturnsEndLines(text: String) {
        let formatted = JSONLines.format(text, budget: 1 << 20)

        #expect(formatted.text == "{\n  \"a\": 1\n}\n{\n  \"b\": 2\n}")
        #expect(formatted.starts == [0, 3, 6])
    }

    @Test(arguments: ["{\"a\":1", "{\"a\":1}x", "[1,]", "{\"a\":1 , }", "{a:1}"])
    func anInvalidRecordStaysAsWritten(line: String) {
        let formatted = JSONLines.format(line, budget: 1 << 20)

        #expect(formatted.text == line)
        #expect(formatted.starts == [0, 1])
    }

    @Test func anEmptyFileIsOneSlot() {
        #expect(JSONLines.format("", budget: 10) == JSONLines.Formatted(text: "", starts: [0, 1]))
    }

    @Test func theBudgetReservesRoomForTheRawLinesAfter() {
        let first = #"{"a":1,"b":2}"#
        let second = #"{"c":3}"#
        let text = "\(first)\n\(second)"
        let laidFirst = "{\n  \"a\": 1,\n  \"b\": 2\n}"
        let fits = laidFirst.utf8.count + 1 + second.utf8.count

        #expect(JSONLines.format(text, budget: fits).text == "\(laidFirst)\n\(second)")
        #expect(JSONLines.format(text, budget: fits - 1).text == "\(first)\n{\n  \"c\": 3\n}")
        #expect(JSONLines.format(text, budget: fits - 1).starts == [0, 1, 4])
    }

    @Test func noOutputPassesTheBudget() {
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        let text = Array(repeating: deep, count: 20).joined(separator: "\n")
        let laid = JSONLines.format(deep, budget: .max)
        let budget = text.utf8.count + 2 * (laid.text.utf8.count - deep.utf8.count) + 10

        let formatted = JSONLines.format(text, budget: budget)

        #expect(formatted.text.utf8.count <= budget)
        #expect(laid.starts == [0, 399])
        #expect(Array(formatted.starts.prefix(4)) == [0, 399, 798, 799])
        #expect(formatted.starts.last == 816)
    }
}
