// PluginTools.swift — MCP tools a plugin's widget or session type brings into a session (SDK 3.5.0, WOR-894).
//
// A plugin that runs as an extension declares the tools an agent can call as Swift, on the widget or session type they attach
// to. Work42 serves them to a session the way it serves its own MCP servers and routes each call back to the plugin, so the
// widget's UI and the agent's tool call run the same function:
//
// ```swift
// extension MailWidget: Work42WidgetMCPs {
//     var mcpTools: [PluginMCPTools] {[
//         PluginMCPTools(id: "mail") {
//             PluginTool(id: "search_messages", description: "Search the user's Apple Mail.",
//                        input: .object(["query": .string("What to search for"), "limit": .integer("At most this many").optional])) { args, context in
//                 .structured(try await MailController.shared(for: context).search(try args.string("query")))
//             }
//         }
//     ]}
// }
// ```
//
// Every type here is plain data except the handler, so Work42 can read a tool's id, description and input schema without
// running it (packaging writes them into the release). All of it is additive: a plugin that declares no tool is unchanged.

import Foundation

// MARK: - Input schema

/// One argument of a tool: a JSON-schema property (the subset a tool needs).
nonisolated public struct PluginToolProperty: Codable, Sendable, Equatable {
    /// `string`, `integer`, `number` or `boolean`.
    public var type: String
    public var description: String?
    /// `date-time` for an ISO 8601 date and time.
    public var format: String?
    /// The only values accepted, for a choice.
    public var choices: [String]?
    /// Whether the agent must pass it (the default). Not part of the schema property itself: `PluginToolSchema.object` turns it
    /// into the schema's `required` list.
    public var isRequired: Bool

    private enum CodingKeys: String, CodingKey { case type, description, format, choices = "enum" }

    public init(type: String, description: String? = nil, format: String? = nil, choices: [String]? = nil, isRequired: Bool = true) {
        self.type = type
        self.description = description
        self.format = format
        self.choices = choices
        self.isRequired = isRequired
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        choices = try container.decodeIfPresent([String].self, forKey: .choices)
        isRequired = true
    }

    public static func string(_ description: String) -> PluginToolProperty { PluginToolProperty(type: "string", description: description) }
    public static func integer(_ description: String) -> PluginToolProperty { PluginToolProperty(type: "integer", description: description) }
    public static func number(_ description: String) -> PluginToolProperty { PluginToolProperty(type: "number", description: description) }
    public static func boolean(_ description: String) -> PluginToolProperty { PluginToolProperty(type: "boolean", description: description) }
    public static func dateTime(_ description: String) -> PluginToolProperty {
        PluginToolProperty(type: "string", description: description, format: "date-time")
    }
    public static func oneOf(_ choices: [String], _ description: String) -> PluginToolProperty {
        PluginToolProperty(type: "string", description: description, choices: choices)
    }

    /// The same property, which the agent may leave out.
    public var optional: PluginToolProperty {
        var copy = self
        copy.isRequired = false
        return copy
    }
}

/// A tool's input: a JSON object with named properties. Always an object, as MCP requires.
nonisolated public struct PluginToolSchema: Codable, Sendable, Equatable {
    public var type: String
    public var properties: [String: PluginToolProperty]
    public var required: [String]

    public init(properties: [String: PluginToolProperty] = [:], required: [String]? = nil) {
        self.type = "object"
        self.properties = properties
        self.required = required ?? properties.filter { $0.value.isRequired }.keys.sorted()
    }

    /// An object with these properties; every one is required unless marked `.optional`.
    public static func object(_ properties: [String: PluginToolProperty]) -> PluginToolSchema {
        PluginToolSchema(properties: properties)
    }

    /// What is wrong with `arguments` against this schema, or nil when they fit: a missing required argument, an argument the
    /// schema does not list, or one of the wrong type. Work42 checks this before a handler runs.
    public func problem(with arguments: [String: WidgetJSONValue]) -> String? {
        for name in required where arguments[name] == nil || arguments[name] == .null {
            return "'\(name)' is required"
        }
        for (name, value) in arguments.sorted(by: { $0.key < $1.key }) {
            guard let property = properties[name] else { return "'\(name)' is not an argument of this tool" }
            if value == .null { continue }
            switch (property.type, value) {
            case ("string", .string(let text)):
                if let choices = property.choices, !choices.contains(text) {
                    return "'\(name)' must be one of: \(choices.joined(separator: ", "))"
                }
            case ("integer", .number(let number)):
                if number.rounded() != number { return "'\(name)' must be a whole number" }
            case ("number", .number), ("boolean", .bool): break
            default: return "'\(name)' must be a \(property.type)"
            }
        }
        return nil
    }
}

// MARK: - Arguments, results, failures

/// The arguments of one call, with readers that fail with a named error when an argument is missing or of the wrong type.
nonisolated public struct PluginToolArguments: Sendable, Equatable {
    public let values: [String: WidgetJSONValue]

    public init(_ values: [String: WidgetJSONValue] = [:]) { self.values = values }

    public func string(_ name: String) throws -> String {
        guard case .string(let text)? = values[name] else { throw Self.invalid(name, "a string") }
        return text
    }
    public func string(_ name: String, default fallback: String) throws -> String { try optionalString(name) ?? fallback }

    public func optionalString(_ name: String) throws -> String? {
        switch values[name] {
        case nil, .null?: return nil
        case .string(let text)?: return text
        default: throw Self.invalid(name, "a string")
        }
    }

    public func int(_ name: String) throws -> Int {
        guard case .number(let number)? = values[name], number.rounded() == number else { throw Self.invalid(name, "a whole number") }
        return Int(number)
    }

    public func optionalInt(_ name: String) throws -> Int? {
        if values[name] == nil || values[name] == .null { return nil }
        return try int(name)
    }

    public func double(_ name: String) throws -> Double {
        guard case .number(let number)? = values[name] else { throw Self.invalid(name, "a number") }
        return number
    }

    public func bool(_ name: String) throws -> Bool {
        guard case .bool(let flag)? = values[name] else { throw Self.invalid(name, "true or false") }
        return flag
    }

    public func optionalBool(_ name: String) throws -> Bool? {
        if values[name] == nil || values[name] == .null { return nil }
        return try bool(name)
    }

    /// An ISO 8601 date and time, with or without fractional seconds.
    public func date(_ name: String) throws -> Date {
        let text = try string(name)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
        throw Self.invalid(name, "an ISO 8601 date and time")
    }

    private static func invalid(_ name: String, _ expected: String) -> PluginToolFailure {
        PluginToolFailure(code: "invalid_arguments", message: "'\(name)' must be \(expected)",
                          suggestion: "pass '\(name)' as \(expected)")
    }
}

/// One piece of a tool's answer. Text is what an agent reads.
nonisolated public struct PluginToolContent: Codable, Sendable, Equatable {
    public var type: String
    public var text: String
    public init(type: String = "text", text: String) {
        self.type = type
        self.text = text
    }
}

/// What a tool answers: text for the agent to read, and optionally the same answer as structured JSON.
nonisolated public struct PluginToolResult: Codable, Sendable, Equatable {
    public var content: [PluginToolContent]
    public var structured: WidgetJSONValue?

    public init(content: [PluginToolContent], structured: WidgetJSONValue? = nil) {
        self.content = content
        self.structured = structured
    }

    public static func text(_ text: String) -> PluginToolResult { PluginToolResult(content: [PluginToolContent(text: text)]) }

    /// `value` as JSON: the structured answer, and its text for an agent that reads only text.
    public static func structured<Value: Encodable>(_ value: Value) throws -> PluginToolResult {
        let data = try JSONEncoder().encode(value)
        let json = try JSONDecoder().decode(WidgetJSONValue.self, from: data)
        return PluginToolResult(content: [PluginToolContent(text: String(decoding: data, as: UTF8.self))], structured: json)
    }
}

/// Why a tool did not answer. It crosses the wire as a tool failure, kept apart from a transport error: the call reached the
/// tool and the tool said no.
nonisolated public struct PluginToolFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    /// A short stable word for a program (`invalid_arguments`, `not_found`, `cancelled`, `permission_denied`, …).
    public var code: String
    public var message: String
    /// What to do next; an agent reads it.
    public var suggestion: String?
    public var details: WidgetJSONValue?

    public init(code: String, message: String, suggestion: String? = nil, details: WidgetJSONValue? = nil) {
        self.code = code
        self.message = message
        self.suggestion = suggestion
        self.details = details
    }

    public var errorDescription: String? { message }

    public static let cancelled = PluginToolFailure(code: "cancelled", message: "the call was cancelled")
}

// MARK: - Declaring tools

/// One call as the handler sees it. `services` are this plugin's, for this session: asking for a permission goes through
/// Work42's broker as it does for a widget.
@MainActor
public struct PluginToolContext {
    public let sessionId: String
    /// The widget the tool belongs to, nil for a session type's tool.
    public let widgetId: String?
    /// Names this call: progress and cancellation refer to it.
    public let invocationId: String
    public let services: SessionServices
    private let sink: @MainActor @Sendable (_ message: String, _ fraction: Double?) async -> Void

    public init(sessionId: String, widgetId: String?, invocationId: String, services: SessionServices,
                progress: @escaping @MainActor @Sendable (_ message: String, _ fraction: Double?) async -> Void = { _, _ in }) {
        self.sessionId = sessionId
        self.widgetId = widgetId
        self.invocationId = invocationId
        self.services = services
        self.sink = progress
    }

    /// Tells the agent how far a long call is.
    public func reportProgress(_ message: String, fraction: Double? = nil) async { await sink(message, fraction) }
}

/// One tool. `changesData` marks a call that changes something outside the plugin (sends, moves, deletes, records): Work42
/// never repeats such a call after a crash or an uncertain disconnect.
nonisolated public struct PluginTool: Sendable {
    public let id: String
    public let description: String
    public let input: PluginToolSchema
    public let changesData: Bool
    let handler: @MainActor @Sendable (PluginToolArguments, PluginToolContext) async throws -> PluginToolResult

    public init(id: String, description: String, input: PluginToolSchema = .object([:]), changesData: Bool = false,
                handler: @escaping @MainActor @Sendable (PluginToolArguments, PluginToolContext) async throws -> PluginToolResult) {
        self.id = id
        self.description = description
        self.input = input
        self.changesData = changesData
        self.handler = handler
    }

    /// Runs the handler. Used by the extension runtime, which has already validated the arguments.
    @MainActor public func run(_ arguments: PluginToolArguments, _ context: PluginToolContext) async throws -> PluginToolResult {
        try await handler(arguments, context)
    }
}

@resultBuilder
nonisolated public enum PluginToolBuilder {
    public static func buildExpression(_ tool: PluginTool) -> [PluginTool] { [tool] }
    public static func buildBlock(_ groups: [PluginTool]...) -> [PluginTool] { groups.flatMap { $0 } }
    public static func buildArray(_ groups: [[PluginTool]]) -> [PluginTool] { groups.flatMap { $0 } }
    public static func buildOptional(_ tools: [PluginTool]?) -> [PluginTool] { tools ?? [] }
    public static func buildEither(first tools: [PluginTool]) -> [PluginTool] { tools }
    public static func buildEither(second tools: [PluginTool]) -> [PluginTool] { tools }
}

/// The tools of one MCP server. `id` is the id the plugin's `widget.yaml` or session type declares for it.
nonisolated public struct PluginMCPTools: Sendable {
    public let id: String
    public let tools: [PluginTool]

    public init(id: String, tools: [PluginTool]) {
        self.id = id
        self.tools = tools
    }

    public init(id: String, @PluginToolBuilder _ tools: () -> [PluginTool]) {
        self.init(id: id, tools: tools())
    }
}

/// A widget that brings MCP tools into every session it is in.
@MainActor
public protocol Work42WidgetMCPs {
    var mcpTools: [PluginMCPTools] { get }
}

/// A session type that brings MCP tools into every session of the type, with or without a widget open.
@MainActor
public protocol Work42SessionTypeMCPs: AnyObject {
    var mcpTools: [PluginMCPTools] { get }
}

// MARK: - What Work42 reads without running anything

/// A tool as it is described on the wire and written into a release.
nonisolated public struct PluginToolDescription: Codable, Sendable, Equatable {
    public var id: String
    public var description: String
    public var inputSchema: PluginToolSchema
    public var changesData: Bool

    public init(id: String, description: String, inputSchema: PluginToolSchema, changesData: Bool) {
        self.id = id
        self.description = description
        self.inputSchema = inputSchema
        self.changesData = changesData
    }

    public init(describing tool: PluginTool) {
        self.init(id: tool.id, description: tool.description, inputSchema: tool.input, changesData: tool.changesData)
    }
}

/// One MCP server's tools as described on the wire.
nonisolated public struct PluginMCPDescription: Codable, Sendable, Equatable {
    public var id: String
    public var tools: [PluginToolDescription]

    public init(id: String, tools: [PluginToolDescription]) {
        self.id = id
        self.tools = tools
    }

    public init(describing mcp: PluginMCPTools) {
        self.init(id: mcp.id, tools: mcp.tools.map(PluginToolDescription.init(describing:)))
    }
}
