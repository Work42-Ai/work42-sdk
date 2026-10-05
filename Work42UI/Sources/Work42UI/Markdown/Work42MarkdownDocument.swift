// Work42MarkdownDocument.swift - The one call a plugin widget makes to
// render a themed, comment- and artifact-integrated markdown document
// (task42-plugin-conversion, s6).
//
// Bundles three things a rich markdown widget (a spec, a testing plan)
// needs, each promoted into the SDK by an earlier subtask in this same
// effort, so a plugin widget gets full parity with the built-in spec widget
// without re-wiring any of this by hand:
//   - MarkdownPreview + the `.work42` theme (already public).
//   - `[[artifact:id]]` inline embeds, resolved via the promoted
//     `ArtifactRuntime` (s4) — needs only `sessionId` (s3's
//     `SessionServices.sessionId`).
//   - The shared pending-comment store + composer strip + dictation-to-
//     comment, via the promoted `PendingCommentsStore` /
//     `MarkdownPreviewCommentPresenter` / `AnnotationRegistry` (s5) — read
//     automatically from `@Environment(\.pendingComments)`, the SAME
//     environment key the host injects around every widget (built-in or
//     plugin) in the session's widget grid, so no extra wiring is needed
//     to join the shared strip.
//
// What this does NOT do: register the session with `ArtifactRuntime`
// (`ArtifactRuntime.register(sessionId:directory:)`). That needs a
// worktree PATH, not just an id, and is a session-lifecycle concern, not a
// per-render one — the owning widget calls it once, typically in
// `activate(services:)` or its view's `.onAppear`, using
// `services.sessionId` + `services.worktreePath` (both from s3). Every
// artifact-rendering widget in a session (built-in or plugin) already
// does its own opportunistic registration this way, so the server can
// resolve the directory regardless of which widget mounted first.

import SwiftUI
import AppKit

/// A themed markdown document with inline `[[artifact:id]]` embeds and a
/// shared, session-scoped comment layer — the spec/testing-plan shape. For
/// a read-only document with no comment layer (e.g. a QA report display),
/// use `MarkdownPreview`/`Markdown` directly instead.
public struct Work42MarkdownDocument: View {
    /// Optional custom-widget identity for comments created from this
    /// document. Omit it for Spec/Testing Plan compatibility.
    public struct CommentWidget: Sendable {
        public let slug: String
        public let title: String
        public let icon: String?

        public init(slug: String, title: String, icon: String? = nil) {
            self.slug = slug
            self.title = title
            self.icon = icon
        }
    }

    @Environment(\.pendingComments) private var pendingComments
    @State private var presenter = MarkdownPreviewCommentPresenter()

    private let text: String
    private let sessionId: String?
    private let commentKey: String
    private let artifactsEnabled: Bool
    private let baseURL: URL?
    private let autoHeight: Bool
    private let commentWidget: CommentWidget?

    /// - Parameters:
    ///   - text: The markdown source to render.
    ///   - sessionId: The owning session's id (`services.sessionId`, s3).
    ///     `nil` disables artifact-embed resolution regardless of
    ///     `artifactsEnabled` (there is no session to scope the embed to).
    ///   - commentKey: A stable, session-scoped key identifying WHAT is being
    ///     commented on (e.g. `"plan/spec"`, `"plan/testing"`) — comments
    ///     pinned here are isolated from comments on any other document in
    ///     the same session. Mirrors the built-in spec widget's
    ///     `"<sessionId>/plan/spec"` convention; combined with `sessionId`
    ///     internally so two sessions' `"plan/spec"` documents never collide.
    ///   - artifactsEnabled: Whether standalone `[[artifact:<id>]]` token
    ///     lines render as live embeds. Defaults to `true`.
    ///   - baseURL: Optional worktree root for resolving relative links in
    ///     the markdown (e.g. `services.worktreePath` as a `URL`). `nil`
    ///     (the default) leaves relative links unresolved.
    ///   - autoHeight: Forwarded to `MarkdownPreview` — sizes the document to
    ///     its rendered content instead of filling the available space.
    public init(
        text: String,
        sessionId: String?,
        commentKey: String,
        artifactsEnabled: Bool = true,
        baseURL: URL? = nil,
        autoHeight: Bool = false,
        commentWidget: CommentWidget? = nil
    ) {
        self.text = text
        self.sessionId = sessionId
        self.commentKey = commentKey
        self.artifactsEnabled = artifactsEnabled
        self.baseURL = baseURL
        self.autoHeight = autoHeight
        self.commentWidget = commentWidget
    }

    /// The comment-presenter target — `sessionId` folded in so the SAME
    /// `commentKey` in two different sessions never shares comment marks.
    private var target: MarkdownPreviewCommentPresenter.Target {
        let key = "\(sessionId ?? "no-session")/\(commentKey)"
        if let commentWidget {
            return .widgetDocument(
                slug: commentWidget.slug,
                documentKey: key,
                title: commentWidget.title,
                icon: commentWidget.icon
            )
        }
        return .spec(path: key)
    }

    public var body: some View {
        MarkdownPreview(
            text: text,
            baseURL: baseURL,
            commentsEnabled: true,
            comments: MarkdownPreviewCommentPresenter.ranges(for: target, in: pendingComments),
            onAddComment: { view, rect, start, end, excerpt in
                presenter.presentComposer(
                    anchorView: view, anchorRect: rect, target: target,
                    store: pendingComments, startLine: start, endLine: end, excerpt: excerpt
                )
            },
            onViewComment: { view, rect, line in
                presenter.presentViewer(
                    anchorView: view, anchorRect: rect, target: target,
                    store: pendingComments, line: line
                )
            },
            onSelectionChanged: { start, end, excerpt in
                publishAnnotation(start: start, end: end, excerpt: excerpt)
            },
            onSelectionCleared: { AnnotationRegistry.shared.clear() },
            artifactURLResolver: (artifactsEnabled ? sessionId : nil).map { sid in
                { (artifactId: String) in ArtifactRuntime.url(sessionId: sid, artifactId: artifactId) }
            },
            autoHeight: autoHeight
        )
    }

    /// Publishes the live text selection to the shared `AnnotationRegistry`
    /// (dictation-to-comment: highlight → push-to-talk → comment), mirroring
    /// the built-in spec widget's `publishSpecAnnotation`. Uses only
    /// already-promoted SDK types (`AnnotationRegistry`/`CommentableSelection`
    /// /`PendingComment`/`PendingCommentsStore`, s5) — no Flow42Core
    /// dependency.
    private func publishAnnotation(start: Int, end: Int, excerpt: String) {
        let store = pendingComments
        let fileName = (commentKey as NSString).lastPathComponent
        let lineSpan = start == end ? "\(start)" : "\(start)–\(end)"
        AnnotationRegistry.shared.present(CommentableSelection(
            sourceLabel: "\(fileName):\(lineSpan)",
            excerpt: excerpt,
            screenRect: nil,
            makeComment: { body in
                store.append(PendingComment(
                    source: target.commentSource,
                    startLine: start, endLine: end, excerpt: excerpt, body: body
                ))
            }
        ))
    }
}
