import Foundation
import Testing
@testable import Work42UI

struct Work42YAMLTests {
    struct Sample: Codable, Equatable {
        var name: String
        var count: Int
        var tags: [String]
    }

    @Test func roundTripsACodableValue() throws {
        let original = Sample(name: "plugin", count: 3, tags: ["a", "b"])
        let yaml = try Work42YAML.encode(original)
        #expect(yaml.contains("name: plugin"))
        #expect(try Work42YAML.decode(Sample.self, from: yaml) == original)
    }

    @Test func loadReturnsUntypedMapping() throws {
        let parsed = try Work42YAML.load("title: hi\nitems:\n  - 1\n  - 2\n") as? [String: Any]
        #expect(parsed?["title"] as? String == "hi")
        #expect((parsed?["items"] as? [Int]) == [1, 2])
    }

    @Test func decodeThrowsOnTypeMismatch() {
        #expect(throws: (any Error).self) {
            try Work42YAML.decode(Sample.self, from: "name: x\ncount: not-a-number\ntags: []\n")
        }
    }
}
