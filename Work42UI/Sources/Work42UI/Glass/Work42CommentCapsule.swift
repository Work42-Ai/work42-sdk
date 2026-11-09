// Work42CommentCapsule.swift — the native comment bubble: the brand 42 mark in a
// Liquid Glass capsule. It replaces the accent-blue `plus.bubble.fill` circle that
// every highlight-to-comment surface (artifacts, browser, spec) used to draw.
//
// Behaviour: pops in from the selection with a spring, grows slightly on hover and
// slides its "Comment" label out, squishes on press, and bursts away when removed.
// The click action is the caller's (open the composer popover); this view owns only
// the look and the motion.

import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The 42 brand mark (tile removed), loaded once from the Work42UI bundle.
private let work42Mark42Image: PlatformImage? = {
    guard let url = Bundle.module.url(forResource: "work42-mark42", withExtension: "png") else { return nil }
    return PlatformImage.loadFile(at: url)
}()

public extension Notification.Name {
    /// Posted by whatever finished with a highlight (a dictated comment was delivered): every selectable text view and web view drops
    /// its text selection, since the highlight has done its job.
    static let work42ClearTextSelection = Notification.Name("work42.clearTextSelection")
}

#if !canImport(AppKit)
/// The comment item of iPadOS's edit menu: the brand 42 mark alone, no word, the way the system's Writing Tools shows an icon
/// alone. It is how to comment on selected text on an iPad, in place of the floating pill the Mac draws. The caller says what
/// choosing it does (open the note box).
public enum Work42CommentMenu {
    /// The menu action: the 42 mark with a speech bubble at its corner and an empty title, so the menu bar draws the icon. One
    /// plain colour that follows the menu's tint. "Comment" is its discoverability title, which VoiceOver and a long press read
    /// out. Without the mark it falls back to the word "Comment".
    @MainActor
    public static func action(_ handler: @escaping () -> Void) -> UIAction {
        guard let image = badgedMark(subSymbol: "bubble.left.fill") else { return UIAction(title: "Comment") { _ in handler() } }
        return UIAction(title: "", image: image, discoverabilityTitle: "Comment") { _ in handler() }
    }

    /// The menu action that dictates the comment: the 42 mark with a microphone at its corner, no word. It is first on the menu,
    /// ahead of "Comment". The caller says what choosing it does (start dictation aimed at the highlighted text).
    @MainActor
    public static func dictateAction(_ handler: @escaping () -> Void) -> UIAction {
        guard let image = badgedMark(subSymbol: "mic.fill") else { return UIAction(title: "Dictate") { _ in handler() } }
        return UIAction(title: "", image: image, discoverabilityTitle: "Dictate a comment") { _ in handler() }
    }

    /// The 42 mark (22 pt wide, its aspect ratio kept) with `subSymbol` (about 12 pt) at the bottom right, a transparent ring
    /// (1.5 pt) cut around it. Built as an alpha mask in black and returned as a template, so the edit menu tints it with the
    /// label colour: white in dark mode, black in light. `nil` when the mark or the symbol can't load.
    @MainActor
    private static func badgedMark(subSymbol: String) -> UIImage? {
        guard let mark = work42Mark42Image else { return nil }
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        guard let symbol = UIImage(systemName: subSymbol, withConfiguration: config)?
            .withTintColor(.black, renderingMode: .alwaysOriginal) else { return nil }

        let markWidth: CGFloat = 22
        let markSize = CGSize(width: markWidth, height: markWidth * mark.size.height / max(mark.size.width, 1))
        let badge: CGFloat = 12
        let ring: CGFloat = 1.5
        let canvas = CGSize(width: markSize.width + 2, height: markSize.height + 2)
        // The sub-icon's box sits in the bottom right corner, inset by the ring so the cut-out is not clipped.
        let badgeCenter = CGPoint(x: canvas.width - ring - badge / 2, y: canvas.height - ring - badge / 2)
        let fit = min(badge / max(symbol.size.width, 1), badge / max(symbol.size.height, 1), 1)
        let symbolSize = CGSize(width: symbol.size.width * fit, height: symbol.size.height * fit)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            mark.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: .zero, size: markSize))
            let cg = context.cgContext
            cg.saveGState()
            cg.setBlendMode(.clear)
            let cutout = badge + 2 * ring
            cg.fillEllipse(in: CGRect(x: badgeCenter.x - cutout / 2, y: badgeCenter.y - cutout / 2, width: cutout, height: cutout))
            cg.restoreGState()
            symbol.draw(in: CGRect(x: badgeCenter.x - symbolSize.width / 2, y: badgeCenter.y - symbolSize.height / 2,
                                   width: symbolSize.width, height: symbolSize.height))
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}
#endif

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

    /// Tint laid over Liquid Glass so the capsule reads as tinted glass, not a
    /// flat fill. Light: the brand tile's pale blue (#C3EEFF) at 33%. Dark: the
    /// palest blue (#F0FBFF) at 75%, so black text keeps strong contrast.
    private var glassTint: Color {
        if colorScheme == .dark {
            return Color(red: 240 / 255, green: 251 / 255, blue: 255 / 255).opacity(0.75)
        }
        return Color(red: 195 / 255, green: 238 / 255, blue: 255 / 255).opacity(0.33)
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
                    Image(platformImage: image)
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
                        .foregroundStyle(Color.black)
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
