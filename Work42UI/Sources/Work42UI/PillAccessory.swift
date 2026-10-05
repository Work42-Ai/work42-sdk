// PillAccessory.swift — the design-system primitive for components that are
// BORN from the dictation pill (Dynamic-Island-style). An accessory declares
// only WHAT it is (an initial size + its content); the system owns the MOTION
// (the locked pinch-off birth in `PillBirthView`).
//
// Two layers make up the pill's surface language:
//   • Capabilities — in-pill controls discovered on hover (the pill's own
//     MitosisSplit; lives in Work42Menu).
//   • Accessories  — components that emerge above the pill with the locked
//     gooey pinch-off. The composer is the first (`ComposerAccessory`).
//
// SELF-SIZING (bug/pill-push-to-talk.4): the birth still animates to a KNOWN
// size up front (`initialSize`) — that is what lets the pinch-off play before
// the content has necessarily been measured. But an accessory's content is no
// longer forced to fit (scrolling) inside a permanently fixed frame: it can
// report its OWN live, measured size as its content changes (e.g. a growing
// list of pending comments) via `.reportsPillAccessorySize()` below, and the
// hosting panel (`PillAccessoryPanelController`, Work42App) grows the window
// to match, capped to a maximum bound. The birth itself plays exactly once;
// a size change afterward is a live resize, not a re-birth.

import SwiftUI

@MainActor
public protocol PillAccessory {
    /// The footprint the birth animates to before any live size report
    /// arrives. Accessories whose content doesn't change size can treat this
    /// as their permanent size (never opt into `.reportsPillAccessorySize()`);
    /// accessories that grow with content should still return a sane initial
    /// value here — the first live report supersedes it immediately.
    static var initialSize: CGSize { get }
    /// Instance-level birth footprint. Defaults to the type's `initialSize`,
    /// but an accessory whose size depends on INSTANCE data (e.g. a comment
    /// carrying a screenshot thumbnail) overrides this so the pinch-off opens
    /// at the right footprint from frame one instead of visibly growing once
    /// the image lays out (comments-on-widgets: "the initial size needs to be
    /// registered with the image in mind if it carries an image").
    var birthSize: CGSize { get }
    /// Whether the hosting panel should take keyboard focus (composer: true).
    var acceptsKeyboard: Bool { get }
    /// Auto-dismiss after this interval once shown (composer: nil = manual).
    var autoDismiss: TimeInterval? { get }
    /// The content to reveal — no motion, no positioning; the system owns those.
    associatedtype Body: View
    @ViewBuilder func makeBody() -> Body
}

extension PillAccessory {
    /// Default: the type-level `initialSize`. Accessories with instance-
    /// dependent birth sizing override this.
    public var birthSize: CGSize { Self.initialSize }
}

/// Preference key a `PillAccessory`'s `makeBody()` content reports its own
/// live, measured size through — read by the hosting panel to grow/shrink the
/// window to fit (bug/pill-push-to-talk.4, AC13/AC14). A single accessory has
/// a single content tree, so the last reported value simply wins.
public struct PillAccessoryContentSizeKey: PreferenceKey {
    public static let defaultValue: CGSize? = nil
    public static func reduce(value: inout CGSize?, nextValue: () -> CGSize?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Opts this view into live pill-accessory sizing: its measured size is
    /// reported up via `PillAccessoryContentSizeKey` whenever it changes, so
    /// a growing/shrinking accessory (e.g. a list of pending comments) drives
    /// its hosting panel's live resize. Apply to the ROOT of a `PillAccessory`
    /// conformer's `makeBody()` content when its size should track content;
    /// an accessory with a genuinely fixed size can skip this entirely.
    public func reportsPillAccessorySize() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: PillAccessoryContentSizeKey.self, value: proxy.size)
            }
        )
    }
}

/// The max height (points) any `PillAccessory`'s content should ever grow
/// to before switching to internal scrolling — a system-level rule, defined
/// ONCE here, that both the hosting panel (`PillAccessoryPanelController.
/// cappedContentSize`, Work42App) and an accessory's own content (e.g.
/// `PendingCommentsAccessoryList`) read, instead of each independently
/// guessing a number (bug/pill-push-to-talk dogfooding: "our system should
/// tell the accessories what's the area that they can occupy... they can't
/// go lower or higher than certain thresholds" — a prior mismatch between a
/// window-computed cap and the content's own uncapped rendered height was
/// the root cause of the pill "drift" bug this task started from). An
/// accessory whose content might exceed this MUST supply its own internal
/// `ScrollView` — the ceiling is enforced, but the rest of the content must
/// always stay reachable ("we should never prevent the accessory from
/// scrolling or functioning").
public let pillAccessoryMaxContentHeight: CGFloat = 460
