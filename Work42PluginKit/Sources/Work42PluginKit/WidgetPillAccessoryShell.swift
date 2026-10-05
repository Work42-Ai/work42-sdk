import AppKit
import SwiftUI

/// Stable geometry shared by stateful two-row pill accessories.
nonisolated public enum WidgetPillAccessoryMetrics {
    public static let width: CGFloat = 412
    public static let height: CGFloat = 108
    public static let iconSize: CGFloat = 36
    public static let actionHeight: CGFloat = 32
    public static let progressHeight: CGFloat = 3
}

/// A native application icon with a consistent fallback and footprint.
public struct WidgetPillAppIcon: View {
    private let image: NSImage?
    private let fallbackSymbol: String
    private let tint: Color

    public init(image: NSImage?, fallbackSymbol: String = "video.fill", tint: Color) {
        self.image = image
        self.fallbackSymbol = fallbackSymbol
        self.tint = tint
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tint.opacity(0.9))
            }
        }
        .frame(
            width: WidgetPillAccessoryMetrics.iconSize,
            height: WidgetPillAccessoryMetrics.iconSize
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }
}

/// The common meeting-pill canvas. Identity never moves; callers replace only
/// the state row and optional bottom rail.
public struct WidgetPillAccessoryShell<ActionRow: View, ProgressRail: View>: View {
    private let title: String
    private let subtitle: String
    private let icon: WidgetPillAppIcon
    private let actionRow: ActionRow
    private let progressRail: ProgressRail

    public init(
        title: String,
        subtitle: String,
        icon: WidgetPillAppIcon,
        @ViewBuilder actionRow: () -> ActionRow,
        @ViewBuilder progressRail: () -> ProgressRail
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.actionRow = actionRow()
        self.progressRail = progressRail()
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    icon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                }
                .frame(height: WidgetPillAccessoryMetrics.iconSize)

                actionRow
                    .frame(height: WidgetPillAccessoryMetrics.actionHeight)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            progressRail
                .frame(
                    width: WidgetPillAccessoryMetrics.width,
                    height: WidgetPillAccessoryMetrics.progressHeight
                )
        }
        .frame(
            width: WidgetPillAccessoryMetrics.width,
            height: WidgetPillAccessoryMetrics.height,
            alignment: .leading
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.controlActiveState, .active)
    }
}

public enum WidgetPillActionEmphasis: Sendable {
    case secondary
    case primary
}

public struct WidgetPillActionButtonStyle: ButtonStyle {
    private let emphasis: WidgetPillActionEmphasis
    private let tint: Color

    public init(
        emphasis: WidgetPillActionEmphasis = .secondary,
        tint: Color = .accentColor
    ) {
        self.emphasis = emphasis
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .frame(height: WidgetPillAccessoryMetrics.actionHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(emphasis == .primary ? tint : .white.opacity(0.10))
                    .overlay {
                        if emphasis == .secondary {
                            Capsule(style: .continuous)
                                .strokeBorder(.white.opacity(0.20), lineWidth: 0.5)
                        }
                    }
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
