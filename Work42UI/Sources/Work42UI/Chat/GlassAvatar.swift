// GlassAvatar.swift — the one avatar look for chat and meeting surfaces (WOR-235).
//
// A circle of liquid glass tinted with a single plain colour, the initials drawn in that same
// colour. No gradient, no white ring, no drop shadow. `ChatBubble`, `ConversationView` and
// meet42's `MeetAvatarView` all draw through this, so a person looks the same everywhere.

import AppKit
import SwiftUI

/// A liquid-glass circle in one plain colour with the initials in that colour, or a photo.
///
/// On macOS 26 the circle is real Liquid Glass (`.glassEffect`) tinted with `color`. Earlier
/// systems get a thin material, a `color` wash and a hairline inner stroke, which reads the same
/// way without the lensing.
///
/// With an `imageURL` the photo is clipped to a circle and inset inside the glass ring. Until it
/// has loaded, or if it never does (offline, a broken URL), the initials show, so a row never waits
/// on the network.
public struct GlassAvatar: View {
    let initials: String
    let color: Color
    let size: CGFloat
    let imageURL: URL?

    @Environment(\.colorScheme) private var colorScheme
    @State private var photo: NSImage?

    public init(initials: String, color: Color, size: CGFloat = 32) {
        self.init(initials: initials, color: color, size: size, imageURL: nil)
    }

    public init(initials: String, color: Color, size: CGFloat = 32, imageURL: URL?) {
        self.initials = initials
        self.color = color
        self.size = size
        self.imageURL = imageURL
    }

    /// Initials colour: the plain colour in dark mode, deepened a little in light mode so it
    /// stays legible against the pale glass.
    private var initialsColor: Color {
        colorScheme == .dark ? color : color.mix(with: .black, by: 0.18)
    }

    /// Width of the glass ring left visible around a photo.
    private var ring: CGFloat { max(1.5, size * 0.05) }

    public var body: some View {
        ZStack {
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(initialsColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .opacity(photo == nil ? 1 : 0)
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size - ring * 2, height: size - ring * 2)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .modifier(GlassAvatarBackground(color: color))
        .accessibilityLabel(initials)
        .task(id: imageURL) {
            guard let imageURL else { photo = nil; return }
            photo = await GlassAvatarImageCache.shared.image(for: imageURL)
        }
    }
}

/// One decoded image per URL for the whole process, so a hundred rows showing the same person do
/// not fetch it a hundred times. A URL that fails is remembered and not retried, so a broken photo
/// costs one request, not one per redraw.
@MainActor
public final class GlassAvatarImageCache {

    public static let shared = GlassAvatarImageCache()

    private var images: [URL: NSImage] = [:]
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    public init() {}

    /// The cached image for `url` if it has loaded already.
    public func cachedImage(for url: URL) -> NSImage? { images[url] }

    /// The image at `url`: from the cache, else loaded once (concurrent callers share one request).
    /// nil if it cannot be loaded; that outcome is cached too.
    public func image(for url: URL) async -> NSImage? {
        if let image = images[url] { return image }
        if failed.contains(url) { return nil }
        if let running = inFlight[url] { return await running.value }
        let task = Task<NSImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { images[url] = image } else { failed.insert(url) }
        return image
    }
}

private struct GlassAvatarBackground: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(color.opacity(0.28)), in: Circle())
        } else {
            content
                .background(Circle().fill(.ultraThinMaterial))
                .background(Circle().fill(color.opacity(0.22)))
                .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 1))
        }
    }
}

#Preview("GlassAvatar colours and sizes") {
    let colors: [(String, Color)] = [
        ("AL", Color(red: 1.00, green: 0.24, blue: 0.43)),
        ("ML", Color(red: 0.15, green: 0.39, blue: 0.92)),
        ("PR", Color(red: 0.05, green: 0.65, blue: 0.42)),
        ("JD", Color(red: 0.43, green: 0.16, blue: 0.85)),
        ("KT", Color(red: 0.91, green: 0.47, blue: 0.06)),
        ("S2", Color(red: 0.36, green: 0.40, blue: 0.44)),
    ]
    return VStack(alignment: .leading, spacing: 16) {
        ForEach([22.0, 32.0, 40.0], id: \.self) { size in
            HStack(spacing: 10) {
                ForEach(colors, id: \.0) { item in
                    GlassAvatar(initials: item.0, color: item.1, size: size)
                }
            }
        }
    }
    .padding(24)
}
