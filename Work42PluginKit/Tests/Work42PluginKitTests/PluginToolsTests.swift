// PluginToolsTests.swift — declaring MCP tools: the input schema, arguments, results and failures (SDK 3.5.0, WOR-894).

import Foundation
import Testing

@testable import Work42PluginKit

@Suite("Plugin tool declarations")
struct PluginToolsTests {

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try #require(JSONSerialization.jsonObject(with: try encoder.encode(value)) as? [String: Any])
    }

    // MARK: Schema

    @Test("an object schema is the JSON schema MCP expects; every property is required unless marked optional")
    func schemaShape() throws {
        let schema = PluginToolSchema.object([
            "query": .string("What to search for"),
            "limit": .integer("At most this many").optional,
            "since": .dateTime("From when"),
            "folder": .oneOf(["inbox", "sent"], "Which folder"),
        ])
        #expect(schema.type == "object" && schema.required == ["folder", "query", "since"])

        let object = try json(schema)
        #expect(object["type"] as? String == "object")
        #expect(object["required"] as? [String] == ["folder", "query", "since"])
        let properties = try #require(object["properties"] as? [String: [String: Any]])
        #expect(properties["query"]?["type"] as? String == "string" && properties["query"]?["description"] as? String == "What to search for")
        #expect(properties["limit"]?["type"] as? String == "integer")
        #expect(properties["since"]?["format"] as? String == "date-time")
        #expect(properties["folder"]?["enum"] as? [String] == ["inbox", "sent"])
        #expect(properties["query"]?["isRequired"] == nil && properties["query"]?["choices"] == nil, "only schema keys are written")
    }

    @Test("a schema round-trips through JSON, and an empty one is an object with no properties")
    func schemaRoundTrips() throws {
        let schema = PluginToolSchema.object(["query": .string("q"), "limit": .integer("n").optional])
        let again = try JSONDecoder().decode(PluginToolSchema.self, from: try JSONEncoder().encode(schema))
        #expect(again.type == "object" && again.required == ["query"] && again.properties.keys.sorted() == ["limit", "query"])
        let empty = try json(PluginToolSchema.object([:]))
        #expect(empty["type"] as? String == "object" && (empty["properties"] as? [String: Any])?.isEmpty == true)
        #expect((empty["required"] as? [String])?.isEmpty == true)
    }

    @Test("arguments are checked against the schema: missing, unknown, wrong type, not whole, not a choice")
    func validation() {
        let schema = PluginToolSchema.object([
            "query": .string("q"), "limit": .integer("n").optional, "ratio": .number("r").optional, "all": .boolean("b").optional,
            "folder": .oneOf(["inbox", "sent"], "f").optional,
        ])
        #expect(schema.problem(with: ["query": .string("a")]) == nil)
        #expect(schema.problem(with: ["query": .string("a"), "limit": .number(3), "ratio": .number(0.5), "all": .bool(true),
                                      "folder": .string("sent")]) == nil)
        #expect(schema.problem(with: [:]) == "'query' is required")
        #expect(schema.problem(with: ["query": .null]) == "'query' is required")
        #expect(schema.problem(with: ["query": .string("a"), "zzz": .string("x")]) == "'zzz' is not an argument of this tool")
        #expect(schema.problem(with: ["query": .number(1)]) == "'query' must be a string")
        #expect(schema.problem(with: ["query": .string("a"), "limit": .number(1.5)]) == "'limit' must be a whole number")
        #expect(schema.problem(with: ["query": .string("a"), "all": .string("yes")]) == "'all' must be a boolean")
        #expect(schema.problem(with: ["query": .string("a"), "folder": .string("trash")]) == "'folder' must be one of: inbox, sent")
        #expect(schema.problem(with: ["query": .string("a"), "limit": .null]) == nil, "an explicit null is the same as leaving it out")
    }

    // MARK: Arguments

    @Test("argument readers return typed values and fail with a named error when one is missing or the wrong type")
    func readers() throws {
        let args = PluginToolArguments(["q": .string("alex"), "n": .number(7), "x": .number(7.5), "on": .bool(true),
                                        "when": .string("2026-11-26T10:30:00Z"), "nothing": .null])
        #expect(try args.string("q") == "alex" && (try args.int("n")) == 7 && (try args.double("x")) == 7.5)
        #expect(try args.bool("on") && (try args.optionalString("nothing")) == nil && (try args.optionalInt("absent")) == nil)
        #expect(try args.string("absent", default: "fallback") == "fallback")
        #expect(try args.date("when") == ISO8601DateFormatter().date(from: "2026-11-26T10:30:00Z"))

        for read in [{ _ = try args.string("n") }, { _ = try args.int("x") }, { _ = try args.bool("q") }, { _ = try args.date("q") },
                     { _ = try args.string("absent") }] {
            do { try read(); Issue.record("did not throw") } catch let failure as PluginToolFailure {
                #expect(failure.code == "invalid_arguments" && failure.suggestion != nil)
            } catch { Issue.record("\(error)") }
        }
    }

    @Test("a date with fractional seconds reads too")
    func fractionalDate() throws {
        let args = PluginToolArguments(["when": .string("2026-11-26T10:30:00.250Z")])
        #expect(try args.date("when").timeIntervalSince1970.truncatingRemainder(dividingBy: 1) == 0.25)
    }

    // MARK: Results and failures

    @Test("a structured result carries the JSON and its text, and a text result has no structure")
    func results() throws {
        struct Hit: Encodable { let id: Int; let subject: String }
        let result = try PluginToolResult.structured([Hit(id: 1, subject: "Hi")])
        #expect(result.structured == .array([.object(["id": .number(1), "subject": .string("Hi")])]))
        #expect(result.content.count == 1 && result.content[0].type == "text" && result.content[0].text.contains("\"subject\":\"Hi\""))
        #expect(PluginToolResult.text("done") == PluginToolResult(content: [PluginToolContent(text: "done")]))
        #expect(PluginToolResult.text("done").structured == nil)
    }

    @Test("a failure round-trips, keeps its optional parts absent, and reads as its message")
    func failures() throws {
        let failure = PluginToolFailure(code: "not_found", message: "no such message", suggestion: "search first")
        #expect(try JSONDecoder().decode(PluginToolFailure.self, from: try JSONEncoder().encode(failure)) == failure)
        let bare = try json(PluginToolFailure(code: "x", message: "m"))
        #expect(bare["suggestion"] == nil && bare["details"] == nil)
        #expect(failure.localizedDescription == "no such message")
        #expect(PluginToolFailure.cancelled.code == "cancelled")
    }

    // MARK: Declaring

    @Test("tools are declared with a builder, and described without running them")
    func declaring() {
        let mcp = PluginMCPTools(id: "mail") {
            PluginTool(id: "search", description: "Search.", input: .object(["query": .string("q")])) { _, _ in .text("ok") }
            PluginTool(id: "archive", description: "Archive.", changesData: true) { _, _ in .text("ok") }
        }
        #expect(mcp.id == "mail" && mcp.tools.map(\.id) == ["search", "archive"])
        let description = PluginMCPDescription(describing: mcp)
        #expect(description.tools.map(\.id) == ["search", "archive"] && description.tools.map(\.changesData) == [false, true])
        #expect(description.tools[0].inputSchema.required == ["query"] && description.tools[1].inputSchema.properties.isEmpty)
    }

    @Test("a builder takes conditionals and loops")
    func builderControlFlow() {
        let include = true
        let mcp = PluginMCPTools(id: "m") {
            PluginTool(id: "a", description: "a") { _, _ in .text("a") }
            if include { PluginTool(id: "b", description: "b") { _, _ in .text("b") } }
            for name in ["c", "d"] { PluginTool(id: name, description: name) { _, _ in .text(name) } }
        }
        #expect(mcp.tools.map(\.id) == ["a", "b", "c", "d"])
    }
}
