// SectionHeader.swift - The header row primitive of the Work42 design
// system.
//
// One row: a sentence-case title on the left, an optional trailing
// actions slot on the right. No surface, no padding — the parent
// (`Card`, the chat column, a settings group) decides where to
// place it and how much air to give it. Keeping it stateless and
// chrome-free is what lets non-card surfaces (chat, modal sheets,
// inline groups) borrow the exact same header rhythm without
// inheriting a card's background.
//
// The actions slot is a `@ViewBuilder` so callers can drop in a
// single button, three icons, or a whole HStack without reaching
// for `AnyView`. Renders right-aligned with `Spacer` separation
// from the title.
//
// API shape:
//   SectionHeader("Plan")                                // bare label
//   SectionHeader("Plan", actions: { Button("Edit") })   // w/ trailing

import SwiftUI

public struct SectionHeader<Actions: View>: View {

    public let label: String
    private let actions: Actions

    public init(
        _ label: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.label = label
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: DT.s8) {
            Text(label)
                .font(.system(size: DT.f12, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            actions
        }
    }
}

// MARK: - No-actions convenience

extension SectionHeader where Actions == EmptyView {
    /// Convenience init for callers that don't need a trailing
    /// actions row — keeps `SectionHeader("Plan")` ergonomic.
    public init(_ label: String) {
        self.init(label, actions: { EmptyView() })
    }
}
