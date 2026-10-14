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
    @Environment(\.colorScheme) private var colorScheme

    /// The brand tile's pale blue (#C3EEFF, sampled from the 42 mark's tile),
    /// laid over Liquid Glass so the capsule reads as tinted glass, not a flat
    /// fill. Strong in light mode; lower in dark so the glass still shows.
    private var glassTint: Color {
        Color(red: 195 / 255, green: 238 / 255, blue: 255 / 255)
            .opacity(colorScheme == .dark ? 0.42 : 0.68)
    }

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
            .glassShowcasePillSurface(tint: glassTint)
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
    /// Places a view centred horizontally on a text selection and a few points
    /// above its top edge (below it when there isn't room above). Meant to be
    /// applied inside a `.topLeading` overlay that shares the selection's
    /// coordinate space.
    ///
    /// The view hangs off a zero-size anchor point: it is laid out (not offset),
    /// so a popover attached to the view anchors to where it is drawn, and the
    /// view can change width (the label opening) while staying centred.
    ///
    /// - Parameters:
    ///   - selectionRect: the selection's rect in the container's space.
    ///   - gap: points between the selection and the view.
    func work42CentredOnSelection(_ selectionRect: CGRect, gap: CGFloat = 8) -> some View {
        let above = selectionRect.minY >= 40
        let anchorY = above ? selectionRect.minY - gap : selectionRect.maxY + gap
        return Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: above ? .bottom : .top) {
                self.fixedSize()
            }
            .padding(.leading, max(selectionRect.midX, 0))
            .padding(.top, max(anchorY, 0))
    }
}
