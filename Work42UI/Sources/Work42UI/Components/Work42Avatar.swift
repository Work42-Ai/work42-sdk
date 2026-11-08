// Work42Avatar.swift — the one avatar of a person or an agent, on every surface (WOR-717).
//
// It owns the photo or initials, the person's colour, the ring, dimmed, the agent variant and the device badge (a laptop or an
// iPad), at a fixed set of sizes, so the same person looks the same everywhere but for size.
//
// A person's face is Liquid Glass (`GlassAvatar`'s: `.glassEffect` tinted with the colour on macOS 26 / iOS 26, a material, a wash
// and a hairline before). The badge and the ring are drawn as content of that glass view, not as overlays outside it: in a
// `GlassEffectContainer` (the session tab strip) the container's glass layer covers anything that is not a glass view's own
// content, which hid the badge. Content of a glass view is above its glass, so the badge is in front in every container.

import SwiftUI

/// The device a person's avatar names with a badge at its bottom right.
public enum Work42AvatarDevice: Sendable, Equatable {
    case mac
    case ipad
    /// No badge: a person with no known device, or an agent.
    case none

    /// The badge's SF Symbol, nil for `.none`.
    public var symbolName: String? {
        switch self {
        case .mac: "laptopcomputer"
        case .ipad: "ipad"
        case .none: nil
        }
    }
}

/// The device badge of an avatar: its diameter, its glyph's size, and how far it sits past the avatar's bottom right corner.
public struct Work42AvatarBadge: Equatable, Sendable {
    public var diameter: CGFloat
    public var glyph: CGFloat
    public var offset: CGSize

    public init(diameter: CGFloat, glyph: CGFloat, offset: CGSize) {
        self.diameter = diameter
        self.glyph = glyph
        self.offset = offset
    }

    /// The smallest glyph the badge draws, so a laptop or an iPad stays legible.
    public static let minimumGlyph: CGFloat = 7

    fileprivate init(diameter: CGFloat, glyph: CGFloat) {
        self.init(
            diameter: diameter, glyph: glyph,
            offset: CGSize(width: (diameter * 0.3).rounded(), height: (diameter * 0.2).rounded()))
    }
}

/// The avatar sizes. The raw value is the diameter in points.
public enum Work42AvatarSize: Int, CaseIterable, Sendable {
    case s16 = 16
    case s18 = 18
    case s20 = 20
    case s22 = 22
    case s24 = 24
    case s26 = 26
    case s28 = 28
    case s32 = 32
    case s36 = 36
    case s44 = 44

    public var diameter: CGFloat { CGFloat(rawValue) }

    /// The badge at this size (avatar / badge / glyph): 18/12/7, 20/12/7, 24/13/7, 28/14/8, 36/20/10. Every glyph is at least 7 pt.
    public var badge: Work42AvatarBadge {
        switch self {
        case .s16, .s18, .s20, .s22: Work42AvatarBadge(diameter: 12, glyph: 7)
        case .s24: Work42AvatarBadge(diameter: 13, glyph: 7)
        case .s26, .s28: Work42AvatarBadge(diameter: 14, glyph: 8)
        case .s32: Work42AvatarBadge(diameter: 16, glyph: 9)
        case .s36: Work42AvatarBadge(diameter: 20, glyph: 10)
        case .s44: Work42AvatarBadge(diameter: 22, glyph: 11)
        }
    }

    /// The size closest to `points`, for a caller that still holds a number.
    public static func nearest(to points: CGFloat) -> Work42AvatarSize {
        allCases.min { abs($0.diameter - points) < abs($1.diameter - points) } ?? .s32
    }
}

/// A person's or an agent's round avatar.
///
/// A person: a photo, or initials in `color`, with an optional device badge. An agent: a provider's mark in its tint, with no badge.
/// `ring` is the colour of what the avatar sits on, drawn 2 pt around it so an overlapping avatar reads as a cut. Where the badge
/// hangs past the avatar (`size.badge.offset`), the container must leave room and must not clip it.
public struct Work42Avatar: View {
    private enum Content {
        case person(initials: String, color: Color, imageURL: URL?, device: Work42AvatarDevice, dimmed: Bool)
        case agent(mark: Image?, tint: Color, fallbackText: String, acting: Bool)
    }

    private let content: Content
    private let size: Work42AvatarSize
    private let ring: Color?

    @Environment(\.colorScheme) private var colorScheme
    @State private var photo: PlatformImage?

    /// A person. `dimmed` greys a device that is not connected.
    public init(
        initials: String, color: Color, imageURL: URL? = nil, device: Work42AvatarDevice = .none,
        size: Work42AvatarSize, ring: Color? = nil, dimmed: Bool = false
    ) {
        self.content = .person(initials: initials, color: color, imageURL: imageURL, device: device, dimmed: dimmed)
        self.size = size
        self.ring = ring
    }

    /// An agent: `mark` (a template image) in `tint`, or `fallbackText` where it has no mark. `acting` rings it in the accent colour.
    public init(
        agentMark mark: Image?, tint: Color, fallbackText: String = "42", size: Work42AvatarSize, acting: Bool = false,
        ring: Color? = nil
    ) {
        self.content = .agent(mark: mark, tint: tint, fallbackText: fallbackText, acting: acting)
        self.size = size
        self.ring = ring
    }

    public var body: some View {
        switch content {
        case let .person(initials, color, imageURL, device, dimmed):
            person(initials: initials, color: color, imageURL: imageURL, device: device, dimmed: dimmed)
        case let .agent(mark, tint, fallbackText, acting):
            agent(mark: mark, tint: tint, fallbackText: fallbackText, acting: acting)
        }
    }

    // MARK: Person

    private func person(initials: String, color: Color, imageURL: URL?, device: Work42AvatarDevice, dimmed: Bool) -> some View {
        let diameter = size.diameter
        let inset = max(1.5, diameter * 0.05)
        // A device that is not connected is greyed by its colour and its photo, not by a filter on the whole view: a filter
        // would flatten the glass, and the badge stays at full strength.
        let tint = dimmed ? Color.gray : color
        let initialsColor = colorScheme == .dark ? tint : tint.mix(with: .black, by: 0.18)
        return ZStack {
            Text(initials)
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(initialsColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .opacity(photo == nil ? (dimmed ? 0.6 : 1) : 0)
            if let photo {
                Image(platformImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter - inset * 2, height: diameter - inset * 2)
                    .clipShape(Circle())
                    .grayscale(dimmed ? 1 : 0)
                    .opacity(dimmed ? 0.6 : 1)
            }
        }
        .frame(width: diameter, height: diameter)
        // The ring and the badge are CONTENT of the glass view, not siblings or overlays outside it. Inside a
        // `GlassEffectContainer` the container's glass layer is drawn over everything that is not the content of a glass view
        // (that is how the badge, an overlay after `.glassEffect`, was covered); a glass view's own content (the initials) is
        // drawn above its glass. The badge is therefore above the face by construction, with or without a container around.
        // The ring is a stroke outside the face, so an overlapping neighbour's glass does not cover the cut either.
        .overlay {
            if let ring { Circle().strokeBorder(ring, lineWidth: 2).padding(-2).allowsHitTesting(false) }
        }
        .overlay(alignment: .bottomTrailing) { badge(device) }
        .modifier(GlassAvatarBackground(color: tint))
        .accessibilityLabel(initials)
        .task(id: imageURL) {
            guard let imageURL else { photo = nil; return }
            photo = await GlassAvatarImageCache.shared.image(for: imageURL)
        }
    }

    @ViewBuilder
    private func badge(_ device: Work42AvatarDevice) -> some View {
        if let symbol = device.symbolName {
            let badge = size.badge
            Image(systemName: symbol)
                .font(.system(size: badge.glyph, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: badge.diameter, height: badge.diameter)
                .background(Circle().fill(DT.surface))
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                .offset(x: badge.offset.width, y: badge.offset.height)
        }
    }

    // MARK: Agent

    private func agent(mark: Image?, tint: Color, fallbackText: String, acting: Bool) -> some View {
        let diameter = size.diameter
        let resolved = DT.resolveChipTint(tint, colorScheme: colorScheme)
        return ZStack {
            Circle().fill(resolved.fill)
            Circle().strokeBorder(resolved.stroke, lineWidth: 0.5)
            if let mark {
                mark.renderingMode(.template).resizable().scaledToFit().frame(width: diameter * 0.5, height: diameter * 0.5)
            } else {
                Text(fallbackText).font(.system(size: diameter * 0.4, weight: .semibold))
            }
        }
        .foregroundStyle(resolved.foreground)
        .frame(width: diameter, height: diameter)
        .overlay {
            if acting {
                Circle().strokeBorder(DT.systemAccent, lineWidth: 2)
            } else if let ring {
                Circle().strokeBorder(ring, lineWidth: 2)
            }
        }
    }
}

#Preview("Work42Avatar sizes and badges") {
    VStack(alignment: .leading, spacing: 16) {
        ForEach([Work42AvatarDevice.none, .mac, .ipad], id: \.self) { device in
            HStack(spacing: 14) {
                ForEach(Work42AvatarSize.allCases, id: \.self) { size in
                    Work42Avatar(initials: "AL", color: .pink, device: device, size: size)
                }
            }
        }
        HStack(spacing: 14) {
            Work42Avatar(initials: "AL", color: .pink, device: .mac, size: .s36, dimmed: true)
            Work42Avatar(agentMark: nil, tint: .orange, size: .s36)
            Work42Avatar(agentMark: nil, tint: .orange, size: .s36, acting: true)
        }
    }
    .padding(24)
}
