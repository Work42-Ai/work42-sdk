// CommentViewerPopover.swift - Read view for pinned comment(s) on a line,
// shown when the user clicks the gutter comment MARK. Mirrors the composer's
// look (source label + excerpt blockquote) and shows each comment's body, with
// a delete affordance.
//
// Promoted into the SDK (task42-plugin-conversion, s5) alongside
// PendingCommentsStore/MarkdownPreviewCommentPresenter. The one behavior
// change: the original's `.dictationHighlightSurface()` modifier (Flow42Core-
// only — ties into the app's push-to-talk dictation-focus tracking) is
// dropped, since Work42UI must never depend on Flow42Core. Purely cosmetic
// (a focus-outline on this read-only viewer popover, not the comment
// COMPOSER where dictation actually happens — that surface stays fully wired
// via the already-promoted AnnotationRegistry/CommentComposerPopover).

import SwiftUI

public struct CommentViewerPopover: View {

    /// The comment(s) anchored at the clicked line.
    let comments: [PendingComment]

    /// Remove a comment by id.
    let onDelete: (_ id: UUID) -> Void

    /// Popover-binding control — flipped to false to dismiss.
    @Binding var isPresented: Bool

    /// Public — Work42App's `CommentGutterCoordinator` (the file-editor
    /// gutter counterpart to `MarkdownPreviewCommentPresenter`) constructs
    /// this directly; a memberwise init is never public even when every
    /// property is (task42-plugin-conversion, s5).
    public init(comments: [PendingComment], onDelete: @escaping (_ id: UUID) -> Void, isPresented: Binding<Bool>) {
        self.comments = comments
        self.onDelete = onDelete
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: DT.s8) {
                    HStack(spacing: DT.s8) {
                        Text(comment.sourceLabel)
                            .font(.system(size: DT.f11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DT.systemAccent.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button {
                            onDelete(comment.id)
                            if comments.count <= 1 { isPresented = false }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: DT.f11))
                                .foregroundStyle(DT.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete comment")
                    }

                    if !comment.excerpt.isEmpty {
                        excerptView(comment.excerpt)
                    }

                    Text(comment.body)
                        .font(.system(size: 13))
                        .foregroundStyle(DT.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if comment.id != comments.last?.id {
                    Divider()
                }
            }
        }
        .padding(DT.s12)
        .frame(width: 340)
    }

    private func excerptView(_ excerpt: String) -> some View {
        let lines = excerpt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .prefix(3)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Rectangle()
                        .fill(DT.systemAccent.opacity(0.45))
                        .frame(width: 2)
                    Text(line)
                        .font(.system(size: DT.f10, design: .monospaced))
                        .foregroundStyle(DT.systemAccent.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
