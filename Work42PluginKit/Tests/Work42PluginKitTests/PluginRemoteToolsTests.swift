import Foundation
import Testing
@testable import Work42PluginKit

@Suite("Plugin tools over the link")
struct PluginRemoteToolsTests {

    @Test("a host with no paired Mac refuses the call with a named error")
    func unsupportedByDefault() async {
        let service: any WidgetPluginToolService = UnsupportedWidgetCapability()
        await #expect(throws: WidgetServiceError.self) {
            _ = try await service.call(mcp: "mail", tool: "search_messages")
        }
    }

    @Test("an outcome carries a result or the tool's own failure, and nothing else is an answer")
    func outcome() throws {
        let ok = PluginToolOutcomeWire(result: .text("done"))
        #expect(try ok.unwrapped().content.first?.text == "done")

        let failed = PluginToolOutcomeWire(failure: PluginToolFailure(code: "not_found", message: "no", suggestion: "look again"))
        do {
            _ = try failed.unwrapped()
            Issue.record("a failed outcome unwrapped")
        } catch let failure as PluginToolFailure {
            #expect(failure.code == "not_found" && failure.suggestion == "look again")
        }
        #expect(throws: PluginToolFailure.self) { try PluginToolOutcomeWire().unwrapped() }
    }

    @Test("an outcome survives the wire")
    func roundTrip() throws {
        let wire = PluginToolOutcomeWire(result: try .structured(["a": 1]))
        let back = try JSONDecoder().decode(PluginToolOutcomeWire.self, from: JSONEncoder().encode(wire))
        #expect(back == wire)
    }
}
