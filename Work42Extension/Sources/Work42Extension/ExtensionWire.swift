// ExtensionWire.swift — what the Work42 app and an out-of-process plugin say to each other (SDK 3.2.0).
//
// Every message, in both directions, is one `ExtensionCall` encoded as JSON and answered by one `ExtensionReply`. The XPC
// protocols carry only `Data` (see `Work42ExtensionXPC.swift`), so adding a service method later adds a `method` string,
// never an XPC selector: an extension built against an older SDK keeps talking to a newer host, and a call it does not
// know comes back as a named `WidgetServiceError` instead of an XPC failure.

import Foundation
import Work42PluginKit

/// The extension point Work42 declares for out-of-process plugins, and the names both sides agree on.
///
/// ExtensionKit requires a point identifier qualified by the host's bundle id (`<host bundle id>.<name>`); an
/// unqualified id such as `com.work42.plugin` is not recognised (WOR-861 finding 2).
public enum Work42ExtensionPoint {
    /// The Work42 app's bundle identifier, the host that declares the point.
    nonisolated public static let hostBundleIdentifier = "com.work42.app"
    /// The point's name inside the host.
    nonisolated public static let name = "plugin"
    /// `com.work42.app.plugin`: the value of `EXAppExtensionAttributes.EXExtensionPointIdentifier` in a plugin
    /// extension's `Info.plist`.
    nonisolated public static let identifier = "\(hostBundleIdentifier).\(name)"
    /// The scene id every widget scene uses; the host passes the widget and session on the scene's connection.
    nonisolated public static let sceneIdentifier = "widget"
    /// The extension `Info.plist` key holding the SDK version it was built with, read by the host before connecting.
    nonisolated public static let sdkVersionInfoKey = "Work42SDKVersion"
}

/// One request across the process boundary, host to extension or extension to host.
nonisolated public struct ExtensionCall: Codable, Sendable, Equatable {
    /// The SDK version of the side that sent it (`Work42SDKCompatibility.version`).
    public var sdkVersion: String
    /// The service family: `extension`, `scene`, or a `SessionServices` member (`shell`, `storage`, ...).
    public var service: String
    /// The method within the service (`run`, `performIntent`, ...).
    public var method: String
    /// The session the call acts for, as the host assigned it.
    public var sessionId: String?
    /// The widget the call comes from or goes to.
    public var widgetId: String?
    /// Set for every call that is not safe to run twice (`ExtensionCall.nonIdempotentMethods`). The host records it, and
    /// after a crash an interrupted request is reported, never sent again.
    public var requestId: UUID?
    /// The method's arguments, as JSON.
    public var payload: Data

    public init(sdkVersion: String = Work42SDKCompatibility.version, service: String, method: String,
                sessionId: String? = nil, widgetId: String? = nil, requestId: UUID? = nil, payload: Data = Data("{}".utf8)) {
        self.sdkVersion = sdkVersion
        self.service = service
        self.method = method
        self.sessionId = sessionId
        self.widgetId = widgetId
        self.requestId = requestId
        self.payload = payload
    }

    /// `service.method`, the name `nonIdempotentMethods` and errors use.
    public var name: String { "\(service).\(method)" }

    /// The calls that change something outside the process and so must never run twice: each carries a `requestId`.
    nonisolated public static let nonIdempotentMethods: Set<String> = [
        "shell.run", "intents.execute", "tools.call", "extension.hook", "extension.performIntent",
    ]

    /// A call with a fresh `requestId` when `service.method` is non-idempotent, and none otherwise.
    public static func make<Payload: Encodable>(service: String, method: String, sessionId: String?, widgetId: String?,
                                                payload: Payload) throws -> ExtensionCall {
        let name = "\(service).\(method)"
        return ExtensionCall(service: service, method: method, sessionId: sessionId, widgetId: widgetId,
                             requestId: nonIdempotentMethods.contains(name) ? UUID() : nil,
                             payload: try ExtensionJSON.encode(payload))
    }
}

/// The answer to one `ExtensionCall`: a JSON payload, or the error the callee threw.
nonisolated public struct ExtensionReply: Codable, Sendable, Equatable {
    public var payload: Data?
    public var error: WidgetServiceError?

    public init(payload: Data? = nil, error: WidgetServiceError? = nil) {
        self.payload = payload
        self.error = error
    }

    public static func success<Value: Encodable>(_ value: Value) throws -> ExtensionReply {
        ExtensionReply(payload: try ExtensionJSON.encode(value))
    }

    public static func failure(_ error: any Error) -> ExtensionReply {
        ExtensionReply(error: error as? WidgetServiceError
            ?? WidgetServiceError(message: error.localizedDescription, suggestion: nil))
    }
}

/// A value pushed on a stream the other side subscribed to (file watches, host streams, browser tabs and events,
/// collaboration cursors). `finished` ends the stream; `item` is absent then.
nonisolated public struct ExtensionStreamEvent: Codable, Sendable, Equatable {
    public var streamId: UUID
    public var item: Data?
    public var finished: Bool

    public init(streamId: UUID, item: Data? = nil, finished: Bool = false) {
        self.streamId = streamId
        self.item = item
        self.finished = finished
    }
}

/// An empty JSON object, for calls and replies with nothing to say.
nonisolated public struct ExtensionEmpty: Codable, Sendable, Equatable {
    public init() {}
}

/// The JSON coder both sides use. Dates are ISO 8601 with fractional seconds so a `WidgetFileEntry` round-trips exactly.
nonisolated public enum ExtensionJSON {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            Date(timeIntervalSinceReferenceDate: try decoder.singleValueContainer().decode(Double.self))
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw WidgetServiceError(
                message: "the message for \(type) could not be read: \(error.localizedDescription)",
                suggestion: "build the plugin with the SDK the host reports (`work42 sdk`) and try again")
        }
    }
}

public extension WidgetServiceError {
    /// What a caller gets when the extension process stopped (crashed, was killed or stopped answering) while its request
    /// was in flight. The request is never sent again: the person or agent decides whether to repeat it.
    static var extensionInterrupted: WidgetServiceError {
        WidgetServiceError(message: "interrupted: the extension stopped", suggestion: "retry the action")
    }

    /// What code inside an extension gets when its connection to Work42 closed while a service call was in flight.
    static var hostInterrupted: WidgetServiceError {
        WidgetServiceError(message: "interrupted: the connection to Work42 closed", suggestion: "retry the action")
    }

    /// A call the other side does not implement: it was built with an older SDK.
    static func unsupported(_ call: ExtensionCall) -> WidgetServiceError {
        WidgetServiceError(
            message: "\(call.name) is not supported by this side (SDK \(Work42SDKCompatibility.version)); the caller is on SDK \(call.sdkVersion)",
            suggestion: "update Work42 or rebuild the plugin so both use the same SDK major version")
    }
}
