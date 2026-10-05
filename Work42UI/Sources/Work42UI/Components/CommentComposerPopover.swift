// CommentComposerPopover.swift — Reusable mini-composer popover presented
// over a text selection (PR diff, spec, file editor, diff widget) so the user
// can attach a quoted excerpt to the session's chat composer with a typed note.
//
// Originally lived in Work42App/Common/; relocated to Work42UI so widgets
// (which link Work42UI but not Work42App) can present the same affordance
// without duplicating the view (feat/generalizations-of-features.11).
//
// Generic API:
//   - `sourceLabel`  — header confirming what is being cited (e.g. "PR #42 · Foo.swift")
//   - `excerpt`      — the selected text, shown as a blockquote preview
//   - `onCommit`     — receives the trimmed body the user typed; caller appends
//                      to the session's PendingCommentsStore / composer
//   - `isPresented`  — popover binding; set to false to dismiss
//
// Nothing GitHub-specific lives here.

import SwiftUI

/// Mini-composer popover for text-selection comment attachments.
///
/// Present it as a `.popover(isPresented:attachmentAnchor:)` anchored to the
/// selection bubble. The user types a note in the `TextEditor`, then taps
/// "Add comment" — the `onCommit` callback receives the trimmed body. Cancel
/// dismisses without committing.
public struct CommentComposerPopover: View {

    /// One-line confirmation of the anchor shown in the header
    /// (e.g. `"PR #42 · Foo.swift"`, `"auth.swift:42–58"`).
    public let sourceLabel: String

    /// The selected text — rendered as a small blockquote so the user
    /// sees what they are commenting on. Pass an empty string to hide it.
    public let excerpt: String

    /// Called with the trimmed body text when the user taps "Add comment".
    /// The view dismisses itself first (flips `isPresented`), then calls this.
    public let onCommit: (_ body: String) -> Void

    /// Popover-binding control — the caller owns the boolean; set it to
    /// `false` to dismiss programmatically. The view flips it on Add / Cancel.
    @Binding public var isPresented: Bool

    @State private var draft: String = ""
    @FocusState private var bodyFocused: Bool

    public init(
        sourceLabel: String,
        excerpt: String,
        onCommit: @escaping (_ body: String) -> Void,
        isPresented: Binding<Bool>
    ) {
        self.sourceLabel = sourceLabel
        self.excerpt = excerpt
        self.onCommit = onCommit
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            Text(sourceLabel)
                .font(.system(size: DT.f11, weight: .semibold, design: .monospaced))
                .foregroundStyle(DT.systemAccent.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)

            if !excerpt.isEmpty {
                excerptView
            }

            TextEditor(text: $draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .foregroundStyle(DT.systemAccent)
                .frame(minHeight: 72, maxHeight: 160)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DT.systemAccent.opacity(0.06))
                )
                .focused($bodyFocused)

            HStack(spacing: DT.s8) {
                Spacer(minLength: 0)
                Button("Cancel") { isPresented = false }
                    .glassSubtleCapsule(tint: DT.textSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Add comment") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    isPresented = false
                    onCommit(trimmed)
                }
                .glassProminentCapsule(tint: DT.systemAccent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DT.s12)
        .frame(width: 340)
        .onAppear {
            bodyFocused = true
            // Self-register for dictation-to-comment: while THIS dialog is open,
            // push-to-talk commits the transcript as the comment (reusing the
            // caller's `onCommit`) instead of typing. One hook, every surface
            // that opens this popover (spec, code, testing plan, diff, markdown,
            // artifact, PR) gets it for free.
            AnnotationRegistry.shared.present(CommentableSelection(
                sourceLabel: sourceLabel,
                excerpt: excerpt,
                screenRect: nil,
                makeComment: { body in
                    isPresented = false
                    onCommit(body)
                }
            ))
        }
        .onDisappear { AnnotationRegistry.shared.clear() }
    }

    private var excerptView: some View {
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
