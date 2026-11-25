// ExtensionCapabilityTests.swift — SDK 3.3.0's permission, audio, speech and calendar services over the in-memory wire, from
// the extension's proxies (through `services.permissions` and friends) to the services Work42 answers with.

import Foundation
import Testing
import Work42Extension
import Work42PluginKit

// MARK: - Host-side fake

/// One object that is all four services, scripted by the test.
nonisolated final class FakeCapabilities: WidgetPermissionService, WidgetAudioService, WidgetSpeechService, WidgetCalendarService,
                                          @unchecked Sendable {
    private let lock = NSLock()
    private var statusByPermission: [PluginPermission: PluginPermissionStatus] = [:]
    private var requested: [PluginPermission] = []
    private var stopCalls = 0
    private var request: AudioRecordingRequest?
    private var recordingId = UUID()
    private var liveOf: UUID?
    var refuse: PluginPermissionError?

    var requests: [PluginPermission] { lock.withLock { requested } }
    var stops: Int { lock.withLock { stopCalls } }
    var lastRequest: AudioRecordingRequest? { lock.withLock { request } }
    var hostRecordingId: UUID { lock.withLock { recordingId } }
    var liveTranscriptOf: UUID? { lock.withLock { liveOf } }

    var capabilities: WidgetCapabilities { WidgetCapabilities(permissions: self, audio: self, speech: self, calendar: self) }

    func status(_ permission: PluginPermission) async throws -> PluginPermissionStatus {
        if let refuse { throw refuse }
        return lock.withLock { statusByPermission[permission] } ?? .notAsked
    }

    func request(_ permission: PluginPermission) async throws -> PluginPermissionStatus {
        if let refuse { throw refuse }
        lock.withLock { requested.append(permission); statusByPermission[permission] = .granted }
        return .granted
    }

    func startRecording(_ request: AudioRecordingRequest) async throws -> AudioRecording {
        if let refuse { throw refuse }
        let (levels, continuation) = AsyncStream<AudioLevels>.makeStream()
        let id = UUID()
        lock.withLock { self.request = request; recordingId = id }
        continuation.yield(AudioLevels(source: .microphone, level: 0.5))
        return AudioRecording(id: id, levels: levels, stop: { [weak self] in
            self?.lock.withLock { self?.stopCalls += 1 }
            continuation.finish()
            return [URL(fileURLWithPath: "/tmp/s1/microphone.m4a")]
        })
    }

    func transcribe(file: URL, locale: Locale?) async throws -> [TranscriptSegment] {
        if let refuse { throw refuse }
        return [TranscriptSegment(start: 0, end: 1.5, text: "hello from \(file.lastPathComponent) in \(locale?.identifier ?? "default")")]
    }

    func liveTranscript(of recording: UUID) -> AsyncThrowingStream<TranscriptSegment, any Error> {
        lock.withLock { liveOf = recording }
        return AsyncThrowingStream { continuation in
            continuation.yield(TranscriptSegment(start: 0, end: 1, text: "live words", source: .microphone))
            continuation.finish()
        }
    }

    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        if let refuse { throw refuse }
        return [CalendarEvent(id: "e1", title: "Standup", start: from, end: to, attendees: ["ada@example.com"], calendar: "Work")]
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in continuation.yield(); continuation.finish() }
    }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<80 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

// MARK: - Tests

@Suite("SDK 3.3.0 capability services over the extension wire", .serialized)
@MainActor
struct ExtensionCapabilityTests {

    private func connect(_ fake: FakeCapabilities?) throws -> (pair: Pair, services: SessionServices) {
        let pair = Pair(widgets: [])
        if let fake { pair.link.server.capabilityProvider = { _ in fake.capabilities } }
        let channel = try #require(pair.runtime.channel)
        WidgetCapabilityRegistry.provider = ExtensionCapabilityProvider(channel: channel)
        let remote = ExtensionServices.session(channel: channel, sessionId: "s1", widgetId: "rec", worktreePath: nil)
        return (pair, remote)
    }

    private func cleanUp() { WidgetCapabilityRegistry.provider = nil }

    // MARK: Permissions

    @Test("status and request reach the host's permission service and return where the permission stands")
    func statusAndRequest() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        let (_, services) = try connect(fake)

        #expect(try await services.permissions.status(.microphone) == .notAsked)
        #expect(try await services.permissions.request(.microphone) == .granted)
        #expect(try await services.permissions.status(.microphone) == .granted)
        #expect(fake.requests == [.microphone])
    }

    @Test("a permission the plugin did not declare arrives as PluginPermissionError.notDeclared, not a generic failure")
    func notDeclaredIsTyped() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        fake.refuse = .notDeclared(.calendars)
        let (_, services) = try connect(fake)

        await #expect(throws: PluginPermissionError.notDeclared(.calendars)) {
            _ = try await services.permissions.request(.calendars)
        }
        await #expect(throws: PluginPermissionError.notDeclared(.calendars)) {
            _ = try await services.calendar.events(from: Date(), to: Date())
        }
    }

    @Test("a refusal keeps its message through the wire, colons and all")
    func deniedKeepsItsMessage() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        fake.refuse = .denied(.microphone, message: "You chose Not now: Meet42 will ask again next time.")
        let (_, services) = try connect(fake)

        do {
            _ = try await services.audio.startRecording(AudioRecordingRequest(sources: [.microphone], directory: "rec"))
            Issue.record("a refused recording started")
        } catch let error as PluginPermissionError {
            #expect(error == .denied(.microphone, message: "You chose Not now: Meet42 will ask again next time."))
            #expect(error.errorDescription == "You chose Not now: Meet42 will ask again next time.")
        }
    }

    @Test("a host with no capability services answers with a named error")
    func noProvider() async throws {
        defer { cleanUp() }
        let (_, services) = try connect(nil)
        await #expect(throws: WidgetServiceError.self) { _ = try await services.permissions.status(.microphone) }
    }

    @Test("with no provider registered a widget gets the named 'host lacks' error, never a crash")
    func unregisteredRegistry() async throws {
        WidgetCapabilityRegistry.provider = nil
        let (_, services) = try connect(nil)
        WidgetCapabilityRegistry.provider = nil
        await #expect(throws: WidgetServiceError.self) { _ = try await services.permissions.request(.microphone) }
        await #expect(throws: WidgetServiceError.self) {
            _ = try await services.audio.startRecording(AudioRecordingRequest(sources: [.microphone], directory: "rec"))
        }
        var changes = 0
        for await _ in services.calendar.changes() { changes += 1 }
        #expect(changes == 0, "a host without a calendar has no changes")
    }

    // MARK: Audio

    @Test("a recording streams levels, writes where it was asked to, and stop returns the files")
    func recordingLifecycle() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        let (pair, services) = try connect(fake)

        let recording = try await services.audio.startRecording(
            AudioRecordingRequest(sources: [.microphone, .systemAudio], directory: "meetings/a"))
        #expect(fake.lastRequest == AudioRecordingRequest(sources: [.microphone, .systemAudio], directory: "meetings/a"))
        #expect(pair.link.server.runningRecordingCount == 1)

        var first: AudioLevels?
        for await levels in recording.levels { first = levels; break }
        #expect(first == AudioLevels(source: .microphone, level: 0.5))

        let files = try await recording.stop()
        #expect(files == [URL(fileURLWithPath: "/tmp/s1/microphone.m4a")])
        #expect(fake.stops == 1)
        #expect(await eventually { pair.link.server.runningRecordingCount == 0 })
    }

    @Test("a recording stops when the extension's connection closes, and when its widget is detached")
    func recordingEndsWithItsScope() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        let (pair, services) = try connect(fake)
        let request = AudioRecordingRequest(sources: [.microphone], directory: "a")

        let kept = try await services.audio.startRecording(request)
        pair.link.server.stopStreams()
        #expect(await eventually { fake.stops == 1 })
        #expect(pair.link.server.runningRecordingCount == 0)
        _ = kept

        let second = try await services.audio.startRecording(request)
        pair.link.server.detach(widgetId: "rec", sessionId: "s1")
        #expect(await eventually { fake.stops == 2 })
        _ = second
    }

    // MARK: Speech

    @Test("a file is transcribed on the host, with the locale the widget chose")
    func transcribeFile() async throws {
        defer { cleanUp() }
        let (_, services) = try connect(FakeCapabilities())
        let segments = try await services.speech.transcribe(file: URL(fileURLWithPath: "/tmp/s1/a.m4a"), locale: Locale(identifier: "es_ES"))
        #expect(segments == [TranscriptSegment(start: 0, end: 1.5, text: "hello from a.m4a in es_ES")])
    }

    @Test("a live transcript follows the host's recording, though the widget knows it by another id")
    func liveTranscript() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        let (_, services) = try connect(fake)
        let recording = try await services.audio.startRecording(AudioRecordingRequest(sources: [.microphone], directory: "a"))

        var segments: [TranscriptSegment] = []
        for try await segment in services.speech.liveTranscript(of: recording.id) { segments.append(segment) }
        #expect(segments == [TranscriptSegment(start: 0, end: 1, text: "live words", source: .microphone)])
        #expect(fake.liveTranscriptOf == fake.hostRecordingId)
        #expect(recording.id != fake.hostRecordingId, "the extension's id is the stream's, the host's is the recording's")
    }

    @Test("a live transcript of a recording that is not running fails with a named error")
    func liveTranscriptOfNothing() async throws {
        defer { cleanUp() }
        let (_, services) = try connect(FakeCapabilities())
        await #expect(throws: WidgetServiceError.self) {
            for try await _ in services.speech.liveTranscript(of: UUID()) {}
        }
    }

    @Test("the host finds a call's session folder from the services its widget was attached with")
    func sessionFolder() throws {
        let pair = Pair(widgets: [])
        let services = SessionServices(composer: NullComposer(), shell: ScriptedShell(), intents: NullIntents(), storage: MemoryStore(),
                                       pill: NullPill(), sessionId: "s1", worktreePath: "/work/s1")
        pair.link.server.attach(services, widgetId: "rec", sessionId: "s1")
        func call(_ session: String?) -> ExtensionCall { ExtensionCall(service: "audio", method: "startRecording", sessionId: session, widgetId: "rec") }
        #expect(pair.link.server.sessionFolder(for: call("s1")) == "/work/s1")
        #expect(pair.link.server.sessionFolder(for: call("other")) == nil)
        #expect(pair.link.server.sessionFolder(for: call(nil)) == nil)
        pair.link.server.detach(widgetId: "rec", sessionId: "s1")
        #expect(pair.link.server.sessionFolder(for: call("s1")) == nil)
    }

    // MARK: Calendar

    @Test("events come back with their dates, and the change stream yields")
    func calendar() async throws {
        defer { cleanUp() }
        let (_, services) = try connect(FakeCapabilities())
        let from = Date(timeIntervalSince1970: 1_800_000_000), to = from.addingTimeInterval(3600)

        let events = try await services.calendar.events(from: from, to: to)
        #expect(events.count == 1)
        #expect(events[0].title == "Standup" && events[0].attendees == ["ada@example.com"] && events[0].calendar == "Work")
        #expect(abs(events[0].start.timeIntervalSince(from)) < 0.01 && abs(events[0].end.timeIntervalSince(to)) < 0.01)

        var changes = 0
        for await _ in services.calendar.changes() { changes += 1 }
        #expect(changes == 1)
    }
}

// MARK: - Types

@Suite("SDK 3.3.0 capability types")
struct PluginCapabilityTypeTests {

    @Test("a permission error round-trips through the service error it travels as")
    func errorRoundTrip() {
        for error in [PluginPermissionError.notDeclared(.systemAudio),
                      .denied(.speechRecognition, message: "Turn it on in System Settings: Privacy & Security."),
                      .denied(.calendars, message: "")] {
            #expect(PluginPermissionError(error.serviceError) == error)
        }
        #expect(PluginPermissionError(WidgetServiceError(message: "something else")) == nil)
        #expect(PluginPermissionError(WidgetServiceError(message: PluginPermissionError.deniedPrefix + "nonsense: x")) == nil)
    }

    @Test("typed(_:) turns only permission errors into PluginPermissionError")
    func typedOnlyPermission() {
        #expect(PluginPermissionError.typed(PluginPermissionError.notDeclared(.microphone).serviceError) as? PluginPermissionError
                == .notDeclared(.microphone))
        #expect(PluginPermissionError.typed(WidgetServiceError(message: "other")) as? WidgetServiceError == WidgetServiceError(message: "other"))
    }

    @Test("the permission names are the ones plugin.yaml uses")
    func names() {
        #expect(PluginPermission.allCases.map(\.rawValue) == ["microphone", "system-audio", "calendars", "speech-recognition"])
        #expect(AudioSource.systemAudio.permission == .systemAudio && AudioSource.microphone.permission == .microphone)
    }

    @Test("a service that implements none of a protocol answers each call with a named error")
    func defaults() async {
        let unsupported = UnsupportedWidgetCapability()
        await #expect(throws: WidgetServiceError.self) { _ = try await unsupported.status(.microphone) }
        await #expect(throws: WidgetServiceError.self) { _ = try await unsupported.request(.microphone) }
        await #expect(throws: WidgetServiceError.self) {
            _ = try await unsupported.startRecording(AudioRecordingRequest(sources: [.microphone], directory: "a"))
        }
        await #expect(throws: WidgetServiceError.self) { _ = try await unsupported.transcribe(file: URL(fileURLWithPath: "/x"), locale: nil) }
        await #expect(throws: WidgetServiceError.self) { _ = try await unsupported.events(from: Date(), to: Date()) }
        await #expect(throws: WidgetServiceError.self) { for try await _ in unsupported.liveTranscript(of: UUID()) {} }
        var changes = 0
        for await _ in unsupported.changes() { changes += 1 }
        #expect(changes == 0)
    }
}
