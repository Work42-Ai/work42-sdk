// ExtensionDiskAutomationTests.swift — SDK 3.5.0's `services.diskRead` and `services.automation` over the in-memory wire, from
// the extension's proxies to the services Work42 answers with.

import Foundation
import Testing
import Work42Extension
import Work42PluginKit

// MARK: - Host-side fake

nonisolated final class FakeDiskAndAutomation: WidgetDiskReadService, WidgetAutomationService, @unchecked Sendable {
    private let lock = NSLock()
    private var statPaths: [String] = []
    private var listCalls: [(path: String, cursor: String?, limit: Int?)] = []
    private var readCalls: [(path: String, offset: Int64, length: Int)] = []
    private var sent: [AppleEventRequest] = []
    var refuse: WidgetServiceError?

    var stats: [String] { lock.withLock { statPaths } }
    var lists: [(path: String, cursor: String?, limit: Int?)] { lock.withLock { listCalls } }
    var reads: [(path: String, offset: Int64, length: Int)] { lock.withLock { readCalls } }
    var events: [AppleEventRequest] { lock.withLock { sent } }

    var capabilities: WidgetCapabilities {
        WidgetCapabilities(permissions: UnsupportedWidgetCapability(), audio: UnsupportedWidgetCapability(),
                           speech: UnsupportedWidgetCapability(), calendar: UnsupportedWidgetCapability(),
                           diskRead: self, automation: self)
    }

    func stat(path: String) async throws -> DiskEntry {
        if let refuse { throw refuse }
        lock.withLock { statPaths.append(path) }
        return DiskEntry(name: "mail.db", kind: .file, size: 42, modifiedAt: Date(timeIntervalSince1970: 1_000))
    }

    func list(path: String, cursor: String?, limit: Int?) async throws -> DiskListing {
        if let refuse { throw refuse }
        lock.withLock { listCalls.append((path, cursor, limit)) }
        return DiskListing(entries: [DiskEntry(name: "a", kind: .directory), DiskEntry(name: "b", kind: .symlink, linkTarget: "/x")],
                           nextCursor: cursor == nil ? "2" : nil)
    }

    func read(path: String, offset: Int64, length: Int) async throws -> DiskChunk {
        if let refuse { throw refuse }
        lock.withLock { readCalls.append((path, offset, length)) }
        return DiskChunk(data: Data([1, 2, 3]), offset: offset, size: 3, isEnd: true)
    }

    func send(_ request: AppleEventRequest) async throws -> AppleEventReply {
        if let refuse { throw refuse }
        lock.withLock { sent.append(request) }
        return AppleEventReply(value: .list([.string("INBOX"), .int(3)]))
    }
}

// MARK: - Tests

// In the suite of the 3.3.0 capability services: both set the one global capability provider, and a suite's tests run one at a time
// but two suites run side by side.
extension ExtensionCapabilityTests {

    private func connectDisk(_ fake: FakeDiskAndAutomation?) throws -> SessionServices {
        let pair = Pair(widgets: [])
        if let fake { pair.link.server.capabilityProvider = { _ in fake.capabilities } }
        let channel = try #require(pair.runtime.channel)
        WidgetCapabilityRegistry.provider = ExtensionCapabilityProvider(channel: channel)
        return ExtensionServices.session(channel: channel, sessionId: "s1", widgetId: "mail", worktreePath: nil)
    }

    private func resetDiskProvider() { WidgetCapabilityRegistry.provider = nil }

    @Test("stat reaches the host's disk service with its path and returns what it answers")
    func diskStat() async throws {
        defer { resetDiskProvider() }
        let fake = FakeDiskAndAutomation()
        let services = try connectDisk(fake)

        let entry = try await services.diskRead.stat(path: "~/Library/Mail")
        #expect(entry == DiskEntry(name: "mail.db", kind: .file, size: 42, modifiedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(fake.stats == ["~/Library/Mail"])
    }

    @Test("list pages through the host's disk service with its cursor and limit")
    func diskList() async throws {
        defer { resetDiskProvider() }
        let fake = FakeDiskAndAutomation()
        let services = try connectDisk(fake)

        let page = try await services.diskRead.list(path: "~/Library/Mail", cursor: nil, limit: 2)
        #expect(page.entries.map(\.name) == ["a", "b"])
        #expect(page.entries[1].kind == .symlink && page.entries[1].linkTarget == "/x")
        #expect(page.nextCursor == "2")
        let next = try await services.diskRead.list(path: "~/Library/Mail", cursor: page.nextCursor, limit: 2)
        #expect(next.nextCursor == nil)
        #expect(fake.lists.map(\.cursor) == [nil, "2"])
        #expect(fake.lists.first?.limit == 2)
    }

    @Test("read reaches the host's disk service with its offset and length and returns the bytes")
    func diskRead() async throws {
        defer { resetDiskProvider() }
        let fake = FakeDiskAndAutomation()
        let services = try connectDisk(fake)

        let chunk = try await services.diskRead.read(path: "/var/db/x", offset: 7, length: 100)
        #expect(chunk == DiskChunk(data: Data([1, 2, 3]), offset: 7, size: 3, isEnd: true))
        #expect(fake.reads.first?.path == "/var/db/x" && fake.reads.first?.offset == 7 && fake.reads.first?.length == 100)
    }

    @Test("a permission refusal keeps its prefix, so a plugin can tell which permission was missing")
    func diskRefusalCrossesTheWire() async throws {
        defer { resetDiskProvider() }
        let fake = FakeDiskAndAutomation()
        fake.refuse = WidgetServiceError(message: PluginPermissionError.deniedPrefix + "full-disk-access: turn it on in System Settings")
        let services = try connectDisk(fake)

        do {
            _ = try await services.diskRead.read(path: "/x", offset: 0, length: 1)
            Issue.record("a refused read went through")
        } catch let error as WidgetServiceError {
            #expect(error.message == PluginPermissionError.deniedPrefix + "full-disk-access: turn it on in System Settings")
        }
    }

    @Test("an Apple Event travels as typed data and its reply comes back typed")
    func automationRoundTrip() async throws {
        defer { resetDiskProvider() }
        let fake = FakeDiskAndAutomation()
        let services = try connectDisk(fake)

        let message = AppleEventValue.object(AppleEventObjectSpecifier(
            desiredClass: "mbxp", container: .null, form: "name", data: .string("INBOX")))
        let request = AppleEventRequest(
            target: "com.apple.mail", eventClass: "core", eventID: "getd",
            parameters: [AppleEventField(.directObject, message), AppleEventField("data", .record([AppleEventField("pnam", .bool(true))]))],
            timeoutSeconds: 10)
        let reply = try await services.automation.send(request)

        #expect(reply == AppleEventReply(value: .list([.string("INBOX"), .int(3)])))
        #expect(fake.events == [request])
    }

    @Test("an Apple Event is never sent twice: it is a non-idempotent call that carries a request id")
    func automationIsNotRepeated() {
        #expect(ExtensionCall.nonIdempotentMethods.contains("automation.send"))
        #expect(!ExtensionCall.nonIdempotentMethods.contains("diskRead.read"))
    }

    @Test("a host with no capability services answers with a named error")
    func diskAutomationNoProvider() async throws {
        defer { resetDiskProvider() }
        let services = try connectDisk(nil)

        await #expect(throws: WidgetServiceError.self) { _ = try await services.diskRead.stat(path: "/") }
        await #expect(throws: WidgetServiceError.self) {
            _ = try await services.automation.send(AppleEventRequest(target: "com.apple.mail", eventClass: "core", eventID: "getd"))
        }
    }

    @Test("four-character codes: only four ASCII characters are a code")
    func appleEventCodes() {
        #expect(AppleEventCode("core").number == 0x636F7265)
        #expect(AppleEventCode("----").number == 0x2D2D2D2D)
        #expect(AppleEventCode("ID  ").number != nil)
        #expect(AppleEventCode("core1").number == nil)
        #expect(AppleEventCode("abc").number == nil)
        #expect(AppleEventCode("é123").number == nil)
    }

    @Test("a value round-trips through JSON, including nesting")
    func appleEventValueRoundTrip() throws {
        let value = AppleEventValue.record([
            AppleEventField("lst ", .list([.int(1), .double(2.5), .string("x"), .null, .enumerator("yes "), .type("long")])),
            AppleEventField("when", .date(Date(timeIntervalSince1970: 86_400))),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(AppleEventValue.self, from: data) == value)
    }
}
