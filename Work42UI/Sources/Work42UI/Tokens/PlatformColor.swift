// PlatformColor.swift — one color type for macOS (NSColor) and iPadOS (UIColor).
//
// The design tokens resolve colors per appearance and do luminance math on concrete sRGB values.
// This file is the only place that knows which platform class does the work, so `DesignTokens`
// and the theme code read the same on both.

import SwiftUI

#if canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformColor = UIColor
#endif

extension PlatformColor {

    /// A color that picks its value at draw time from the current light/dark appearance.
    ///
    /// The provider runs on the drawing thread, not the main actor, so it may only touch
    /// nonisolated state.
    public nonisolated static func dynamicColor(
        _ provider: @escaping (_ isDark: Bool) -> PlatformColor
    ) -> PlatformColor {
        #if canImport(AppKit)
        NSColor(name: nil) { appearance in
            provider(appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil)
        }
        #else
        let box = UncheckedProvider(provider)
        return UIColor { traits in box.provider(traits.userInterfaceStyle == .dark) }
        #endif
    }

    /// The system accent: the user's chosen accent on macOS, the app tint on iPadOS.
    public nonisolated static var platformAccent: PlatformColor {
        #if canImport(AppKit)
        NSColor.controlAccentColor
        #else
        UIColor.tintColor
        #endif
    }

    /// This color as concrete sRGB (a no-op where the color is already RGB).
    public nonisolated var srgb: PlatformColor {
        #if canImport(AppKit)
        usingColorSpace(.sRGB) ?? self
        #else
        self
        #endif
    }

    /// Red, green, blue, alpha of the sRGB value.
    public nonisolated var rgbaComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    /// Hue, saturation, brightness, alpha of the sRGB value.
    public nonisolated var hsbaComponents: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b, a)
    }

    /// `0xRRGGBB` as an sRGB color, alpha 1.
    public nonisolated static func srgb(_ hex: UInt32) -> PlatformColor {
        PlatformColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1)
    }
}

#if !canImport(AppKit)
/// UIKit's dynamic-color closure is `@Sendable`; the provider reads only nonisolated state, so the
/// non-Sendable closure is carried across unchecked.
private nonisolated struct UncheckedProvider: @unchecked Sendable {
    let provider: (Bool) -> PlatformColor
    init(_ provider: @escaping (Bool) -> PlatformColor) { self.provider = provider }
}

extension UIColor {
    /// NSColor's sRGB initializer, so shared code can use one spelling.
    public nonisolated convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif

extension Color {
    /// A SwiftUI color from the platform color class.
    public init(platform color: PlatformColor) {
        #if canImport(AppKit)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}
