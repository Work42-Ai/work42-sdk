// MarkdownPreviewCommentPresenter.swift - Presents the comment composer/viewer
// for the Markdown *Preview* comment layer.
//
// Promoted into the SDK (task42-plugin-conversion, s5) so a hot-loaded
// plugin markdown widget joins the SAME shared pending-comment store +
// composer strip + dictation as the built-in spec/file widgets, via public
// SDK API — instead of maintaining its own disconnected comment UI.
//
// The WebView-based preview (`MarkdownWebView`) can't reach a HOST app's
// comment popovers across a module boundary, so it fires callbacks with the
// anchor view + rect. This presenter receives those callbacks and opens the
// SAME `CommentComposerPopover` / `CommentViewerPopover`, anchored via an
// NSPopover, then appends / removes a `PendingComment` against the shared
// `PendingCommentsStore`. Because it commits against the same source-line
// span (mapped from the block's `data-sourcepos`), a comment left in Preview
// is identical to one left in Source — they share one queue.
//
// It is stateless across surfaces: every call carries its `Target` (a File
// preview commits `.file`, a Spec / Testing-Plan preview — built-in OR a
// plugin's own — commits `.spec`), so a single instance serves all
// commentable markdown previews.

import AppKit
import SwiftUI

@MainActor
public final class MarkdownPreviewCommentPresenter {

    /// What a preview comment anchors to. Determines the committed
    /// `PendingComment.Source` and which existing comments the viewer shows.
    public enum Target: Equatable {
        /// A `.md` file open in the File widget.
        case file(absolutePath: String)
        /// The Spec or Testing-Plan markdown in the Plan view (both commit
        /// `.spec(path:)`, keyed by their own path).
        case spec(path: String)
        /// A Markdown document rendered by a custom widget. The stable key
        /// keeps marks isolated between documents while the widget identity
        /// remains agent-drivable in the serialized comment.
        case widgetDocument(slug: String, documentKey: String, title: String, icon: String?)

        var commentSource: PendingComment.Source {
            switch self {
            case .file(let p): return .file(absolutePath: p)
            case .spec(let p): return .spec(path: p)
            case .widgetDocument(let slug, let key, let title, let icon):
                return .widgetDocument(slug: slug, documentKey: key, title: title, icon: icon)
            }
        }

        var displayName: String {
            switch self {
            case .file(let p), .spec(let p): return (p as NSString).lastPathComponent
            case .widgetDocument(_, _, let title, _): return title
            }
        }

        func matches(_ comment: PendingComment) -> Bool {
            switch self {
            case .file(let p):
                if case .file(let cp) = comment.source { return cp == p }
                return false
            case .spec(let p):
                if case .spec(let cp) = comment.source { return cp == p }
                return false
            case .widgetDocument(let slug, let key, _, _):
                if case .widgetDocument(let commentSlug, let commentKey, _, _) = comment.source {
                    return commentSlug == slug && commentKey == key
                }
                return false
            }
        }
    }

    private var activePopover: NSPopover?

    public init() {}

    /// The comment ranges currently on `target`, projected for the preview marks.
    public static func ranges(for target: Target, in store: PendingCommentsStore) -> [MarkdownCommentRange] {
        store.comments.compactMap { comment in
            guard target.matches(comment) else { return nil }
            return MarkdownCommentRange(startLine: comment.startLine, endLine: comment.endLine)
        }
    }

    /// The floating "add comment" button was clicked over a selection spanning
    /// `start…end` (1-based source lines). Open the composer next to it.
    public func presentComposer(
        anchorView: NSView,
        anchorRect: NSRect,
        target: Target,
        store: PendingCommentsStore,
        startLine: Int,
        endLine: Int,
        excerpt rawExcerpt: String
    ) {
        let start = max(1, startLine)
        let end = max(start, endLine)
        let excerpt = Self.firstLines(rawExcerpt, 3)
        let label = target.displayName + ":" + (start == end ? "\(start)" : "\(start)–\(end)")
        let source = target.commentSource

        let popover = NSPopover()
        popover.behavior = .transient
        let binding = Binding<Bool>(
            get: { true },
            set: { presented in if !presented { popover.performClose(nil) } }
        )
        let composer = CommentComposerPopover(
            sourceLabel: label,
            excerpt: excerpt,
            onCommit: { body in
                store.append(
                    PendingComment(
                        source: source,
                        startLine: start,
                        endLine: end,
                        excerpt: excerpt,
                        body: body
                    )
                )
            },
            isPresented: binding
        )
        popover.contentViewController = NSHostingController(rootView: composer)
        popover.contentSize = NSSize(width: 340, height: 220)
        popover.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .maxX)
        activePopover = popover
    }

    /// A comment mark was clicked — show the existing comment(s) on `line`.
    public func presentViewer(
        anchorView: NSView,
        anchorRect: NSRect,
        target: Target,
        store: PendingCommentsStore,
        line: Int
    ) {
        let matching = store.comments.filter { comment in
            target.matches(comment) && line >= comment.startLine && line <= comment.endLine
        }
        guard !matching.isEmpty else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        let binding = Binding<Bool>(
            get: { true },
            set: { presented in if !presented { popover.performClose(nil) } }
        )
        let viewer = CommentViewerPopover(
            comments: matching,
            onDelete: { id in store.remove(id: id) },
            isPresented: binding
        )
        popover.contentViewController = NSHostingController(rootView: viewer)
        popover.contentSize = NSSize(width: 340, height: 200)
        popover.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .maxX)
        activePopover = popover
    }

    private static func firstLines(_ text: String, _ n: Int) -> String {
        text.components(separatedBy: "\n").prefix(n).joined(separator: "\n")
    }
}
