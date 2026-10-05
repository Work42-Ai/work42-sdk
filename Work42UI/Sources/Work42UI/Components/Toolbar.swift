// Toolbar.swift - Grouped Liquid-Glass control row.
//
// Wraps any horizontal stack of controls in a Liquid Glass capsule,
// matching the macOS 26 Tahoe floating-toolbar pattern: a single
// continuous glass surface that groups related icon buttons / menus
// / pills together. Multiple Toolbars on the same row read as
// DISTINCT groups separated by negative space — same shape as the
// editor toolbars in stock Apple apps (text format / list / table
// / attach … share / more / search).
//
// On macOS 26+ the capsule uses the real `.glassEffect` material so
// it picks up the live blur behind it; older OSes fall back to a
// `.thinMaterial` capsule with a hairline stroke. The call site is
// identical across versions — no `#available` gating leaks into the
// view layer.
//
// Usage:
//
//     Toolbar {
//         Button { … } label: { Image(systemName: "plus") }
//         Button { … } label: { Image(systemName: "list.bullet") }
//         Button { … } label: { Image(systemName: "tablecells") }
//     }
//
// Children can be any view (Button, Menu, plain Image, Text). The
// Toolbar provides the capsule chrome; individual children stay
// transparent unless the caller adds their own treatment.

import SwiftUI

public struct Toolbar<Content: View>: View {

    private let content: Content
    private let spacing: CGFloat
    private let tint: Color?

    /// - Parameter tint: when non-nil, the WHOLE capsule takes on this color
    ///   (e.g. red while a Record toolbar is active) instead of the neutral
    ///   glass — the capsule's own chrome adapts, rather than a child adding
    ///   its own separate colored surface on top.
    public init(
        spacing: CGFloat = DT.s4,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.tint = tint
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: spacing) { content }
            .padding(.horizontal, DT.s8)
            .padding(.vertical, DT.s4)
            .modifier(ToolbarCapsule(tint: tint))
            .animation(.easeInOut(duration: 0.2), value: tint)
    }
}

/// Inner ViewModifier that holds the `#available` gate so the
/// `Toolbar.body` stays a single straight-line expression.
private struct ToolbarCapsule: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: Capsule())
        } else {
            content
                .background(
                    Capsule().fill(tint.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(.thinMaterial))
                )
                .overlay(
                    Capsule()
                        .strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.10 : 0.35), lineWidth: 0.5)
                )
        }
    }
}
