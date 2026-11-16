// WidgetFileServiceTests.swift — SDK 2.16.0 (ABI 17): `files` and `platform` on the session services. The host
// implements them (the Mac locally, an iPad over the device link); these pin the path rule, the refusal shape,
// the no-op default and how the service bundles carry them.

import Foundation
import Testing
@testable import Work42PluginKit

private struct StubComposer: WidgetComposerService {
    nonisolated func insert(text: String) async throws {}
    nonisolated func attach(sourceLabel: String, excerpt: String, body: String) async throws {}
}

private struct StubShell: WidgetShellService {
    nonisolated func run(command: String) async throws -> WidgetShellResult {
        WidgetShellResult(stdout: "", stderr: "", exitCode: 0)
    }
}

private struct StubIntents: WidgetIntentsService {
    nonisolated func execute(id: String, params: [String: WidgetJSONValue]) async throws {}
}

private struct StubStorage: WidgetStorageService {
    nonisolated func get(namespace: String, key: String) async throws -> WidgetJSONValue? { nil }
    nonisolated func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }
    nonisolated func set(key: String, value: WidgetJSONValue) async throws {}
    nonisolated func delete(key: String) async throws {}
}

private struct StubPill: WidgetPillService {
    nonisolated func present(widgetId: String, sessionId: String) async throws {}
    nonisolated func dismiss(widgetId: String) async throws {}
    nonisolated func isPresented(widgetId: String) async throws -> Bool { false }
}

private struct FixedFiles: WidgetFileService {
    nonisolated func read(_ relativePath: String) async throws -> Data { Data(relativePath.utf8) }
    nonisolated func list(_ relativeDir: String) async throws -> [WidgetFileEntry] {
        [WidgetFileEntry(name: "meeting.json", isDirectory: false, size: 2, modifiedAt: Date(timeIntervalSince1970: 0))]
    }
    nonisolated func watch(_ relativePath: String) -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private struct RecordingPlatform: WidgetPlatformService {
    @MainActor func open(_ url: URL) {}
    @MainActor func copy(_ text: String) {}
}

@Suite("WidgetFileService and WidgetPlatformService (SDK 2.16.0)")
struct WidgetFileServiceTests {

    @Test("a relative path inside the session folder is accepted")
    func acceptsRelativePaths() throws {
        for path in ["meeting.json", "notes/a.md", ".", "a/./b.txt", "dir/", "..hidden", "a..b/c"] {
            try WidgetFilePath.validate(path)
        }
    }

    @Test("an empty, absolute, home-relative, NUL or parent-escaping path is refused as not permitted")
    func refusesEscapingPaths() {
        let refused = ["", "/etc/passwd", "~/secrets", "..", "../x", "a/../../x", "a/../b", "a/b/..", "x\0y", "//abs"]
        for path in refused {
            do {
                try WidgetFilePath.validate(path)
                Issue.record("expected \"\(path.debugDescription)\" to be refused")
            } catch let error as WidgetServiceError {
                #expect(error.isNotPermitted, "\(path.debugDescription): \(error.message)")
                #expect(error.suggestion?.isEmpty == false)
            } catch {
                Issue.record("expected WidgetServiceError for \(path.debugDescription), got \(error)")
            }
        }
    }

    @Test("notPermitted is recognizable from the error alone, and an ordinary error is not")
    func notPermittedShape() throws {
        let refusal = WidgetServiceError.notPermitted("the widget is not built in", suggestion: "use a built-in widget")
        #expect(refusal.isNotPermitted)
        #expect(refusal.message == "not permitted: the widget is not built in")
        #expect(refusal.suggestion == "use a built-in widget")
        #expect(!WidgetServiceError(message: "timed out").isNotPermitted)

        // It survives the device link: only message and suggestion cross, and the prefix is all that's needed.
        let decoded = try JSONDecoder().decode(WidgetServiceError.self, from: JSONEncoder().encode(refusal))
        #expect(decoded.isNotPermitted)
        #expect(decoded == refusal)
    }

    @Test("WidgetFileEntry round-trips through Codable")
    func entryRoundTrips() throws {
        let entry = WidgetFileEntry(name: "a.md", isDirectory: false, size: 12, modifiedAt: Date(timeIntervalSince1970: 100))
        let decoded = try JSONDecoder().decode(WidgetFileEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
    }

    @Test("the no-op file service fails read loudly, lists nothing and never yields from watch")
    func noopDefault() async throws {
        let files = NoopWidgetFileService()
        do {
            _ = try await files.read("meeting.json")
            Issue.record("expected an error")
        } catch let error as WidgetServiceError {
            #expect(!error.message.isEmpty)
            #expect(error.suggestion?.isEmpty == false)
        } catch {
            Issue.record("expected WidgetServiceError, got \(error)")
        }
        #expect(try await files.list(".").isEmpty)
        var ticks = 0
        for await _ in files.watch("meeting.json") { ticks += 1 }
        #expect(ticks == 0)
    }

    @Test("both service bundles default to the no-op files and the system platform, and carry supplied ones")
    func servicesCarryFilesAndPlatform() async throws {
        let defaulted = SessionServices(
            composer: StubComposer(), shell: StubShell(), intents: StubIntents(), storage: StubStorage(), pill: StubPill())
        #expect(defaulted.files is NoopWidgetFileService)
        #expect(defaulted.platform is SystemWidgetPlatformService)

        let session = SessionServices(
            composer: StubComposer(), shell: StubShell(), intents: StubIntents(), storage: StubStorage(), pill: StubPill(),
            files: FixedFiles(), platform: RecordingPlatform(), sessionId: "s1")
        #expect(try await session.files.read("x.txt") == Data("x.txt".utf8))
        #expect(try await session.files.list(".").map(\.name) == ["meeting.json"])
        #expect(session.platform is RecordingPlatform)
        #expect(session.sessionId == "s1")

        let background = WidgetBackgroundServices(
            shell: StubShell(), storage: StubStorage(), pill: StubPill(), files: FixedFiles(), sessionId: "s1", taskId: nil)
        #expect(try await background.files.list(".").count == 1)
        let defaultedBackground = WidgetBackgroundServices(
            shell: StubShell(), storage: StubStorage(), pill: StubPill(), sessionId: "s1", taskId: nil)
        #expect(defaultedBackground.files is NoopWidgetFileService)
    }
}
