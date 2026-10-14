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
        var fontSize: CGFloat { self == .regular ? 12 : 10 }
    }

    private let label: String?
    private let size: Size
    private let action: () -> Void

    @State private var hovering = false
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
            HStack(spacing: hovering && label != nil ? 7 : 0) {
                if let image = work42Mark42Image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: size.markHeight)
                } else {
                    Text("42").font(.system(size: size.fontSize, weight: .bold, design: .rounded))
                }
                if hovering, let label {
                    Text(label)
                        .font(.system(size: size.fontSize, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .padding(.horizontal, size.hPadding)
            .frame(minWidth: size == .regular ? 44 : 28, minHeight: size.height, maxHeight: size.height)
            .glassCapsuleSurface()
            .contentShape(Capsule())
        }
        .buttonStyle(Work42CapsulePressStyle(reduceMotion: reduceMotion))
        .scaleEffect(appeared ? (hovering ? 1.06 : 1) : 0.2, anchor: .bottomLeading)
        .opacity(appeared ? 1 : 0)
        .animation(spring, value: hovering)
        .onHover { hovering = $0 }
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
