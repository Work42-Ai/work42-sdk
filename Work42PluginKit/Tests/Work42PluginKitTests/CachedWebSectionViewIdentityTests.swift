// CachedWebSectionViewIdentityTests.swift — WOR-195.
//
// The web view on screen must always be the live view the host hands to `CachedWebSectionView`, because that is
// the one its Refresh, Stop and address bar drive. A host that rebuilds a cached view for the same tab hands over
// a new live view; the old NSView must not stay on screen.

import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Work42UI

@Suite("CachedWebSectionView shows the live view it is given", .serialized)
@MainActor
struct CachedWebSectionViewIdentityTests {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)

    init() {
        _ = NSApplication.shared
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    private func live(_ name: String) throws -> WebSectionLiveView {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w42-identity-\(name).html")
        try Data("<html><body>\(name)</body></html>".utf8).write(to: url)
        return WebSectionView.makeLiveView(spec: WebAppCatalog.debugWeb(url: url))
    }

    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test("handing over a different live view puts its web view on screen and takes the old one off")
    func swappedLiveViewIsTheOneShown() async throws {
        let a = try live("a"), b = try live("b")
        defer { a.teardown(); b.teardown() }
        let host = NSHostingView(rootView: CachedWebSectionView(live: a))
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        #expect(await wait { a.webView.window != nil })

        host.rootView = CachedWebSectionView(live: b)

        #expect(await wait { b.webView.window != nil })
        #expect(await wait { a.webView.window == nil })
        #expect(await wait { b.status == .loaded })
        #expect(b.webView.url?.lastPathComponent == "w42-identity-b.html")
    }

    @Test("handing over the same live view again keeps its web view on screen")
    func sameLiveViewStays() async throws {
        let a = try live("same")
        defer { a.teardown() }
        let host = NSHostingView(rootView: CachedWebSectionView(live: a))
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        #expect(await wait { a.webView.window != nil && a.status == .loaded })
        let generation = a.coordinator.navState.generation

        host.rootView = CachedWebSectionView(live: a)
        try await Task.sleep(for: .milliseconds(400))

        #expect(a.webView.window != nil)
        #expect(a.coordinator.navState.generation == generation)   // not reloaded
    }
}
