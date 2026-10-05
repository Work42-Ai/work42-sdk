// Work42WidgetPill.swift — opt-in pill-presentation SDK surface
// (meet42-plugin-conversion, s1)
//
// Work42WidgetPill   — opt-in protocol; a widget conforms to declare it has a
//                       compact "pill" presentation that can be floated above
//                       the app, reachable from the pill's Session/Home lists.
// WidgetPillMetadata — display metadata for the pill's list row (title, icon)
//                       plus a preferred initial size hint for the floated
//                       window.
//
// ABI safety: a SEPARATE protocol, following the `Work42BrowserWidgetOptions`
// shape (also `: Work42Widget`) and `Work42WidgetBackground`'s cast-based
// discovery. The host discovers pill capability via
// `as? any Work42WidgetPill`. Old dylibs without the conformance return nil
// from the cast, load and behave exactly as before. `WidgetSDK.abiVersion` IS
// bumped this release — not because this protocol is unsafe, but because
// `SessionServices`/`WidgetBackgroundServices` gain a new required `pill`
// field (see `Work42PluginKit.swift`'s v10 note).

import SwiftUI

// MARK: - Work42WidgetPill

/// Opt-in: the widget has a compact "pill" presentation that can be floated
/// above the app, independent of whether it is open in a session tab.
///
/// Conform with a class that also conforms to `Work42Widget`. The host
/// discovers the conformance via `as? any Work42WidgetPill` — a widget that
/// does not override either requirement (the default, via the extension
/// below) is never listed on the pill's Session/Home buttons.
///
/// ## ABI safety
///
/// Mirrors `Work42WidgetBackground`'s opt-in cast-based discovery and the
/// `Work42BrowserWidgetOptions` `: Work42Widget` shape. Old dylibs without the
/// conformance return nil from the cast and behave exactly as today.
///
/// ## Example
///
/// ```swift
/// final class MyWidget: Work42Widget, Work42WidgetPill {
///     // ... Work42Widget requirements ...
///
///     func makePillView(services: SessionServices) -> AnyView? {
///         AnyView(MyCompactPillView())
///     }
///
///     var pillMetadata: WidgetPillMetadata {
///         WidgetPillMetadata(title: "My Widget", icon: "bolt.fill")
///     }
/// }
/// ```
@MainActor
public protocol Work42WidgetPill: Work42Widget {

    /// Build the widget's compact pill view for `services`' session, or
    /// `nil` if this widget has no pill presentation for that call (the
    /// default, via the extension below). The host's "has a pill version"
    /// check is `(widget as? any Work42WidgetPill)?.makePillView(services:) != nil`.
    ///
    /// ## Content-only canvas contract
    ///
    /// The returned view **must be content only** — it must not draw its own
    /// background, card, or filled shape behind the content. The host
    /// (`PillAccessoryPanel` → `PillBirthView`) owns the card surface: it
    /// draws the single liquid-glass card sized to `pillMetadata.preferredSize`
    /// and composites the widget's content on top. A widget that renders its
    /// own opaque background produces a double-card: the host's glass layer
    /// plus the widget's own fill, which defeats the liquid-glass effect and
    /// produces an incorrect visual.
    ///
    /// Correct: return `AnyView(MyContent())` — just the inner content tree.
    /// Incorrect: wrapping the content in a `RoundedRectangle.fill(…)` or any
    /// other filled background modifier.
    ///
    /// `.clipShape`, `.frame`, and `.padding` modifiers are fine; only avoid
    /// any modifier that paints an opaque or semi-opaque fill behind the content.
    func makePillView(services: SessionServices) -> AnyView?

    /// Display metadata for the pill's Session/Home list row and the
    /// floated window's initial size.
    var pillMetadata: WidgetPillMetadata { get }
}

public extension Work42WidgetPill {
    // Default: no pill. A widget that conforms but doesn't override either
    // requirement behaves exactly like a non-conforming widget.
    func makePillView(services: SessionServices) -> AnyView? { nil }
    var pillMetadata: WidgetPillMetadata { WidgetPillMetadata() }
}

// MARK: - WidgetPillMetadata

/// Display metadata for a pill-capable widget's list row (the pill's Session
/// and Home buttons) and the floated pill window.
nonisolated public struct WidgetPillMetadata: Codable, Sendable, Equatable {

    /// Initial size hint for the floated pill window, before
    /// `.reportsPillAccessorySize()` measures real content and grows the
    /// window to fit. Reuses `WidgetMinSize`'s width/height shape. `.zero`
    /// lets the host choose a default initial size.
    public var preferredSize: WidgetMinSize

    /// Row title shown in the pill's Session/Home lists.
    public var title: String

    /// SF Symbol name shown beside `title` in the pill's Session/Home lists.
    public var icon: String

    public init(preferredSize: WidgetMinSize = .zero, title: String = "", icon: String = "circle") {
        self.preferredSize = preferredSize
        self.title = title
        self.icon = icon
    }
}
