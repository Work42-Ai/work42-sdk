// PluginCapabilities.swift — what a plugin can ask Work42 to do on its behalf that macOS keeps from an extension
// (SDK 3.3.0): record audio, transcribe speech, read calendars.
//
// macOS refuses a privacy permission (microphone, calendars, speech recognition, system-audio capture) to a process that is
// an extension on a third-party point (WOR-882), however it is signed. So Work42, which can hold them, does the work and
// hands the result to the plugin. A plugin declares what it needs in plugin.yaml (`permissions`) and just calls the
// services below; Work42 checks the declaration, asks the person (its own pill, then macOS) the first time, and a call that
// cannot go ahead throws `PluginPermissionError`, which a widget handles like any other error.
//
// Like every service they are reached through `SessionServices`, as computed properties: the struct's memory layout is
// part of the binary contract with plugins built against older SDKs, so a new service cannot be a stored property. A host
// that has none of them (a 3.2.0 host, a preview) answers every call with a named `WidgetServiceError` instead.

import Foundation

// MARK: - Permissions

/// A privacy permission Work42 holds for plugins. The raw values are the names `plugin.yaml` `permissions` use.
nonisolated public enum PluginPermission: String, Codable, Sendable, CaseIterable, Equatable {
    case microphone
    case systemAudio = "system-audio"
    case calendars
    case speechRecognition = "speech-recognition"

    /// What a sentence calls it: "wants to use the microphone".
    public var displayName: String {
        switch self {
        case .microphone: "microphone"
        case .systemAudio: "system audio"
        case .calendars: "calendars"
        case .speechRecognition: "speech recognition"
        }
    }
}

/// A permission by the name `plugin.yaml` `permissions` uses (SDK 3.5.0). `PluginPermission` has only the four cases of SDK
/// 3.3.0; this names every permission Work42 brokers, including ones a newer Work42 adds, and a name the host does not know
/// is refused rather than guessed at. Each `PluginPermission` converts to the id with the same name.
nonisolated public struct PluginPermissionID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(_ permission: PluginPermission) { self.rawValue = permission.rawValue }

    public static let microphone: PluginPermissionID = "microphone"
    public static let systemAudio: PluginPermissionID = "system-audio"
    public static let speechRecognition: PluginPermissionID = "speech-recognition"
    public static let calendars: PluginPermissionID = "calendars"
    public static let reminders: PluginPermissionID = "reminders"
    public static let contacts: PluginPermissionID = "contacts"
    public static let photos: PluginPermissionID = "photos"
    public static let camera: PluginPermissionID = "camera"
    public static let location: PluginPermissionID = "location"
    public static let bluetooth: PluginPermissionID = "bluetooth"
    public static let localNetwork: PluginPermissionID = "local-network"
    public static let mediaLibrary: PluginPermissionID = "media-library"
    public static let notifications: PluginPermissionID = "notifications"
    public static let filesAndFolders: PluginPermissionID = "files-and-folders"
    public static let automation: PluginPermissionID = "automation"
    public static let fullDiskAccess: PluginPermissionID = "full-disk-access"
    public static let accessibility: PluginPermissionID = "accessibility"
    public static let inputMonitoring: PluginPermissionID = "input-monitoring"
    public static let screenRecording: PluginPermissionID = "screen-recording"
    /// Running a command through `services.shell`: Work42's own rule, with no macOS permission behind it.
    public static let runCommands: PluginPermissionID = "run-commands"
}

/// Where a permission stands for one plugin.
nonisolated public enum PluginPermissionStatus: String, Codable, Sendable, Equatable {
    /// The plugin may use it now.
    case granted
    /// Nobody has been asked yet: the first use shows Work42's pill, then macOS's own prompt.
    case notAsked
    /// macOS or the person said no.
    case denied
    /// The plugin's manifest does not declare it, so it can never be used.
    case notDeclared
}

/// Why a call that needs a permission did not go ahead.
nonisolated public enum PluginPermissionError: Error, LocalizedError, Equatable, Sendable {
    /// plugin.yaml does not declare the permission.
    case notDeclared(PluginPermission)
    /// The permission was refused (macOS said no, or the person chose Not now). `message` says what to do.
    case denied(PluginPermission, message: String)

    nonisolated public static let notDeclaredPrefix = "plugin permission not declared: "
    nonisolated public static let deniedPrefix = "plugin permission denied: "

    public var errorDescription: String? {
        switch self {
        case .notDeclared(let permission):
            "this plugin does not declare the \(permission.displayName) permission. Add it under permissions in plugin.yaml."
        case .denied(_, let message):
            message
        }
    }

    /// The error as it crosses the wire. `WidgetServiceError` has no stored code (its layout is pinned), so the kind and
    /// the permission are carried as a prefix, the way `WidgetServiceError.notPermitted` does.
    public var serviceError: WidgetServiceError {
        switch self {
        case .notDeclared(let permission):
            WidgetServiceError(message: Self.notDeclaredPrefix + permission.rawValue,
                               suggestion: "declare \(permission.rawValue) under permissions in plugin.yaml")
        case .denied(let permission, let message):
            WidgetServiceError(message: Self.deniedPrefix + permission.rawValue + ": " + message)
        }
    }

    /// The permission error `error` carries, or nil when it is any other failure.
    public init?(_ error: WidgetServiceError) {
        if error.message.hasPrefix(Self.notDeclaredPrefix),
           let permission = PluginPermission(rawValue: String(error.message.dropFirst(Self.notDeclaredPrefix.count))) {
            self = .notDeclared(permission)
        } else if error.message.hasPrefix(Self.deniedPrefix) {
            let rest = error.message.dropFirst(Self.deniedPrefix.count)
            guard let colon = rest.range(of: ": "), let permission = PluginPermission(rawValue: String(rest[..<colon.lowerBound]))
            else { return nil }
            self = .denied(permission, message: String(rest[colon.upperBound...]))
        } else {
            return nil
        }
    }

    /// `error` as a permission error when it is one, else unchanged. Proxies and hosts use it so a widget catches
    /// `PluginPermissionError` whatever side of the wire the check ran on.
    public static func typed(_ error: any Error) -> any Error {
        (error as? WidgetServiceError).flatMap(PluginPermissionError.init) ?? error
    }
}

/// Reads and asks for a plugin's permissions. Optional: a plugin that only calls the capability services never needs it;
/// one that shows a permission list (meet42's permissions widget) does.
nonisolated public protocol WidgetPermissionService: Sendable {
    /// Where `permission` stands for this plugin, without asking anyone. `.notDeclared` when the manifest lacks it.
    func status(_ permission: PluginPermission) async throws -> PluginPermissionStatus

    /// Asks for `permission` as the first use would (Work42's pill, then macOS) and returns where it stands afterwards.
    /// Throws `PluginPermissionError.notDeclared` for a permission the manifest does not declare.
    func request(_ permission: PluginPermission) async throws -> PluginPermissionStatus
}

nonisolated public extension WidgetPermissionService {
    func status(_ permission: PluginPermission) async throws -> PluginPermissionStatus {
        throw WidgetServiceError.hostLacks("permissions.status(_:)")
    }

    func request(_ permission: PluginPermission) async throws -> PluginPermissionStatus {
        throw WidgetServiceError.hostLacks("permissions.request(_:)")
    }
}

// MARK: - Audio

/// Where recorded audio comes from.
nonisolated public enum AudioSource: String, Codable, Sendable, Equatable {
    case microphone
    case systemAudio = "system-audio"

    /// The permission recording from this source needs.
    public var permission: PluginPermission { self == .microphone ? .microphone : .systemAudio }
}

nonisolated public struct AudioRecordingRequest: Codable, Sendable, Equatable {
    /// What to record, at least one. Each source is written to its own file.
    public var sources: [AudioSource]
    /// Where the files go: a path relative to the session folder, or a folder the plugin declared read-write under
    /// `file_access` (`~/...`).
    public var directory: String
    /// The input device to record the microphone from, by its Core Audio UID. `nil` records the system default input. Ignored
    /// unless `sources` has `.microphone`; a UID that is not connected any more records the default input instead.
    public var microphoneDevice: String?

    public init(sources: [AudioSource], directory: String) {
        self.sources = sources
        self.directory = directory
        self.microphoneDevice = nil
    }

    /// A request that names the microphone to record (a separate initializer, so the one above keeps its exact signature).
    public init(sources: [AudioSource], directory: String, microphoneDevice: String?) {
        self.sources = sources
        self.directory = directory
        self.microphoneDevice = microphoneDevice
    }
}

/// How loud a source is right now, 0 (silence) to 1 (full scale).
nonisolated public struct AudioLevels: Codable, Sendable, Equatable {
    public var source: AudioSource
    public var level: Double

    public init(source: AudioSource, level: Double) {
        self.source = source
        self.level = level
    }
}

/// A recording in progress.
nonisolated public struct AudioRecording: Sendable {
    public let id: UUID
    /// Levels as they change, until the recording stops.
    public let levels: AsyncStream<AudioLevels>
    /// Ends the recording and returns the files it wrote, one per source. Files written so far are kept when the plugin is
    /// deactivated, its extension's connection closes or Work42 quits.
    public let stop: @Sendable () async throws -> [URL]

    public init(id: UUID, levels: AsyncStream<AudioLevels>, stop: @escaping @Sendable () async throws -> [URL]) {
        self.id = id
        self.levels = levels
        self.stop = stop
    }
}

nonisolated public protocol WidgetAudioService: Sendable {
    /// Starts recording `request.sources` to `request.directory`. Throws `PluginPermissionError` when a source's permission
    /// is not declared or not granted.
    func startRecording(_ request: AudioRecordingRequest) async throws -> AudioRecording
}

nonisolated public extension WidgetAudioService {
    func startRecording(_ request: AudioRecordingRequest) async throws -> AudioRecording {
        throw WidgetServiceError.hostLacks("audio.startRecording(_:)")
    }
}

// MARK: - Speech

nonisolated public struct TranscriptSegment: Codable, Sendable, Equatable {
    /// Seconds from the start of the recording or file.
    public var start: Double
    public var end: Double
    public var text: String
    /// Which side said it, for a live transcript of a recording with both.
    public var source: AudioSource?
    /// `true` for text the recognizer may still change (SDK 3.4.0): a live transcript delivers a growing partial line, then
    /// the final one that replaces it. Absent (nil) means final, which is what every earlier host sends, so a transcript
    /// that only keeps final lines keeps working unchanged: filter on `isFinal`.
    public var isPartial: Bool?

    /// Whether this is the final text of the line.
    public var isFinal: Bool { isPartial != true }

    public init(start: Double, end: Double, text: String, source: AudioSource? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.source = source
        self.isPartial = nil
    }

    /// A line that may be partial (3.4.0). `isPartial` has no default so this overload stays distinct from the one above.
    public init(start: Double, end: Double, text: String, source: AudioSource?, isPartial: Bool?) {
        self.init(start: start, end: end, text: text, source: source)
        self.isPartial = isPartial
    }
}

nonisolated public protocol WidgetSpeechService: Sendable {
    /// Transcribes the audio file at `file` on this Mac. `locale` defaults to the person's.
    func transcribe(file: URL, locale: Locale?) async throws -> [TranscriptSegment]

    /// The words of the recording `recording` (an `AudioRecording.id`) as they are said. Ends when it stops.
    func liveTranscript(of recording: UUID) -> AsyncThrowingStream<TranscriptSegment, any Error>

    /// The same, and with `partialResults` also the text the recognizer may still change (SDK 3.4.0): a line arrives as it
    /// is said (`TranscriptSegment.isPartial`), and the final text replaces it. Without it only final lines arrive, which is
    /// what a caller that does not know about partial lines needs; a service that cannot tell the two apart delivers final
    /// lines only.
    func liveTranscript(of recording: UUID, partialResults: Bool) -> AsyncThrowingStream<TranscriptSegment, any Error>
}

nonisolated public extension WidgetSpeechService {
    func transcribe(file: URL, locale: Locale?) async throws -> [TranscriptSegment] {
        throw WidgetServiceError.hostLacks("speech.transcribe(file:locale:)")
    }

    func liveTranscript(of recording: UUID) -> AsyncThrowingStream<TranscriptSegment, any Error> {
        AsyncThrowingStream { $0.finish(throwing: WidgetServiceError.hostLacks("speech.liveTranscript(of:)")) }
    }

    func liveTranscript(of recording: UUID, partialResults: Bool) -> AsyncThrowingStream<TranscriptSegment, any Error> {
        liveTranscript(of: recording)
    }
}

// MARK: - Calendar

/// One invitee of a calendar event.
nonisolated public struct CalendarAttendee: Codable, Sendable, Equatable {
    public var name: String?
    public var email: String?
    /// `accepted`, `declined`, `tentative`, `pending` or `unknown`.
    public var status: String
    public var isOrganizer: Bool
    public var isCurrentUser: Bool

    public init(name: String? = nil, email: String? = nil, status: String = "unknown", isOrganizer: Bool = false,
                isCurrentUser: Bool = false) {
        self.name = name
        self.email = email
        self.status = status
        self.isOrganizer = isOrganizer
        self.isCurrentUser = isCurrentUser
    }
}

nonisolated public struct CalendarEvent: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var attendees: [String]
    /// The calendar it is on.
    public var calendar: String?

    // What a plugin that keeps its own copy of the calendar needs (all optional: a host that cannot tell leaves them nil).

    /// The calendar's own identifier, stable across renames (`calendar` is its title).
    public var calendarId: String?
    /// The calendar's colour as `#RRGGBB`.
    public var calendarColor: String?
    /// Where the calendar comes from: `local`, `icloud`, `google`, `exchange`, `caldav` or `other`.
    public var source: String?
    public var organizer: String?
    /// The invitees with their answers; `attendees` is the same people as plain names.
    public var attendeeDetails: [CalendarAttendee]?
    /// `confirmed`, `tentative`, `canceled` or `none`.
    public var status: String?
    public var url: String?
    public var lastModified: Date?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil,
                notes: String? = nil, attendees: [String] = [], calendar: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.attendees = attendees
        self.calendar = calendar
        self.calendarId = nil
        self.calendarColor = nil
        self.source = nil
        self.organizer = nil
        self.attendeeDetails = nil
        self.status = nil
        self.url = nil
        self.lastModified = nil
    }

    /// An event with everything a plugin keeping its own copy of the calendar needs. A separate initializer, so the one above keeps
    /// its exact signature; `calendarId` has no default so a call with only the older arguments still means that one.
    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil,
                notes: String? = nil, attendees: [String] = [], calendar: String? = nil, calendarId: String?,
                calendarColor: String? = nil, source: String? = nil, organizer: String? = nil,
                attendeeDetails: [CalendarAttendee]? = nil, status: String? = nil, url: String? = nil,
                lastModified: Date? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.attendees = attendees
        self.calendar = calendar
        self.calendarId = calendarId
        self.calendarColor = calendarColor
        self.source = source
        self.organizer = organizer
        self.attendeeDetails = attendeeDetails
        self.status = status
        self.url = url
        self.lastModified = lastModified
    }
}

nonisolated public protocol WidgetCalendarService: Sendable {
    /// The events that overlap `from`..`to`, soonest first.
    func events(from: Date, to: Date) async throws -> [CalendarEvent]

    /// Yields each time the calendars change (an event added, moved or removed). Finishes when the consumer stops.
    func changes() -> AsyncStream<Void>
}

nonisolated public extension WidgetCalendarService {
    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        throw WidgetServiceError.hostLacks("calendar.events(from:to:)")
    }

    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

// MARK: - The bundle, and how a plugin reaches it

/// The four services for one (plugin, session).
nonisolated public struct WidgetCapabilities: Sendable {
    public let permissions: any WidgetPermissionService
    public let audio: any WidgetAudioService
    public let speech: any WidgetSpeechService
    public let calendar: any WidgetCalendarService

    public init(permissions: any WidgetPermissionService = UnsupportedWidgetCapability(),
                audio: any WidgetAudioService = UnsupportedWidgetCapability(),
                speech: any WidgetSpeechService = UnsupportedWidgetCapability(),
                calendar: any WidgetCalendarService = UnsupportedWidgetCapability()) {
        self.permissions = permissions
        self.audio = audio
        self.speech = speech
        self.calendar = calendar
    }
}

/// What a host with none of the services answers: every call throws a named error (the protocols' defaults).
nonisolated public struct UnsupportedWidgetCapability: WidgetPermissionService, WidgetAudioService, WidgetSpeechService,
                                                       WidgetCalendarService {
    public init() {}
}

/// Hands out the services for a session. The extension runtime registers proxies that send each call to Work42; an iPad
/// registers one that forwards to the paired Mac.
nonisolated public protocol WidgetCapabilityProvider: Sendable {
    /// The services for the widget and session `services` was built for (an extension reads its widget off the services'
    /// proxies, so a recording ends with the widget that started it).
    func capabilities(for services: SessionServices) -> WidgetCapabilities

    /// The services for the widget and session a background agent's `services` was built for. A recording started from an agent
    /// lives as long as the agent does, not as long as a tile is on screen. A provider that predates this answers none.
    func capabilities(forBackground services: WidgetBackgroundServices) -> WidgetCapabilities
}

nonisolated public extension WidgetCapabilityProvider {
    func capabilities(forBackground services: WidgetBackgroundServices) -> WidgetCapabilities { WidgetCapabilities() }
}

/// Where the host process registers its provider. Set once at startup, like `WidgetAccountRegistry`.
@MainActor
public enum WidgetCapabilityRegistry {
    public static var provider: (any WidgetCapabilityProvider)?
}

extension SessionServices {
    @MainActor private var capabilities: WidgetCapabilities {
        WidgetCapabilityRegistry.provider?.capabilities(for: self) ?? WidgetCapabilities()
    }

    /// Reads and asks for this plugin's permissions (SDK 3.3.0). Optional to use: the capability services below ask for
    /// themselves.
    @MainActor public var permissions: any WidgetPermissionService { capabilities.permissions }

    /// Records audio through Work42 (SDK 3.3.0).
    @MainActor public var audio: any WidgetAudioService { capabilities.audio }

    /// Transcribes speech through Work42 (SDK 3.3.0).
    @MainActor public var speech: any WidgetSpeechService { capabilities.speech }

    /// Reads the person's calendars through Work42 (SDK 3.3.0).
    @MainActor public var calendar: any WidgetCalendarService { capabilities.calendar }
}

/// The same four services for a background agent (SDK 3.3.0). A recording started here ends when the agent stops, so work that
/// has to outlive a tile (a meeting being recorded) belongs to an agent.
extension WidgetBackgroundServices {
    @MainActor private var capabilities: WidgetCapabilities {
        WidgetCapabilityRegistry.provider?.capabilities(forBackground: self) ?? WidgetCapabilities()
    }

    @MainActor public var permissions: any WidgetPermissionService { capabilities.permissions }
    @MainActor public var audio: any WidgetAudioService { capabilities.audio }
    @MainActor public var speech: any WidgetSpeechService { capabilities.speech }
    @MainActor public var calendar: any WidgetCalendarService { capabilities.calendar }
}
