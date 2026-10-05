// Card.swift - The labeled-card primitive of the Work42 design system.
//
// One pattern, two callsites: a card with an OPTIONAL header strip
// (sentence-case title on the left, action controls on the right)
// living INSIDE the rounded surface, followed by content. A single
// `padding` value wraps EVERYTHING inside the surface — title row,
// actions row, and content share the same inset from the rounded
// edge — so every card in the app looks like the same surface
// family, no per-callsite overrides.
//
// API shape:
//   Card("Plan") { … }                          // bare card
//   Card("Plan", actions: { Button("Edit") }){} // header w/ actions
//   Card { … }                                  // no header at all
//
// The `actions` slot is a `@ViewBuilder` so callers can pass one or
// many controls (a close X, a copy button, an inline link, an HStack
// of three icons) without having to reach for `AnyView`. Actions
// render right-aligned in the header row.
//
// Padding layout:
//   ┌─ surface ────────────────────────────────┐
//   │                                          │
//   │    Title              Actions            │   ← shared `padding`
//   │                                          │      inset
//   │    Content                               │
//   │                                          │
//   └──────────────────────────────────────────┘
//
// Surface treatment matches macOS's native feel — a faint primary
// fill, a hairline stroke, and the standard card corner radius. No
// `.glassEffect()` here because the design system has to compile on
// macOS 14; the apps wrap `Card` with their own glass modifier when
// they want the Tahoe Liquid Glass material. The token surface read
// is already very close to native chrome over `DT.backdrop`.

import SwiftUI

public struct Card<Actions: View, Content: View>: View {

    /// Card title rendered inside the surface, sentence case. Nil
    /// hides the header row entirely (and the actions slot with it
    /// — actions without a title would float in an unanchored
    /// strip).
    public let label: String?
    /// Padding applied around the title + actions row (top and
    /// horizontal edges). Defaults to `padding` (see below) so every
    /// existing callsite that doesn't pass this explicitly renders
    /// byte-for-byte as before. Pass a smaller value to give a card's
    /// header its own denser rhythm without touching the content inset.
    public let headerPadding: CGFloat
    /// Padding applied around the content (horizontal edges, bottom,
    /// and — when there's no header — top too). Defaults to `DT.s16`
    /// so every card breathes the same amount of air regardless of
    /// callsite. Pass a custom value only when a card genuinely needs
    /// a different rhythm from the rest of the app.
    public let padding: CGFloat
    /// Corner radius of the surface. Defaults to `DT.rCard`; raise
    /// to `DT.rPanel` when the card is the dominant surface of a
    /// pane.
    public let cornerRadius: CGFloat

    private let actions: Actions
    private let content: Content

    public init(
        _ label: String? = nil,
        padding: CGFloat = DT.s16,
        headerPadding: CGFloat? = nil,
        cornerRadius: CGFloat = DT.rCard,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.padding = padding
        self.headerPadding = headerPadding ?? padding
        self.cornerRadius = cornerRadius
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DT.s16) {
            if let label {
                SectionHeader(label) { actions }
                    .padding(.top, headerPadding)
                    .padding(.horizontal, headerPadding)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, padding)
                .padding(.top, label == nil ? padding : 0)
                .padding(.bottom, padding)
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

// MARK: - No-actions convenience

extension Card where Actions == EmptyView {
    /// Convenience init for callers that don't need a trailing
    /// actions row — keeps `Card("Plan") { … }` ergonomic without
    /// forcing every site to spell out `actions: { EmptyView() }`.
    public init(
        _ label: String? = nil,
        padding: CGFloat = DT.s16,
        headerPadding: CGFloat? = nil,
        cornerRadius: CGFloat = DT.rCard,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            label,
            padding: padding,
            headerPadding: headerPadding,
            cornerRadius: cornerRadius,
            actions: { EmptyView() },
            content: content
        )
    }
}
