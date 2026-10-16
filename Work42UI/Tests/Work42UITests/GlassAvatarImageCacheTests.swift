import AppKit
import Foundation
import Testing
@testable import Work42UI

@MainActor
struct GlassAvatarImageCacheTests {

    private func pngData() throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wor235-\(UUID().uuidString)-\(name)")
    }

    @Test func loadsALocalImageOnceAndCachesIt() async throws {
        let url = tempURL("photo.png")
        try pngData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = GlassAvatarImageCache()

        #expect(cache.cachedImage(for: url) == nil)
        let first = await cache.image(for: url)
        #expect(first != nil)
        #expect(cache.cachedImage(for: url) != nil)

        // Served from memory: still there after the file is gone.
        try FileManager.default.removeItem(at: url)
        #expect(await cache.image(for: url) != nil)
    }

    @Test func anUnreachableURLGivesNilAndIsNotRetried() async throws {
        let url = tempURL("missing.png")
        let cache = GlassAvatarImageCache()

        #expect(await cache.image(for: url) == nil)

        // The file appears afterwards; a remembered failure must not hit the network (disk) again.
        try pngData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await cache.image(for: url) == nil)
        #expect(cache.cachedImage(for: url) == nil)
    }

    @Test func concurrentCallersShareOneLoad() async throws {
        let url = tempURL("shared.png")
        try pngData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = GlassAvatarImageCache()

        async let a = cache.image(for: url)
        async let b = cache.image(for: url)
        let (imageA, imageB) = await (a, b)
        #expect(imageA != nil)
        #expect(imageA === imageB)
    }

    @Test func anUndecodableFileIsAFailure() async throws {
        let url = tempURL("not-an-image.png")
        try Data("this is not a png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = GlassAvatarImageCache()
        #expect(await cache.image(for: url) == nil)
    }
}
