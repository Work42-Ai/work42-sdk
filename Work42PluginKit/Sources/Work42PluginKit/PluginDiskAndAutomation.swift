// PluginDiskAndAutomation.swift — two more things macOS keeps from an extension, done by Work42 on the plugin's behalf
// (SDK 3.5.0): reading files anywhere on disk (Full Disk Access) and sending Apple Events to another app (Automation).
//
// Both are permissions Work42 brokers (`full-disk-access`, `automation`): the plugin declares them in plugin.yaml, Work42's
// pill asks the person the first time, and every call is checked again. Neither hands a plugin a capability it can keep: no
// file descriptor leaves Work42, and an Apple Event is built by Work42 from typed data, never from a script.
//
// They are reached through `SessionServices.diskRead` and `.automation` like the other capability services, and a host without
// them answers every call with a named `WidgetServiceError`.

import Foundation

// MARK: - Disk read

/// What a path is. `stat` reports a symbolic link as itself; sockets, devices and pipes are named so a plugin can see why a
/// read was refused.
nonisolated public enum DiskEntryKind: String, Codable, Sendable, Equatable {
    case file
    case directory
    case symlink
    /// A socket, a device node or a pipe: Work42 never reads these.
    case other
}

/// One file, folder or link, as `stat` and `list` describe it.
nonisolated public struct DiskEntry: Codable, Sendable, Equatable {
    /// The last component of the path.
    public var name: String
    public var kind: DiskEntryKind
    /// Bytes for a file; 0 for anything else.
    public var size: Int64
    public var modifiedAt: Date?
    /// Where a symbolic link points, as written in the link.
    public var linkTarget: String?

    public init(name: String, kind: DiskEntryKind, size: Int64 = 0, modifiedAt: Date? = nil, linkTarget: String? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.linkTarget = linkTarget
    }
}

/// One page of a folder.
nonisolated public struct DiskListing: Codable, Sendable, Equatable {
    /// In byte order of the names, so every page of a folder agrees.
    public var entries: [DiskEntry]
    /// Pass it to the next `list` call; nil when this was the last page.
    public var nextCursor: String?

    public init(entries: [DiskEntry], nextCursor: String? = nil) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

/// One bounded piece of a file.
nonisolated public struct DiskChunk: Codable, Sendable, Equatable {
    public var data: Data
    /// Where in the file this piece starts.
    public var offset: Int64
    /// The file's size when it was read.
    public var size: Int64
    /// True when this piece reaches the end of the file.
    public var isEnd: Bool

    public init(data: Data, offset: Int64, size: Int64, isEnd: Bool) {
        self.data = data
        self.offset = offset
        self.size = size
        self.isEnd = isEnd
    }
}

/// The bounds every host applies to `services.diskRead`.
nonisolated public enum DiskReadLimits {
    /// The most `read` returns in one call; a longer `length` is cut to this and `isEnd` says whether more is left.
    public static let maxReadLength = 4 * 1024 * 1024
    /// The page size `list` uses when `limit` is nil, and the most it will return.
    public static let defaultListLimit = 200
    public static let maxListLimit = 1000
    /// The longest path accepted.
    public static let maxPathLength = 4096
}

/// Reads files anywhere on the disk, through Work42 (which holds Full Disk Access). Needs the `full-disk-access` permission on
/// every call.
///
/// Paths are absolute (`/Users/…`) or start with `~/`. There is no folder scoping: the permission is the whole gate. Reads are
/// bounded and paged, and no file descriptor is ever handed out. Symbolic links: `stat` describes the link itself, `list` and
/// `read` follow it and refuse a target that is not a folder (list) or a regular file (read). Sockets, devices and pipes are
/// refused. A failure from macOS is passed through in the error's message with its errno.
nonisolated public protocol WidgetDiskReadService: Sendable {
    func stat(path: String) async throws -> DiskEntry
    func list(path: String, cursor: String?, limit: Int?) async throws -> DiskListing
    func read(path: String, offset: Int64, length: Int) async throws -> DiskChunk
}

nonisolated public extension WidgetDiskReadService {
    func stat(path: String) async throws -> DiskEntry {
        throw WidgetServiceError.hostLacks("diskRead.stat(path:)")
    }

    func list(path: String, cursor: String?, limit: Int?) async throws -> DiskListing {
        throw WidgetServiceError.hostLacks("diskRead.list(path:cursor:limit:)")
    }

    func read(path: String, offset: Int64, length: Int) async throws -> DiskChunk {
        throw WidgetServiceError.hostLacks("diskRead.read(path:offset:length:)")
    }

    /// The first page of a folder.
    func list(path: String) async throws -> DiskListing { try await list(path: path, cursor: nil, limit: nil) }
}

// MARK: - Automation

/// A four-character code Apple Events use for classes, events, keywords and enumerators (`'core'`, `'getd'`, `'----'`).
nonisolated public struct AppleEventCode: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(stringLiteral value: String) { self.rawValue = value }
    public init(_ value: String) { self.rawValue = value }

    public var description: String { rawValue }

    /// The code as a 32-bit number, or nil when it is not four ASCII characters.
    public var number: UInt32? {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == 4, rawValue.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The direct parameter of an event (`'----'`).
    public static let directObject: AppleEventCode = "----"
}

/// One named parameter of an event or one field of a record.
nonisolated public struct AppleEventField: Codable, Sendable, Equatable {
    public var key: AppleEventCode
    public var value: AppleEventValue

    public init(_ key: AppleEventCode, _ value: AppleEventValue) {
        self.key = key
        self.value = value
    }
}

/// An object in the target app: "message 3 of mailbox 'INBOX'". `container` is the object it is in, or `.null` for the app.
nonisolated public struct AppleEventObjectSpecifier: Codable, Sendable, Equatable {
    /// The class wanted (`'cobj'` for any object, or the app's own, such as `'mbxp'`).
    public var desiredClass: AppleEventCode
    public var container: AppleEventValue
    /// How `data` picks it: `'indx'` by index, `'name'` by name, `'ID  '` by id, …
    public var form: AppleEventCode
    public var data: AppleEventValue

    public init(desiredClass: AppleEventCode, container: AppleEventValue = .null, form: AppleEventCode, data: AppleEventValue) {
        self.desiredClass = desiredClass
        self.container = container
        self.form = form
        self.data = data
    }
}

/// A value in an Apple Event, as typed data. No script text is ever accepted or run.
nonisolated public indirect enum AppleEventValue: Codable, Sendable, Equatable {
    case null
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case list([AppleEventValue])
    case record([AppleEventField])
    /// A constant of the app's terminology (`'yes '`, `'seen'`).
    case enumerator(AppleEventCode)
    /// A class name as a value (`'long'`, `'mbxp'`).
    case type(AppleEventCode)
    case object(AppleEventObjectSpecifier)
}

/// One Apple Event for Work42 to send.
nonisolated public struct AppleEventRequest: Codable, Sendable, Equatable {
    /// The app that receives it, by bundle id (`com.apple.mail`). The plugin must declare the `automation` permission for this
    /// target; each target is its own consent.
    public var target: String
    public var eventClass: AppleEventCode
    public var eventID: AppleEventCode
    /// The event's parameters by keyword; the direct parameter is `.directObject`.
    public var parameters: [AppleEventField]
    /// How long to wait for the reply, in seconds (1 to 120; 30 when nil).
    public var timeoutSeconds: Int?

    public init(target: String, eventClass: AppleEventCode, eventID: AppleEventCode, parameters: [AppleEventField] = [],
                timeoutSeconds: Int? = nil) {
        self.target = target
        self.eventClass = eventClass
        self.eventID = eventID
        self.parameters = parameters
        self.timeoutSeconds = timeoutSeconds
    }
}

/// What the app answered. An app's own refusal (an error number in its reply) is `errorNumber` and `errorMessage` with no value.
nonisolated public struct AppleEventReply: Codable, Sendable, Equatable {
    public var value: AppleEventValue?
    public var errorNumber: Int?
    public var errorMessage: String?

    public init(value: AppleEventValue? = nil, errorNumber: Int? = nil, errorMessage: String? = nil) {
        self.value = value
        self.errorNumber = errorNumber
        self.errorMessage = errorMessage
    }
}

nonisolated public enum AppleEventLimits {
    public static let defaultTimeoutSeconds = 30
    public static let maxTimeoutSeconds = 120
    /// Nesting a request may have, so a malicious value cannot exhaust the host's stack.
    public static let maxDepth = 16
}

/// Sends typed Apple Events to another app, through Work42 (which holds the Automation consent). Needs the `automation`
/// permission for `request.target` on every call. Work42 builds the event with the Apple Event APIs: it never runs `osascript`,
/// a shell or a script, and it does not launch the target.
nonisolated public protocol WidgetAutomationService: Sendable {
    func send(_ request: AppleEventRequest) async throws -> AppleEventReply
}

nonisolated public extension WidgetAutomationService {
    func send(_ request: AppleEventRequest) async throws -> AppleEventReply {
        throw WidgetServiceError.hostLacks("automation.send(_:)")
    }
}

extension UnsupportedWidgetCapability: WidgetDiskReadService, WidgetAutomationService {}
