// GlassAvatar.swift — the one avatar look for chat and meeting surfaces (WOR-235).
//
// A circle of liquid glass tinted with a single plain colour, the initials drawn in that same
// colour. No gradient, no white ring, no drop shadow. `ChatBubble`, `ConversationView` and
// meet42's `MeetAvatarView` all draw through this, so a person looks the same everywhere.

import SwiftUI

/// A liquid-glass circle in one plain colour with the initials in that colour.
///
/// On macOS 26 the circle is real Liquid Glass (`.glassEffect`) tinted with `color`. Earlier
/// systems get a thin material, a `color` wash and a hairline inner stroke, which reads the same
/// way without the lensing.
public struct GlassAvatar: View {
    let initials: String
    let color: Color
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(initials: String, color: Color, size: CGFloat = 32) {
        self.initials = initials
        self.color = color
        self.size = size
    }

    /// Initials colour: the plain colour in dark mode, deepened a little in light mode so it
    /// stays legible against the pale glass.
    private var initialsColor: Color {
        colorScheme == .dark ? color : color.mix(with: .black, by: 0.18)
    }

    public var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(initialsColor)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .modifier(GlassAvatarBackground(color: color))
            .accessibilityLabel(initials)
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
