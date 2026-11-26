// PluginRemoteTools.swift — a widget on another device running its own plugin's tools on the paired Mac (SDK 3.5.0, WOR-902).
//
// A widget on the Mac calls its controller directly. A widget on an iPad has no extension process: the plugin's extension runs on
// the paired Mac, so the iPad asks the Mac to run one of the plugin's MCP tools and gets its answer. It is a typed call, not a
// command line: `mcp` and `tool` name a tool the plugin declared, `arguments` are checked by the tool's own schema, and the Mac
// runs the same code the Mac's widget and the agent's MCP tools run.
//
// The Mac decides whether the call may run (the device is paired and may use the session, the widget belongs to the plugin that
// declares the MCP, the MCP is the widget's own). A tool that `changesData` is never run twice for one `requestId`: a retry after
// a lost connection gets the first call's answer, or `outcome_unknown` when the Mac does not know it, never a second run.
// With no Mac to reach the call fails with `mac_unreachable`; there is no other route.

import Foundation

public nonisolated enum PluginRemoteFailure {
    /// The paired Mac did not answer (asleep, off the network, not paired).
    public static let macUnreachable = "mac_unreachable"
    /// The Mac received a call that changes data but cannot say whether it ran; it will not run it again.
    public static let outcomeUnknown = "outcome_unknown"
    /// The widget may not call that tool: not the plugin's, not the widget's own MCP, or not a tool the plugin declares.
    public static let notPermitted = "not_permitted"
}

nonisolated public protocol WidgetPluginToolService: Sendable {
    /// Runs the plugin tool `tool` of the MCP `mcp` that this widget owns, on the Mac, and returns its answer. `requestId` names
    /// the call: send the same id again to retry it, and a tool that changes data still runs once. Throws `PluginToolFailure`
    /// for a tool that said no and for the failures in `PluginRemoteFailure`.
    func call(mcp: String, tool: String, arguments: [String: WidgetJSONValue], requestId: UUID) async throws -> PluginToolResult
}

nonisolated public extension WidgetPluginToolService {
    func call(mcp: String, tool: String, arguments: [String: WidgetJSONValue], requestId: UUID) async throws -> PluginToolResult {
        throw WidgetServiceError.hostLacks("pluginTools.call")
    }

    /// The same, with a fresh id: one attempt that is not retried.
    func call(mcp: String, tool: String, arguments: [String: WidgetJSONValue] = [:]) async throws -> PluginToolResult {
        try await call(mcp: mcp, tool: tool, arguments: arguments, requestId: UUID())
    }
}

extension UnsupportedWidgetCapability: WidgetPluginToolService {}

/// How a tool's outcome crosses the link: the answer, or the failure the tool gave.
nonisolated public struct PluginToolOutcomeWire: Codable, Sendable, Equatable {
    public var result: PluginToolResult?
    public var failure: PluginToolFailure?

    public init(result: PluginToolResult? = nil, failure: PluginToolFailure? = nil) {
        self.result = result
        self.failure = failure
    }

    /// The answer, or the failure thrown; an outcome with neither is a failure of the Mac's side.
    public func unwrapped() throws -> PluginToolResult {
        if let failure { throw failure }
        guard let result else {
            throw PluginToolFailure(code: "empty_result", message: "The Mac answered with neither a result nor a failure.",
                                    suggestion: "Try the call again.")
        }
        return result
    }
}
