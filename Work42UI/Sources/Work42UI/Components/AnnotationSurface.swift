// AnnotationSurface.swift — the ONE seam that lets any comment surface also
// accept a DICTATED comment (highlight → push-to-talk → comment in the composer,
// no typing).
//
// Lives in Work42UI (the lowest shared layer) so BOTH the shared
// `CommentComposerPopover` here AND the app's `DictationController` can see it —
// Flow42Core depends on Work42UI, not the other way around.
//
// A single shared registry holds the CURRENT live "commentable selection". A
// surface publishes its selection (excerpt + a `makeComment` closure that is the
// EXACT append it already performs on commit) and clears it when the selection /
// dialog goes away. `DictationController` consults the registry on a trigger: if
// work42 is frontmost and a selection is live, the transcript is routed to
// `makeComment(...)` instead of pasted into the focused field.
//
// The surface knows nothing about dictation; dictation knows nothing about the
// surface. The closure carries both the payload and the destination store, so
// multi-window "which composer?" needs no routing — the closure captured it.

import AppKit
import Foundation

/// A live, commentable selection published by a surface.
public struct CommentableSelection {
    /// e.g. "PR #42 · Widget.swift:88" — shown on the pending-comment card.
    public let sourceLabel: String
    /// The highlighted text (the comment's excerpt/anchor).
    public let excerpt: String
    /// The selection's rect in Cocoa screen coords, so the dictation glow can
    /// hug it. Optional — nil falls back to the normal target resolution.
    public let screenRect: CGRect?
    /// Turns a comment BODY into an appended comment. This is the exact closure
    /// the surface's comment dialog runs on commit — reused verbatim.
    public let makeComment: (String) -> Void

    public init(
        sourceLabel: String,
        excerpt: String,
        screenRect: CGRect?,
        makeComment: @escaping (String) -> Void
    ) {
        self.sourceLabel = sourceLabel
        self.excerpt = excerpt
        self.screenRect = screenRect
        self.makeComment = makeComment
    }
}

/// A whole-widget comment target (comments-on-widgets.3): when dictation
/// starts while a widget is FOCUSED but there is NO text selection, this lets
/// the dictation controller create a comment on the entire widget instead of
/// falling through to the clipboard. The app layer builds it for the currently
/// focused widget (resolving its id/type/title/context) and registers a
/// provider closure with `AnnotationRegistry`; the dictation controller
/// consults the provider after `active`.
public struct WholeWidgetCommentTarget {
    /// The focused widget's human title — shown as the pending-comment card's
    /// label (the card's identity, since there's no selection excerpt).
    public let title: String
    /// The widget's whole-card rect in Cocoa screen coords, so the dictation
    /// glow hugs it. Nil falls back to normal target resolution.
    public let screenRect: CGRect?
    /// Appends the (text-only) whole-widget comment for the dictated `body`.
    /// Built by the app layer, which owns the store and knows how to construct
    /// the comment (its id/type/context were resolved when the target was
    /// built). The screenshot is NOT part of the comment — it ships separately
    /// as a `ChatAttachment` (comments-on-widgets.6).
    public let append: (_ body: String) -> Void
    /// Captures a PNG of the widget's content region and returns its path (nil
    /// on failure / no rect). App-layer-owned (ScreenCaptureKit + the session's
    /// attachments dir). The caller sends the result as a separate attachment;
    /// a nil result just means no screenshot is attached (never blocks the
    /// comment).
    public let captureScreenshot: () async -> String?
    /// Stages the screenshot at `path` into the session's MAIN composer as a
    /// removable `ChatAttachment` (comments-on-widgets.8). Used on the
    /// composer-visible path, where the comment is queued for the user to send
    /// from the main composer rather than the floating accessory — so the image
    /// must ride along there too, like a manual attach.
    public let stageScreenshotAttachment: (_ path: String) -> Void

    public init(
        title: String,
        screenRect: CGRect?,
        append: @escaping (_ body: String) -> Void,
        captureScreenshot: @escaping () async -> String?,
        stageScreenshotAttachment: @escaping (_ path: String) -> Void
    ) {
        self.title = title
        self.screenRect = screenRect
        self.append = append
        self.captureScreenshot = captureScreenshot
        self.stageScreenshotAttachment = stageScreenshotAttachment
    }
}

/// Holds the CURRENT live commentable selection (one at a time — you can only
/// highlight in one surface at a time). Surfaces publish/clear; dictation reads.
@MainActor
public final class AnnotationRegistry {
    public static let shared = AnnotationRegistry()

    public private(set) var active: CommentableSelection?

    /// A surface's selection became live (or a comment dialog opened).
    public func present(_ selection: CommentableSelection) { active = selection }
    /// A surface's selection cleared (deselect / Esc / dialog dismissed).
    public func clear() { active = nil }

    /// Provider for a WHOLE-WIDGET comment target (comments-on-widgets.3),
    /// registered by the session panel. Returns a target for the currently
    /// focused widget, or nil when no widget is focused. The dictation
    /// controller calls this only when there is no `active` selection, so a
    /// focused widget + dictation becomes a whole-widget comment instead of a
    /// clipboard copy.
    public var wholeWidgetProvider: (() -> WholeWidgetCommentTarget?)?
}
