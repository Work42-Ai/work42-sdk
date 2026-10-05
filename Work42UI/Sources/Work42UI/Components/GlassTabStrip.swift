import SwiftUI

/// iOS/macOS-style segmented bar with a single Liquid Glass selection pill.
///
/// `GlassTabStrip` is shared by Work42's built-in surfaces and plugin widgets,
/// so both use the same system-accent-aware treatment and animation.
public struct GlassTabStrip<Item: Hashable & Identifiable>: View {

    private let items: [Item]
    @Binding private var selection: Item
    private let label: (Item) -> String
    /// Distinct namespace id per strip. Without this, two mounted strips with
    /// the same matched-geometry id can race their pill animations.
    private let namespaceId: String
    private let isEnabled: (Item) -> Bool
    private let badge: (Item) -> String?

    @Namespace private var pill

    /// Creates a segmented strip.
    ///
    /// - Parameters:
    ///   - items: Items displayed in order.
    ///   - selection: The currently selected item.
    ///   - label: Human-readable label for an item.
    ///   - namespaceId: Stable id used by the selection-pill animation.
    ///   - isEnabled: Optional item availability predicate.
    ///   - badge: Optional short badge displayed beside an item's label.
    public init(
        items: [Item],
        selection: Binding<Item>,
        label: @escaping (Item) -> String,
        namespaceId: String,
        isEnabled: @escaping (Item) -> Bool = { _ in true },
        badge: @escaping (Item) -> String? = { _ in nil }
    ) {
        self.items = items
        self._selection = selection
        self.label = label
        self.namespaceId = namespaceId
        self.isEnabled = isEnabled
        self.badge = badge
    }

    private var accent: Color { DT.systemAccent }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let active = selection == item
                let enabled = isEnabled(item)
                let badgeText = badge(item)
                Button {
                    guard enabled else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selection = item
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(label(item))
                            .font(.system(
                                size: DT.f13,
                                weight: active ? .semibold : .medium
                            ))
                        if let badgeText {
                            Text(badgeText)
                                .font(.system(size: DT.f9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.primary.opacity(0.08))
                                )
                        }
                    }
                    .foregroundStyle(
                        active && enabled ? accent :
                        enabled ? Color.secondary : Color.secondary.opacity(0.6)
                    )
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .frame(maxWidth: .infinity)
                    .contentShape(Capsule(style: .continuous))
                    .background(activeBackground(for: item))
                    .opacity(enabled ? 1 : 0.6)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.5)
        )
        .fixedSize()
    }

    @ViewBuilder
    private func activeBackground(for item: Item) -> some View {
        if selection == item && isEnabled(item) {
            Capsule(style: .continuous)
                .fill(accent.opacity(0.16))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(accent.opacity(0.32), lineWidth: 0.5)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .fill(.background.opacity(0.0))
                        .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
                )
                .matchedGeometryEffect(id: namespaceId, in: pill)
        }
    }
}
