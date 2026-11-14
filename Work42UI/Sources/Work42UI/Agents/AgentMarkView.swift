// AgentMarkView.swift — drawing a supported agent: its colour, its mark and its avatar (SDK 2.14.0, ABI 16; WOR-773).
//
// Everything here reads an `AgentIdentity` (`SupportedAgents.identity(for:)`) and nothing else, so an agent looks the same in the chat,
// a pill, a picker and a plugin's widget. The mark files are this target's resources (`provider-logos`).

import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public extension AgentColor {
    /// The colour as SwiftUI draws it.
    var swiftUI: Color { Color(red: red, green: green, blue: blue) }
}

public extension AgentIdentity {
    /// Its brand colour: avatar, chips, glow.
    var tint: Color { color.swiftUI }
    /// The colour of its pointer and tag.
    var pointerTint: Color { pointer.swiftUI }
}

/// The agents' mark files.
public enum AgentMarks {
    /// A bundled mark by file name (`claude-logo`) and extension (`png` or `svg`).
    public static func url(named name: String, withExtension ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "provider-logos")
    }

    /// A bundled mark by its file name, as a SwiftUI image: `template` draws it as a silhouette in the surrounding colour, otherwise it
    /// keeps its own colours. Nil when this build does not carry the file.
    public static func image(asset name: String, template: Bool) -> Image? {
        guard let image = loadedImage(named: name) else { return nil }
        return image.renderingMode(template ? .template : .original)
    }

    /// An agent's mark as a SwiftUI image; nil when it has none, or this build does not carry it.
    public static func image(for identity: AgentIdentity, template: Bool) -> Image? {
        identity.markAsset.flatMap { image(asset: $0, template: template) }
    }

    private static var cache: [String: Image] = [:]

    private static func loadedImage(named name: String) -> Image? {
        if let cached = cache[name] { return cached }
        guard let url = url(named: name, withExtension: "png") else { return nil }
        #if canImport(AppKit)
        guard let platform = NSImage(contentsOf: url) else { return nil }
        // The source PNGs are exported at very different pixel sizes; give them one logical size.
        platform.size = NSSize(width: 64, height: 64)
        let image = Image(nsImage: platform)
        #elseif canImport(UIKit)
        guard let platform = UIImage(contentsOfFile: url.path) else { return nil }
        let image = Image(uiImage: platform)
        #endif
        cache[name] = image
        return image
    }
}

/// An agent's mark at `size`, in its own colours or as a silhouette in the surrounding colour (`markKeepsColor`). Nothing when the
/// agent has no mark.
public struct AgentMark: View {
    private let identity: AgentIdentity
    private let size: CGFloat

    public init(_ identity: AgentIdentity, size: CGFloat) {
        self.identity = identity
        self.size = size
    }

    public var body: some View {
        if let image = AgentMarks.image(for: identity, template: !identity.markKeepsColor) {
            image.resizable().scaledToFit().frame(width: size, height: size)
        }
    }
}

/// An agent's round avatar: its mark in its colour, "42" where it has no mark, ringed when `acting`. The drawing is `Work42Avatar`'s
/// agent variant; this only says whose.
public struct AgentAvatarView: View {
    private let identity: AgentIdentity
    private let size: CGFloat
    private let acting: Bool
    private let ring: Color?

    public init(_ identity: AgentIdentity, size: CGFloat, acting: Bool = false, ring: Color? = nil) {
        self.identity = identity
        self.size = size
        self.acting = acting
        self.ring = ring
    }

    public var body: some View {
        Work42Avatar(
            agentMark: AgentMarks.image(for: identity, template: true), tint: identity.tint, size: .nearest(to: size), acting: acting,
            ring: ring)
    }
}
