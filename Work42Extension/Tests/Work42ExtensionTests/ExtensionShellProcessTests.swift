// ExtensionShellProcessTests.swift — the SDK 3.3.0 additions over the in-memory wire: `shell.start`, `shell.run(timeout:)`,
// `files.write` and `files.remove`, from the extension's proxies to the host's services.

import Foundation
import Testing
import Work42Extension
import Work42PluginKit

// MARK: - Host-side fakes

/// A host shell whose started commands the test drives line by line.
nonisolated final class ScriptedShell: WidgetShellService, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    private var timeoutsSeen: [Duration] = []
    private var stops = 0
    private var open: [AsyncStream<WidgetShellOutput>.Continuation] = []
    var refuseStart: WidgetServiceError?

    var started: [String] { lock.withLock { commands } }
    var timeouts: [Duration] { lock.withLock { timeoutsSeen } }
    var stopCount: Int { lock.withLock { stops } }

    func run(command: String) async throws -> WidgetShellResult {
        WidgetShellResult(stdout: "ran \(command)\n", stderr: "", exitCode: 0)
    }

    func run(command: String, timeout: Duration) async throws -> WidgetShellResult {
        lock.withLock { timeoutsSeen.append(timeout) }
        return WidgetShellResult(stdout: "timed \(command)\n", stderr: "", exitCode: 0)
    }

    func start(command: String) async throws -> WidgetShellProcess {
        if let refuseStart { throw refuseStart }
        let (stream, continuation) = AsyncStream<WidgetShellOutput>.makeStream()
        lock.withLock { commands.append(command); open.append(continuation) }
        return WidgetShellProcess(id: UUID(), output: stream, stop: { [weak self] in
            self?.lock.withLock { self?.stops += 1 }
            continuation.yield(.exited(143))
            continuation.finish()
        })
    }

    /// Emits `output` from the most recently started command.
    func emit(_ output: WidgetShellOutput) { lock.withLock { open.last }?.yield(output) }
    func finishOutput() { lock.withLock { open.last }?.finish() }
}

/// A host file service that remembers writes and removals.
nonisolated final class WritableFiles: WidgetFileService, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    func read(_ relativePath: String) async throws -> Data { lock.withLock { files[relativePath] } ?? Data() }
    func list(_ relativeDir: String) async throws -> [WidgetFileEntry] { [] }
    func watch(_ relativePath: String) -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func write(_ relativePath: String, data: Data) async throws { lock.withLock { files[relativePath] = data } }
    func remove(_ relativePath: String) async throws { _ = lock.withLock { files.removeValue(forKey: relativePath) } }
    func contents(_ path: String) -> Data? { lock.withLock { files[path] } }
}

private func services(shell: any WidgetShellService, files: any WidgetFileService = NoopWidgetFileService()) -> SessionServices {
    SessionServices(composer: NullComposer(), shell: shell, intents: NullIntents(), storage: MemoryStore(), pill: NullPill(),
                    files: files, sessionId: "s1", worktreePath: "/tmp/s1")
}

/// Polls `condition` for up to two seconds, since a stop travels through a detached task.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<80 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

// MARK: - Tests

@Suite("SDK 3.3.0 over the extension wire", .serialized)
@MainActor
struct ExtensionShellProcessTests {

    private func connect(_ shell: any WidgetShellService, files: any WidgetFileService = NoopWidgetFileService())
        throws -> (Pair, SessionServices) {
        let pair = Pair(widgets: [])
        pair.link.server.attach(services(shell: shell, files: files), widgetId: "rec", sessionId: "s1")
        let remote = ExtensionServices.session(channel: try #require(pair.runtime.channel), sessionId: "s1",
                                               widgetId: "rec", worktreePath: nil)
        return (pair, remote)
    }

    @Test("a started command streams its lines in order and ends with exited")
    func startStreamsAndEnds() async throws {
        let shell = ScriptedShell()
        let (pair, remote) = try connect(shell)

        let process = try await remote.shell.start(command: "serve")
        shell.emit(.stdout("one"))
        shell.emit(.stderr("warn"))
        shell.emit(.exited(0))
        shell.finishOutput()
        var seen: [WidgetShellOutput] = []
        for await line in process.output { seen.append(line) }

        #expect(seen == [.stdout("one"), .stderr("warn"), .exited(0)])
        #expect(shell.started == ["serve"])
        #expect(await eventually { pair.link.server.runningProcessCount == 0 && pair.link.server.openStreamCount == 0 })
    }

    @Test("stop() ends the command and its stream still delivers exited")
    func stopEndsTheCommand() async throws {
        let shell = ScriptedShell()
        let (pair, remote) = try connect(shell)
        let process = try await remote.shell.start(command: "sleep 60")
        #expect(pair.link.server.runningProcessCount == 1)

        await process.stop()
        var seen: [WidgetShellOutput] = []
        for await line in process.output { seen.append(line) }

        #expect(seen == [.exited(143)])
        #expect(shell.stopCount == 1)
        #expect(await eventually { pair.link.server.runningProcessCount == 0 })
    }

    @Test("a command the host refuses to start throws to the caller, with the host's words")
    func startRefusalIsThrown() async throws {
        let shell = ScriptedShell()
        shell.refuseStart = WidgetServiceError(message: "cannot start: no such folder", suggestion: "pick a folder")
        let (pair, remote) = try connect(shell)

        let error = await #expect(throws: WidgetServiceError.self) { _ = try await remote.shell.start(command: "serve") }

        #expect(error?.message == "cannot start: no such folder" && error?.suggestion == "pick a folder")
        #expect(pair.link.server.runningProcessCount == 0)
        #expect(pair.runtime.channel?.openStreamCount == 0)
    }

    @Test("a host without start() answers with a named error, not a crash")
    func hostWithoutStart() async throws {
        let (_, remote) = try connect(CountingShell())
        let error = await #expect(throws: WidgetServiceError.self) { _ = try await remote.shell.start(command: "serve") }
        #expect(error?.message == "this host does not support shell.start(command:)")
        #expect(error?.suggestion == "run inside Work42 3.3 or later")
    }

    @Test("a consumer that stops reading stops the command")
    func consumerStopsReading() async throws {
        let shell = ScriptedShell()
        let (pair, remote) = try connect(shell)
        let process = try await remote.shell.start(command: "serve")

        let reader = Task { @MainActor in for await _ in process.output {} }
        shell.emit(.stdout("hello"))
        try await Task.sleep(for: .milliseconds(50))
        reader.cancel()

        #expect(await eventually { shell.stopCount == 1 })
        #expect(await eventually { pair.link.server.runningProcessCount == 0 })
    }

    @Test("a command stops when its widget's scope ends, and the extension's stream finishes")
    func scopeEndStopsTheCommand() async throws {
        let shell = ScriptedShell()
        let (pair, remote) = try connect(shell)
        let process = try await remote.shell.start(command: "serve")
        #expect(pair.link.server.runningProcessCount == 1)

        pair.link.server.detach(widgetId: "rec", sessionId: "s1")

        var seen: [WidgetShellOutput] = []
        for await line in process.output { seen.append(line) }   // finishes: the host told the extension it is over
        #expect(await eventually { shell.stopCount == 1 })
        #expect(pair.link.server.runningProcessCount == 0)
        #expect(pair.link.server.openStreamCount == 0)
    }

    @Test("when the connection is lost the command stops and the stream ends")
    func connectionLossStopsTheCommand() async throws {
        let shell = ScriptedShell()
        let (pair, remote) = try connect(shell)
        let process = try await remote.shell.start(command: "serve")

        pair.crash()

        var count = 0
        for await _ in process.output { count += 1 }
        #expect(count == 0)
        #expect(pair.link.server.runningProcessCount == 0)
        #expect(await eventually { shell.stopCount == 1 })
    }

    @Test("start carries a request id and a request id that arrives twice starts the command once")
    func startIsNeverRunTwice() async throws {
        #expect(ExtensionCall.nonIdempotentMethods.isSuperset(of: ["shell.start", "files.write", "files.remove"]))
        let pair = Pair(widgets: [])
        let shell = ScriptedShell()
        pair.link.server.attach(services(shell: shell), widgetId: "rec", sessionId: "s1")
        let call = try ExtensionCall.make(
            service: "shell", method: "start", sessionId: "s1", widgetId: "rec",
            payload: ExtensionSubscription(streamId: UUID(), arguments: ExtensionPayload.Command(command: "serve")))
        #expect(call.requestId != nil)

        #expect(await pair.link.server.handle(call).error == nil)
        let again = await pair.link.server.handle(call)

        #expect(again.error?.message.contains("never run twice") == true)
        #expect(shell.started == ["serve"])
    }

    @Test("run(command:timeout:) sends the caller's timeout to the host")
    func timeoutReachesTheHost() async throws {
        let shell = ScriptedShell()
        let (_, remote) = try connect(shell)

        let result = try await remote.shell.run(command: "sleep 20", timeout: .seconds(30))
        let plain = try await remote.shell.run(command: "ls")

        #expect(result.stdout == "timed sleep 20\n")
        #expect(shell.timeouts == [.seconds(30)])
        #expect(plain.stdout == "ran ls\n")   // the 10 s default path is untouched
    }

    @Test("files.write and files.remove reach the host's files, and a refused path never leaves the extension")
    func writeAndRemove() async throws {
        let files = WritableFiles()
        let (pair, remote) = try connect(CountingShell(), files: files)

        try await remote.files.write("notes/a.md", data: Data("hi".utf8))
        #expect(files.contents("notes/a.md") == Data("hi".utf8))
        try await remote.files.remove("notes/a.md")
        #expect(files.contents("notes/a.md") == nil)

        for bad in ["/etc/passwd", "../x", "a/../../x", "~/x", ""] {
            let writeError = await #expect(throws: WidgetServiceError.self) { try await remote.files.write(bad, data: Data()) }
            #expect(writeError?.isNotPermitted == true, "write \(bad)")
            let removeError = await #expect(throws: WidgetServiceError.self) { try await remote.files.remove(bad) }
            #expect(removeError?.isNotPermitted == true, "remove \(bad)")
        }

        // A call that bypasses the proxy is refused by the host too.
        let raw = try ExtensionCall.make(service: "files", method: "write", sessionId: "s1", widgetId: "rec",
                                         payload: ExtensionPayload.FileWrite(path: "../x", data: Data()))
        #expect(await pair.link.server.handle(raw).error?.isNotPermitted == true)
        #expect(files.contents("../x") == nil)
        let names = Set(pair.link.ledger.entries(forSession: "s1").map(\.name))
        #expect(names == ["files.write", "files.remove"])
    }

    @Test("a host whose files cannot write answers with a named error")
    func hostWithoutWrite() async throws {
        let (_, remote) = try connect(CountingShell())
        let error = await #expect(throws: WidgetServiceError.self) { try await remote.files.write("a.txt", data: Data()) }
        #expect(error?.message == "this host does not support files.write(_:data:)")
    }
}
