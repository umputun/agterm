import Foundation
import Testing
@testable import agtermCore

struct ControlPickTests {
    @Test func statusRoundTripsAndOmitsWhenNil() throws {
        let item = ControlPickItem(id: "s1", label: "build", status: "blocked", statusColor: "#ff8800", statusShape: "star")
        let plain = String(decoding: try JSONEncoder().encode(ControlPickItem(id: "a", label: "A")), as: UTF8.self)

        #expect(try JSONDecoder().decode(ControlPickItem.self, from: JSONEncoder().encode(item)) == item)
        #expect(!plain.contains("status"), "nil status fields must be omitted from the JSON; got \(plain)")
        #expect(try JSONDecoder().decode(ControlPickItem.self, from: Data(#"{"id":"a","label":"A"}"#.utf8))
            == ControlPickItem(id: "a", label: "A"))
    }

    @Test(arguments: [
        (ControlPickItem(id: "a", label: "A", status: "completed", statusColor: "#112233", statusShape: "diamond"),
         AgentIndicator(status: .completed, color: "#112233", shape: .diamond)),
        (ControlPickItem(id: "a", label: "A", status: "active", statusShape: "hexagon"), AgentIndicator(status: .active)),
        (ControlPickItem(id: "a", label: "A", status: "idle", statusColor: "#112233"), AgentIndicator()),
        (ControlPickItem(id: "a", label: "A", status: "busy", statusShape: "star"), AgentIndicator()),
        (ControlPickItem(id: "a", label: "A"), AgentIndicator()),
    ])
    func indicatorDropsWhatCannotRender(item: ControlPickItem, expected: AgentIndicator) {
        #expect(item.indicator == expected)
    }
}
