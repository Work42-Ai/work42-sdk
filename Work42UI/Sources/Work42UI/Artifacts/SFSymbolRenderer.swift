// SFSymbolRenderer.swift — draws SF Symbols for artifacts and markdown documents (WOR-213, WOR-216).
//
// Agents write `<i data-sf="checkmark.circle.fill"></i>`; `work42 artifact set`
// rewrites it into a `w42-sf` span whose CSS mask points at
// `_w42/sf/checkmark.circle.fill.png`. This renders that PNG with the system
// symbol API, so the app uses SF Symbols exactly as an app is allowed to — the
// glyphs are drawn at runtime, never shipped as files. The PNG is a black glyph on
// clear; the page uses only its alpha as a mask, so any text colour tints it.

import AppKit
import Foundation

public enum SFSymbolRenderer {

    /// Longest side of the rendered PNG, in pixels (≈ 3x a 64 pt symbol).
    public static let pixelSize = 192

    /// Symbol names are lowercase letters, digits and dots (`checkmark.circle.fill`).
    public nonisolated static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80 && name.range(of: "^[a-z0-9.]+$", options: .regularExpression) != nil
    }

    /// PNG data for `name`, or nil when it is not a symbol this macOS knows.
    /// Main-actor only: AppKit image drawing.
    @MainActor
    public static func pngData(for name: String) -> Data? {
        guard isValidName(name),
              let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configured = base.withSymbolConfiguration(.init(pointSize: 64, weight: .regular)) ?? base
        let side = pixelSize
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        // Aspect-fit into the square with a little padding, centred.
        let natural = configured.size
        guard natural.width > 0, natural.height > 0 else { return nil }
        let inset: CGFloat = 8
        let box = CGFloat(side) - inset * 2
        let scale = min(box / natural.width, box / natural.height)
        let drawn = NSSize(width: natural.width * scale, height: natural.height * scale)
        let rect = NSRect(
            x: (CGFloat(side) - drawn.width) / 2, y: (CGFloat(side) - drawn.height) / 2,
            width: drawn.width, height: drawn.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        // A template image draws in solid black here; only its alpha matters.
        configured.isTemplate = true
        configured.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Thread-safe memo of rendered symbols (nil results are cached too, so a bad name
/// is rendered at most once). Requests arrive on the server's queue, so rendering
/// hops to the main thread.
public nonisolated final class SFSymbolCache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data?] = [:]

    /// `render` produces the PNG for a name on a cache miss; injected so tests need no AppKit.
    private let render: @Sendable (String) -> Data?

    public init(render: @escaping @Sendable (String) -> Data? = SFSymbolCache.renderOnMain) {
        self.render = render
    }

    /// PNG for `name`, or nil for an invalid or unknown symbol.
    public func png(for name: String) -> Data? {
        guard SFSymbolRenderer.isValidName(name) else { return nil }
        lock.lock()
        if let hit = store[name] { lock.unlock(); return hit }
        lock.unlock()
        let data = render(name)
        lock.lock(); store[name] = .some(data); lock.unlock()
        return data
    }

    @Sendable
    public static func renderOnMain(_ name: String) -> Data? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { SFSymbolRenderer.pngData(for: name) }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { SFSymbolRenderer.pngData(for: name) } }
    }
}
