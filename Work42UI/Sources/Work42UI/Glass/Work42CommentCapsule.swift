// Work42CommentCapsule.swift — the native comment bubble: the brand 42 mark in a
// Liquid Glass capsule. It replaces the accent-blue `plus.bubble.fill` circle that
// every highlight-to-comment surface (artifacts, browser, spec) used to draw.
//
// Behaviour: pops in from the selection with a spring, grows slightly on hover and
// slides its "Comment" label out, squishes on press, and bursts away when removed.
// The click action is the caller's (open the composer popover); this view owns only
// the look and the motion.

import SwiftUI
import AppKit

/// The 42 brand mark (tile removed), loaded once from the Work42UI bundle.
private let work42Mark42Image: NSImage? = {
    guard let url = Bundle.module.url(forResource: "work42-mark42", withExtension: "png") else { return nil }
    return NSImage(contentsOf: url)
}()

public struct Work42CommentCapsule: View {
    public enum Size {
        case regular
        case compact

        var height: CGFloat { self == .regular ? 30 : 18 }
        var markHeight: CGFloat { self == .regular ? 14 : 9 }
        var hPadding: CGFloat { self == .regular ? 11 : 5 }
        var fontSize: CGFloat { self == .regular ? DT.f11 : DT.f9 }
    }

    private let label: String?
    private let size: Size
    private let action: () -> Void

    /// Set by the first hover and never cleared: the label stays open once
    /// revealed. (Resizing on every hover in/out moved the edge under the
    /// pointer and made the capsule flicker.) The view is rebuilt when the
    /// selection clears, which resets it.
    @State private var revealed = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - label: text that slides out on hover; `nil` for the icon-only capsule.
    ///   - size: `.regular` for the floating bubble, `.compact` for gutters.
    ///   - action: runs on click.
    public init(label: String? = "Comment", size: Size = .regular, action: @escaping () -> Void) {
        self.label = label
        self.size = size
        self.action = action
    }

    private var spring: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.42, dampingFraction: 0.62)
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: revealed && label != nil ? 7 : 0) {
                if let image = work42Mark42Image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: size.markHeight)
                } else {
                    Text("42").font(.system(size: size.fontSize, weight: .bold, design: .rounded))
                }
                if revealed, let label {
                    Text(label)
                        .font(.system(size: size == .regular ? DT.f11 : DT.f9, weight: .medium))
                        .foregroundStyle(DT.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, size.hPadding)
            .frame(minWidth: size == .regular ? 44 : 28, minHeight: size.height, maxHeight: size.height)
            .glassCapsuleSurface()
            .contentShape(Capsule())
        }
        .buttonStyle(Work42CapsulePressStyle(reduceMotion: reduceMotion))
        .scaleEffect(appeared ? 1 : 0.2, anchor: .bottom)
        .opacity(appeared ? 1 : 0)
        .animation(spring, value: revealed)
        .onHover { if $0 { revealed = true } }
        .onAppear { withAnimation(spring) { appeared = true } }
        // Removal: swell, then fade (the caller wraps the `if` in an animation).
        .transition(.asymmetric(
            insertion: .identity,
            removal: .scale(scale: 1.5).combined(with: .opacity)
        ))
        .accessibilityLabel(label ?? "Comment")
    }
}

/// Squish on press, with a fast response so it feels attached to the pointer.
private struct Work42CapsulePressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

public extension View {
    /// Places a view centred on a text selection, just above it (or just below
    /// when the selection is too close to the top edge). Positions with layout
    /// alignment guides rather than `.offset`, so a popover attached to the view
    /// anchors to where it is drawn.
    ///
    /// - Parameter selectionRect: the selection's rect in the container's space.
    func work42CentredOnSelection(_ selectionRect: CGRect) -> some View {
        let above = selectionRect.minY > 48
        return self
            .alignmentGuide(.leading) { $0[HorizontalAlignment.center] }
            .alignmentGuide(.top) { above ? $0[.bottom] + 6 : -(selectionRect.height + 6) }
            .padding(.leading, max(selectionRect.midX, 0))
            .padding(.top, max(selectionRect.minY, 0))
    }
}
