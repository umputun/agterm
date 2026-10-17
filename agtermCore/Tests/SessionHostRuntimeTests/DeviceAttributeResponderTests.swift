import Testing
@testable import SessionHostRuntime

struct DeviceAttributeResponderTests {
    private let queries = ["\u{1B}[c", "\u{1B}[0c", "\u{1B}[>c", "\u{1B}[>0c"]
    private let primary = Array("\u{1B}[?62;22c".utf8)
    private let secondary = Array("\u{1B}[>1;10;0c".utf8)

    @Test func completeQueriesAndEveryTwoChunkSplit() {
        for (index, query) in queries.enumerated() {
            let bytes = Array(query.utf8)
            let expected = index < 2 ? primary : secondary
            var complete = DeviceAttributeResponder()
            #expect(bytes.withUnsafeBufferPointer { complete.feed($0) } == expected)
            #expect([UInt8]().withUnsafeBufferPointer { complete.feed($0) }.isEmpty)
            for split in 1..<bytes.count {
                var responder = DeviceAttributeResponder()
                #expect(Array(bytes[..<split]).withUnsafeBufferPointer { responder.feed($0) }.isEmpty)
                #expect([UInt8]().withUnsafeBufferPointer { responder.feed($0) }.isEmpty)
                #expect(Array(bytes[split...]).withUnsafeBufferPointer { responder.feed($0) } == expected)
                #expect(Array("c".utf8).withUnsafeBufferPointer { responder.feed($0) }.isEmpty)
            }
        }
    }

    @Test func singleBytesAndAdjacentMixedQueries() {
        var responder = DeviceAttributeResponder()
        var replies: [UInt8] = []
        for (index, query) in queries.enumerated() {
            let bytes = Array(query.utf8)
            for (offset, byte) in bytes.enumerated() {
                let reply = [byte].withUnsafeBufferPointer { responder.feed($0) }
                #expect(reply == (offset == bytes.count - 1 ? (index < 2 ? primary : secondary) : []))
                replies += reply
            }
        }
        let expected = primary + primary + secondary + secondary
        #expect(replies == expected)
        #expect(Array(queries.joined().utf8).withUnsafeBufferPointer { responder.feed($0) } == expected)
        let chunks = ["\u{1B}[", "c\u{1B}", "[>", "0", "c\u{1B}[0", "c"]
        #expect(chunks.flatMap { Array($0.utf8).withUnsafeBufferPointer { responder.feed($0) } } == primary + secondary + primary)
    }

    @Test func invalidPrefixesResponsesAndUnrelatedSequences() {
        let ignored = ["\u{1B}[?62;22c", "\u{1B}[>1;10;0c", "\u{1B}[>0q", "\u{1B}]0;title\u{07}",
                       "\u{1B}]2;title\u{1B}\\", "\u{1B}[6n", "\u{1B}[00c", "\u{1B}[>00c", "\u{1B}[1c"]
        for input in ignored {
            var responder = DeviceAttributeResponder()
            #expect(Array(input.utf8).withUnsafeBufferPointer { responder.feed($0) }.isEmpty)
            #expect(Array(queries[0].utf8).withUnsafeBufferPointer { responder.feed($0) } == primary)
        }
        for prefix in ["\u{1B}", "\u{1B}[", "\u{1B}[0", "\u{1B}[>", "\u{1B}[>0"] {
            var responder = DeviceAttributeResponder()
            #expect(Array(prefix.utf8).withUnsafeBufferPointer { responder.feed($0) }.isEmpty)
            #expect([UInt8(0xFF)].withUnsafeBufferPointer { responder.feed($0) }.isEmpty)
            #expect(Array((prefix + "x" + queries[2]).utf8).withUnsafeBufferPointer { responder.feed($0) } == secondary)
        }
        var responder = DeviceAttributeResponder()
        #expect([0, 255, 27, 27, 91, 27, 91, 99].withUnsafeBufferPointer { responder.feed($0) } == primary)
    }

    @Test func garbageCannotGrowRetainedState() {
        var responder = DeviceAttributeResponder()
        let garbage = Array(repeating: UInt8(0xFF), count: 1_000_000) + [27, 91, 62, 48]
        #expect(garbage.withUnsafeBufferPointer { responder.feed($0) }.isEmpty)
        #expect(MemoryLayout<DeviceAttributeResponder>.size <= 4)
        #expect([UInt8(99)].withUnsafeBufferPointer { responder.feed($0) } == secondary)
        #expect([UInt8(99)].withUnsafeBufferPointer { responder.feed($0) }.isEmpty)
    }
}
