// BrowserSurfaceRecoveryTests.swift — WOR-135.
//
// A real `BrowserSurface` mounted in a window (WebKit only loads for a view that is in one), with its cache entry
// torn down while it is on screen — the Home Jira board when its widget is deactivated around a session visit.
// The surface must rebuild and finish loading instead of showing a spinner forever with no Refresh.

import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Work42PluginKit
@testable import Work42UI

@Suite("BrowserSurface recovers from a torn-down cache entry", .serialized)
@MainActor
struct BrowserSurfaceRecoveryTests {

    private let directory: URL
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)

    init() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("w42-surface-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    }

    private func page(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("<html><body>\(name)</body></html>".utf8).write(to: url)
        return url
    }

    private func mount(key: String, url: URL, configure: ((BrowserWidgetModel) -> Void)? = nil) -> NSHostingView<BrowserSurface> {
        let host = NSHostingView(rootView: BrowserSurface(
            spec: BrowserSurfaceSpec(url: url, dataStoreKey: "w42-surface-recovery", title: "Board"),
            cacheKey: key,
            configure: configure
        ))
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        return host
    }

    private func wait(timeout: TimeInterval = 60, until condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    /// The live view the surface currently shows for `key`, if its model and tab are cached.
    private func liveView(_ key: String) -> WebSectionLiveView? {
        guard let tab = BrowserSurface.model(forKey: key)?.tabs.first else { return nil }
        return BrowserSurfaceCache.shared.existing(forKey: "\(key):\(tab.id)")
    }

    @Test("teardown while mounted: the surface rebuilds a model and a view that finishes loading")
    func rebuildsAfterTeardownWhileMounted() async throws {
        let key = "recovery-mounted-\(UUID().uuidString)"
        let url = try page("board.html")
        let host = mount(key: key, url: url)
        defer { host.removeFromSuperview(); BrowserSurfaceCache.shared.teardown(key: key) }
        #expect(await wait { liveView(key)?.status == .loaded })
        let first = liveView(key)

        BrowserSurfaceCache.shared.teardown(key: key)

        #expect(await wait { liveView(key)?.status == .loaded && liveView(key) !== first })
        #expect(liveView(key)?.webView.url == url)
        #expect(BrowserSurface.model(forKey: key)?.tabs.count == 1)
    }

    @Test("a deactivate that lands after the surface remounted does not leave it empty")
    func lateDeactivateAfterRemount() async throws {
        let key = "recovery-late-\(UUID().uuidString)"
        let url = try page("board.html")
        var host = mount(key: key, url: url)
        #expect(await wait { liveView(key)?.status == .loaded })

        host.removeFromSuperview()                       // Home unmounted (a session is open)
        host = mount(key: key, url: url)                 // Home shown again
        try await Task.sleep(for: .milliseconds(400))    // the remounted surface has resolved
        BrowserSurfaceCache.shared.teardown(key: key)    // the old widget's deactivate arrives late
        defer { host.removeFromSuperview(); BrowserSurfaceCache.shared.teardown(key: key) }

        #expect(await wait { liveView(key)?.status == .loaded })
        #expect(liveView(key)?.webView.window != nil)
    }

    @Test("configure runs again for the rebuilt model so the widget's reference is not stale")
    func configureRunsForRebuiltModel() async throws {
        let key = "recovery-configure-\(UUID().uuidString)"
        let url = try page("board.html")
        var configured: [ObjectIdentifier] = []
        let host = mount(key: key, url: url) { configured.append(ObjectIdentifier($0)) }
        defer { host.removeFromSuperview(); BrowserSurfaceCache.shared.teardown(key: key) }
        #expect(await wait { liveView(key)?.status == .loaded })

        BrowserSurfaceCache.shared.teardown(key: key)
        #expect(await wait { liveView(key)?.status == .loaded && configured.count == 2 })
        #expect(configured[0] != configured[1])
    }

    @Test("a surface that is removed together with its teardown does not rebuild anything")
    func closingDoesNotLeakAnEntry() async throws {
        let key = "recovery-close-\(UUID().uuidString)"
        let url = try page("board.html")
        let host = mount(key: key, url: url)
        #expect(await wait { liveView(key)?.status == .loaded })

        host.removeFromSuperview()                      // the widget closes: view goes away,
        BrowserSurfaceCache.shared.teardown(key: key)   // then its deactivate tears the cache down
        try await Task.sleep(for: .seconds(1))

        #expect(BrowserSurface.model(forKey: key) == nil)
        #expect(BrowserSurfaceCache.shared.existing(forKey: "\(key):anything") == nil)
    }
}
