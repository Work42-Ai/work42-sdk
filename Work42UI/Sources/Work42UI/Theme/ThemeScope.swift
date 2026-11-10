// ThemeScope.swift — which theme a view draws with, when one process shows several.
//
// The theme is a process-wide value (`ThemeRuntime`), which is right for the Mac app: one theme for one user. The iPad shows one
// window per account and each account has its own Mac with its own theme, so a window names its theme: the scope. A view carries it
// in `EnvironmentValues.themeScope` (SwiftUI) and, on iPadOS, in `ThemeScopeTrait` (UIKit); the two are bridged, so a color resolved
// by UIKit for a hosted SwiftUI view, and one UIKit resolves for itself, both see the window's scope. An empty scope is the global theme.

import SwiftUI

#if canImport(UIKit)
import UIKit

/// The trait that carries a window's theme scope down its view hierarchy. Empty: the global theme.
public nonisolated struct ThemeScopeTrait: UITraitDefinition {
    public static let defaultValue: String = ""
    /// A color follows the theme, so a view re-resolves its colors when the scope changes.
    public static let affectsColorAppearance = true
    public static let identifier = "com.work42.theme.scope"
}

extension UITraitCollection {
    /// The theme scope of this trait collection, nil for the global theme.
    public nonisolated var themeScope: String? {
        let scope = self[ThemeScopeTrait.self]
        return scope.isEmpty ? nil : scope
    }
}

/// `EnvironmentValues.themeScope`, bridged both ways with `ThemeScopeTrait`.
private struct ThemeScopeEnvironmentKey: UITraitBridgedEnvironmentKey {
    static let defaultValue: String = ""

    static func read(from traitCollection: UITraitCollection) -> String {
        traitCollection[ThemeScopeTrait.self]
    }

    static func write(to mutableTraits: inout any UIMutableTraits, value: String) {
        mutableTraits[ThemeScopeTrait.self] = value
    }
}
#else
private struct ThemeScopeEnvironmentKey: EnvironmentKey {
    static let defaultValue: String = ""
}
#endif

extension EnvironmentValues {
    /// The theme scope of the view: what `ThemeRuntime.update(_:scope:)` was given for it. Empty: the global theme.
    public var themeScope: String {
        get { self[ThemeScopeEnvironmentKey.self] }
        set { self[ThemeScopeEnvironmentKey.self] = newValue }
    }
}
