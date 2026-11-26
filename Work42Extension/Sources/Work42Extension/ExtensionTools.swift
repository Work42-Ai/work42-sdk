// ExtensionTools.swift — the wire for MCP tools a plugin's widgets and session types declare (SDK 3.5.0, WOR-894).
//
// A tool is described once, in the handshake (id, description, input schema, whether it changes data), so Work42 can list it to
// an agent without running anything. A call is `extension.callTool` (host to extension), answered with a `ToolOutcome`: the
// tool's result, or the tool's own failure, kept apart from a transport error (the call reached the tool and the tool said no).
// `extension.cancelTool` stops a running call. A tool that reports progress sends `tool.progress` (extension to host) on the
// existing channel. Every message is a new method string on the existing JSON/XPC transport: nothing in XPC changes, and an
// extension or host built before 3.5.0 answers any of them with a named "unsupported" error.

import Foundation
import Work42PluginKit

/// How an extension makes the object that declares a session type's tools. The runtime makes one per (type, session).
nonisolated public struct ExtensionSessionTypeFactory: Sendable {
    public let id: String
    public let make: @MainActor @Sendable () -> any Work42SessionTypeMCPs

    public init(_ id: String, make: @escaping @MainActor @Sendable () -> any Work42SessionTypeMCPs) {
        self.id = id
        self.make = make
    }
}

/// One session type's tools as the handshake lists them. `id` is the id in the plugin's `session-types/<id>.json`.
nonisolated public struct ExtensionSessionTypeDescription: Codable, Sendable, Equatable {
    public var id: String
    public var mcps: [PluginMCPDescription]

    public init(id: String, mcps: [PluginMCPDescription]) {
        self.id = id
        self.mcps = mcps
    }
}

extension ExtensionPayload {
    /// `extension.callTool` arguments: which tool, its arguments, and who the call is for (the execution lease: session,
    /// widget when the tool belongs to one, and the chat the agent called from).
    nonisolated public struct CallTool: Codable, Sendable, Equatable {
        public static let widgetOwner = "widget"
        public static let sessionTypeOwner = "session-type"

        /// `widget` or `session-type`.
        public var owner: String
        /// The widget id or the session type id.
        public var ownerId: String
        public var mcp: String
        public var tool: String
        public var arguments: [String: WidgetJSONValue]
        /// Names this call; `extension.cancelTool` and `tool.progress` refer to it.
        public var invocationId: String
        public var chatId: String?
        public var worktreePath: String?

        public init(owner: String, ownerId: String, mcp: String, tool: String, arguments: [String: WidgetJSONValue] = [:],
                    invocationId: String, chatId: String? = nil, worktreePath: String? = nil) {
            self.owner = owner
            self.ownerId = ownerId
            self.mcp = mcp
            self.tool = tool
            self.arguments = arguments
            self.invocationId = invocationId
            self.chatId = chatId
            self.worktreePath = worktreePath
        }
    }

    /// `extension.cancelTool` arguments.
    nonisolated public struct CancelTool: Codable, Sendable, Equatable {
        public var invocationId: String
        public init(invocationId: String) { self.invocationId = invocationId }
    }

    /// `tool.progress` arguments, from the extension to the host.
    nonisolated public struct ToolProgress: Codable, Sendable, Equatable {
        public var invocationId: String
        public var message: String
        /// 0 to 1 when the tool knows how far along it is.
        public var fraction: Double?
        public init(invocationId: String, message: String, fraction: Double? = nil) {
            self.invocationId = invocationId
            self.message = message
            self.fraction = fraction
        }
    }

    /// The reply to `extension.callTool`: exactly one of the two.
    nonisolated public struct ToolOutcome: Codable, Sendable, Equatable {
        public var result: PluginToolResult?
        public var failure: PluginToolFailure?

        public init(result: PluginToolResult) { self.result = result; self.failure = nil }
        public init(failure: PluginToolFailure) { self.result = nil; self.failure = failure }
    }
}

public extension ExtensionCall {
    /// The `extension.callTool` call for `payload`. A tool that changes data gets a `requestId`, so the host records it and,
    /// after a crash, reports it as interrupted instead of sending it again.
    static func callTool(_ payload: ExtensionPayload.CallTool, sessionId: String, widgetId: String?,
                         changesData: Bool) throws -> ExtensionCall {
        ExtensionCall(service: "extension", method: "callTool", sessionId: sessionId, widgetId: widgetId,
                      requestId: changesData ? UUID() : nil, payload: try ExtensionJSON.encode(payload))
    }
}

public extension PluginToolFailure {
    /// What the caller of a tool that changes data is told when the extension stopped while it ran: the call is not repeated,
    /// because it may already have taken effect.
    static let outcomeUnknown = PluginToolFailure(
        code: "outcome_unknown",
        message: "the plugin stopped while this call was running, so whether it took effect is unknown",
        suggestion: "check the result before repeating it")
}
