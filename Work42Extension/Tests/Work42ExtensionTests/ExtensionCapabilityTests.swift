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
    /// The live transcript's source throws `error`, before its first segment or after it.
    var liveFailure: (error: any Error, afterSegment: Bool)?

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
        let failure = liveFailure
        return AsyncThrowingStream { continuation in
            if let failure, !failure.afterSegment {
                continuation.finish(throwing: failure.error)
                return
            }
            continuation.yield(TranscriptSegment(start: 0, end: 1, text: "live words", source: .microphone))
            if let failure { continuation.finish(throwing: failure.error) } else { continuation.finish() }
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

    @Test("the microphone the widget chose reaches the host's request")
    func microphoneDeviceTravels() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        let (_, services) = try connect(fake)
        _ = try await services.audio.startRecording(
            AudioRecordingRequest(sources: [.microphone], directory: "a", microphoneDevice: "BuiltInMicrophoneDevice"))
        #expect(fake.lastRequest?.microphoneDevice == "BuiltInMicrophoneDevice")
    }

    @Test("a background agent records through the same services, and its recording ends with the agent")
    func backgroundRecording() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        let pair = Pair(widgets: [])
        pair.link.server.capabilityProvider = { _ in fake.capabilities }
        let channel = try #require(pair.runtime.channel)
        WidgetCapabilityRegistry.provider = ExtensionCapabilityProvider(channel: channel)
        let agent = ExtensionServices.background(channel: channel, sessionId: "s1", widgetId: "recording", taskId: nil)

        let recording = try await agent.audio.startRecording(
            AudioRecordingRequest(sources: [.microphone, .systemAudio], directory: "~/.work42/meet42/recordings/r1"))
        #expect(pair.link.server.runningRecordingCount == 1)
        #expect(fake.lastRequest?.directory == "~/.work42/meet42/recordings/r1")

        // The agent's scope ends (the session went away): the recording stops, with the files so far kept.
        pair.link.server.detachBackground(widgetId: "recording", sessionId: "s1")
        #expect(await eventually { fake.stops == 1 })
        #expect(pair.link.server.runningRecordingCount == 0)

        #expect(try await agent.permissions.status(.microphone) == .notAsked)
        let events = try await agent.calendar.events(from: Date(), to: Date())
        #expect(events.count == 1)
        withExtendedLifetime(recording) {}
    }

    @Test("a tile closing does not end a recording an agent started")
    func tileClosingKeepsTheAgentsRecording() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        let pair = Pair(widgets: [])
        pair.link.server.capabilityProvider = { _ in fake.capabilities }
        let channel = try #require(pair.runtime.channel)
        WidgetCapabilityRegistry.provider = ExtensionCapabilityProvider(channel: channel)
        let agent = ExtensionServices.background(channel: channel, sessionId: "s1", widgetId: "recording", taskId: nil)

        // Held, as a recorder does: letting go of the recording (its levels) ends it, which is not what is under test.
        let recording = try await agent.audio.startRecording(
            AudioRecordingRequest(sources: [.microphone], directory: "~/.work42/meet42/recordings/r1"))
        pair.link.server.detach(widgetId: "recording", sessionId: "s1")   // the tile unmounts
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.stops == 0)
        #expect(pair.link.server.runningRecordingCount == 1)
        _ = try await recording.stop()
        #expect(fake.stops == 1)
    }

    @Test("and the same widget's tile recording does end with the tile, not with its agent")
    func agentClosingKeepsTheTilesRecording() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        let (pair, services) = try connect(fake)
        let recording = try await services.audio.startRecording(AudioRecordingRequest(sources: [.microphone], directory: "a"))
        pair.link.server.detachBackground(widgetId: "rec", sessionId: "s1")   // an agent of the same widget stops
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.stops == 0)
        pair.link.server.detach(widgetId: "rec", sessionId: "s1")
        #expect(await eventually { fake.stops == 1 })
        _ = recording
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

    private struct SpeechModelMissing: Error, LocalizedError {
        var errorDescription: String? { "the on-device speech model for en_US is not installed" }
    }

    @Test("a host speech stream that throws before its first segment reaches the consumer with the original error text")
    func liveTranscriptFailsBeforeFirstSegment() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        fake.liveFailure = (SpeechModelMissing(), afterSegment: false)
        let (_, services) = try connect(fake)
        let recording = try await services.audio.startRecording(AudioRecordingRequest(sources: [.microphone], directory: "a"))

        var segments: [TranscriptSegment] = []
        do {
            for try await segment in services.speech.liveTranscript(of: recording.id) { segments.append(segment) }
            Issue.record("the stream finished normally: the host's error was swallowed")
        } catch {
            #expect(error.localizedDescription == "the on-device speech model for en_US is not installed")
        }
        #expect(segments.isEmpty)
    }

    @Test("a host speech stream that throws after a segment delivers the segment, then the original error text")
    func liveTranscriptFailsAfterSegment() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        fake.liveFailure = (WidgetServiceError(message: "speech analyzer stopped", suggestion: "start the recording again"),
                            afterSegment: true)
        let (_, services) = try connect(fake)
        let recording = try await services.audio.startRecording(AudioRecordingRequest(sources: [.microphone], directory: "a"))

        var segments: [TranscriptSegment] = []
        do {
            for try await segment in services.speech.liveTranscript(of: recording.id) { segments.append(segment) }
            Issue.record("the stream finished normally: the host's error was swallowed")
        } catch let error as WidgetServiceError {
            #expect(error == WidgetServiceError(message: "speech analyzer stopped", suggestion: "start the recording again"))
        }
        #expect(segments == [TranscriptSegment(start: 0, end: 1, text: "live words", source: .microphone)])
    }

    @Test("a permission refusal that ends a host speech stream arrives as PluginPermissionError")
    func liveTranscriptPermissionRefusal() async throws {
        defer { cleanUp() }
        let fake = FakeCapabilities()
        let denied = PluginPermissionError.denied(.speechRecognition, message: "Speech Recognition is off: allow it in System Settings.")
        fake.liveFailure = (denied, afterSegment: false)
        let (_, services) = try connect(fake)
        let recording = try await services.audio.startRecording(AudioRecordingRequest(sources: [.microphone], directory: "a"))

        await #expect(throws: denied) {
            for try await _ in services.speech.liveTranscript(of: recording.id) {}
        }
    }

    @Test("a stream event without an error decodes as before, and one with an error survives the wire")
    func streamEventCompatibility() throws {
        let id = UUID()
        let old = Data(#"{"streamId":"\#(id.uuidString)","finished":true}"#.utf8)
        let decoded = try ExtensionJSON.decode(ExtensionStreamEvent.self, from: old)
        #expect(decoded == ExtensionStreamEvent(streamId: id, finished: true))
        #expect(decoded.error == nil)

        let failed = ExtensionStreamEvent(streamId: id, error: WidgetServiceError(message: "boom", suggestion: "retry"))
        #expect(try ExtensionJSON.decode(ExtensionStreamEvent.self, from: ExtensionJSON.encode(failed)) == failed)
        #expect(failed.finished, "an extension that predates `error` still sees the stream end")
        // A new host's event read by an old extension: the unknown key is ignored.
        struct OldEvent: Codable { var streamId: UUID; var item: Data?; var finished: Bool }
        let seenByOld = try ExtensionJSON.decode(OldEvent.self, from: ExtensionJSON.encode(failed))
        #expect(seenByOld.finished && seenByOld.item == nil)
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

    @Test("a calendar event keeps everything a plugin's own copy needs, and an older host's payload still decodes")
    func calendarEventFields() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CalendarEvent(
            id: "e1", title: "Standup", start: start, end: start.addingTimeInterval(1800), calendar: "Work", calendarId: "cal-1",
            calendarColor: "#1BADF8", source: "google", organizer: "Ada",
            attendeeDetails: [CalendarAttendee(name: "Ada", email: "ada@example.com", status: "accepted", isOrganizer: true)],
            status: "confirmed", url: "https://example.com/e1", lastModified: start)
        let wire = try ExtensionJSON.encode(event)
        #expect(try ExtensionJSON.decode(CalendarEvent.self, from: wire) == event)

        // What a host that predates the extra fields sent: they are all optional, so it still decodes.
        let old = try ExtensionJSON.encode(CalendarEvent(id: "e2", title: "Old", start: start, end: start))
        let decoded = try ExtensionJSON.decode(CalendarEvent.self, from: old)
        #expect(decoded.calendarId == nil && decoded.attendeeDetails == nil && decoded.status == nil)
    }

    @Test("a recording request without a microphone device encodes as it did before the field existed")
    func requestWireIsUnchangedWithoutDevice() throws {
        let wire = try ExtensionJSON.encode(AudioRecordingRequest(sources: [.microphone], directory: "a"))
        let text = String(decoding: wire, as: UTF8.self)
        #expect(!text.contains("microphoneDevice"))
        #expect(try ExtensionJSON.decode(AudioRecordingRequest.self, from: wire).microphoneDevice == nil)
    }

    @Test("a provider that predates background capabilities answers none, with the named error")
    func providerWithoutBackgroundCapabilities() async {
        struct OldProvider: WidgetCapabilityProvider {
            func capabilities(for services: SessionServices) -> WidgetCapabilities { WidgetCapabilities() }
        }
        let agent = WidgetBackgroundServices(shell: ScriptedShell(), storage: MemoryStore(), pill: NullPill(), sessionId: "s1", taskId: nil)
        let capabilities = OldProvider().capabilities(forBackground: agent)
        await #expect(throws: WidgetServiceError.self) { _ = try await capabilities.permissions.status(.microphone) }
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
