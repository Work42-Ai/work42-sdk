// PlatformAppearance.swift — "resolve this color as if the UI were light/dark", on macOS and iPadOS.
//
// The web-token generators resolve every dynamic color twice, once per scheme, so the CSS they emit
// carries both values. macOS does that with NSAppearance; iPadOS with a trait collection.

import SwiftUI

#if canImport(AppKit)
import AppKit

public typealias PlatformAppearance = NSAppearance

extension NSAppearance {
    public static var light: NSAppearance { NSAppearance(named: .aqua) ?? .currentDrawing() }
    public static var dark: NSAppearance { NSAppearance(named: .darkAqua) ?? light }

    /// The appearance the app is drawing with right now.
    @MainActor public static var current: NSAppearance { NSApplication.shared.effectiveAppearance }

    public var isDarkAppearance: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// Runs `body` with this appearance as the current drawing appearance.
    public func perform(_ body: () -> Void) { performAsCurrentDrawingAppearance(body) }
}
#else
import UIKit

public struct PlatformAppearance: Sendable {
    public let style: UIUserInterfaceStyle

    public static let light = PlatformAppearance(style: .light)
    public static let dark = PlatformAppearance(style: .dark)

    @MainActor public static var current: PlatformAppearance {
        let style = UITraitCollection.current.userInterfaceStyle
        return style == .dark ? .dark : .light
    }

    public var isDarkAppearance: Bool { style == .dark }

    public func perform(_ body: () -> Void) {
        UITraitCollection(userInterfaceStyle: style).performAsCurrent(body)
    }
}
#endif
