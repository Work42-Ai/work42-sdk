// PendingCommentsStore.swift - In-memory queue of PR-review-style
// comments the user has staged but not yet sent.
//
// Promoted into the SDK (task42-plugin-conversion, s5) from
// Sources/Flow42Core/Chat/PendingCommentsStore.swift, so a hot-loaded
// plugin widget — which can only link Work42UI.framework +
// Work42PluginKit.framework, never Flow42Core — joins the SAME shared
// comment store as the built-in spec/file widgets, instead of maintaining
// its own disconnected queue. Flow42Core `@_exported import`s Work42UI
// (Design.swift), so every existing unqualified `PendingComment` /
// `PendingCommentsStore` reference in Work42App keeps resolving unchanged
// through `import Flow42Core` — this is a straight relocation, not a
// behavior change.
//
// The ONE dependency this promotion removes: the original bound to
// `ChatSession` + `ComposerDraftHandle` (Flow42Core's chat-composer
// persistence layer) directly. That binding now goes through the
// `PendingCommentsPersisting` protocol below — Flow42Core's own
// `Sources/Flow42Core/Chat/PendingCommentsStore.swift` (now just the
// session-aware convenience init + the `ComposerDraftHandle` conformance)
// wires the real persistence; Work42UI itself never needs to know
// `ChatSession` exists.
//
// Lifetime matches the session detail panel — the store is a
// `@StateObject` there, so closing the panel drops the queue. On-
// disk persistence (per-session drafts) is a follow-up.

import CoreGraphics
import Foundation
import SwiftUI

/// One pinned comment ready to be flushed into the next chat
/// prompt. Carries the absolute / repo-relative path of what was
/// commented on plus a 1-based inclusive line range and a short
/// excerpt of the underlying text — enough that the agent reading
/// the prompt has both the citation (path + line) and the visible
/// snippet to reason against.
/// Which side of a PR diff a `.prWebView` selection landed on (AC6 —
/// cozy-nimbus). A **removed** line no longer exists in the checked-out
/// working tree, so the comment must tell the agent to read it from the
/// PR git diff rather than the file. The kind is extracted from GitHub's
/// React diff DOM (the row's addition/deletion/context marker plus the
/// `data-line-anchor` `R`/`L` prefix as a secondary signal).
public enum PRChangeKind: String, Equatable, Sendable, Codable {
    case added, removed, context

    /// Map the raw `change` string posted by the selection-tracking JS to
    /// the enum. The JS emits `"added"` / `"removed"` / `"context"`
    /// directly; this is the single decode seam so the mapping is unit-
    /// testable without WebKit. Returns nil for any unrecognized / missing
    /// value so the caller falls back to the file-only / text-only block.
    public init?(jsValue: String?) {
        guard let jsValue else { return nil }
        switch jsValue {
        case "added": self = .added
        case "removed": self = .removed
        case "context": self = .context
        default: return nil
        }
    }
}

public struct PendingComment: Identifiable, Equatable, Sendable {
    public enum DiffSide: String, Equatable, Sendable, Codable {
        case old, new
    }

    /// Where the comment is anchored. Plain enum because each
    /// surface carries different metadata — the Diff widget in
    /// particular needs the +/- side so the prompt can disambiguate
    /// "before this line" vs "this line you added".
    public enum Source: Equatable, Sendable {
        case spec(path: String)
        case file(absolutePath: String)
        case diff(absolutePath: String, side: DiffSide)
        /// A selection made in the GitHub PR WebView widget (AC2 —
        /// cozy-nimbus). Carries the PR URL for citation and the
        /// selected text as the excerpt. No file-line anchor: the
        /// selection is page-content, not a source file. `startLine`
        /// and `endLine` on the owning `PendingComment` are both 0.
        ///
        /// `filePath` is the repo-relative path of the diff file the
        /// selection was made in (e.g. `Sources/Foo/Bar.swift`), extracted
        /// from the GitHub diff DOM's `data-path` attribute. It is `nil`
        /// when the selection is in the PR description or a comment thread
        /// rather than a diff file section.
        ///
        /// `line` + `change` (AC6 — cozy-nimbus) make the anchor diff-aware:
        /// `line` is the diff line number (`data-line-number` from the React
        /// diff DOM) and `change` says which side it is. Both are `nil` for
        /// a selection outside a diff row (PR description, comment thread),
        /// in which case the block degrades to the file-only / text-only
        /// framing. A **removed** line is not in the checkout, so the
        /// serialized block points the agent at the PR diff (not the file).
        case prWebView(prUrl: String, excerpt: String, filePath: String?, line: Int?, change: PRChangeKind?)
        /// An element picked inside one of the four embedded WKWebView tiles
        /// (Browser, Jira, GitHub PR, Canvas) via the in-tile element picker
        /// (AC4 — lanky-pine). Carries the page URL for citation, the CSS
        /// selector that uniquely identifies the element, the element's
        /// normalized text content as the excerpt, and an optional path to a
        /// screenshot crop of the element's bounding box. `startLine` and
        /// `endLine` on the owning `PendingComment` are both 0 (no line anchor
        /// — this is a page-element reference, not a source-file reference).
        case browserHighlight(pageUrl: String, selector: String, excerpt: String, screenshotPath: String?)
        /// A text selection made inside an open **artifact** (the HTML render
        /// surface shown in the Artifacts gallery). Carries the artifact id +
        /// title for citation and the selected text as the excerpt. No
        /// source-file line anchor — `startLine`/`endLine` are both 0.
        case artifact(artifactId: String, artifactTitle: String, excerpt: String)
        /// A region captured via the Cmd-Shift-A drag-select in
        /// `AnnotationController`, routed to the comment box for
        /// task / codeReview / plain sessions
        /// (gleeful-glacier AC9, AC10).
        ///
        /// Carries the FULL rich payload from `ScreenHighlight`:
        /// - `appName`        — localised name of the frontmost app at capture time (nil if unknown).
        /// - `rect`           — captured rectangle in global Quartz screen coordinates.
        /// - `screenshotPath` — absolute path to the region PNG, when capture succeeded.
        /// - `ocrText`        — Vision OCR `fullText` for the captured region (nil if unavailable).
        /// - `bundleId`       — bundle identifier of the frontmost app (nil if unknown).
        ///
        /// `startLine` and `endLine` on the owning `PendingComment` are both 0
        /// (no source-file line anchor).
        case screenHighlight(
            appName: String?,
            rect: CGRect,
            screenshotPath: String?,
            ocrText: String?,
            bundleId: String?
        )
        /// A recording the user captured on a preview tile (or via `flow42
        /// learn`), staged as an unsent draft instead of auto-creating a flow —
        /// "here's what I did, take a look." Carries the recording bundle dir,
        /// the device name, the captured step count, and an optional video path.
        /// No source-file line anchor (`startLine`/`endLine` are both 0).
        case recording(
            bundlePath: String,
            deviceName: String,
            stepCount: Int,
            videoPath: String?
        )
        /// A comment staged by a hot-loaded custom widget via
        /// `services.composer.attach` (feat/custom-widgets.4). Unlike every
        /// other source, the label is supplied directly by the widget
        /// (opaque call-site context, not a structured file/URL/rect this
        /// store can re-derive a label from) — `sourceLabel` IS the label.
        /// `startLine`/`endLine` on the owning `PendingComment` are both 0.
        ///
        /// `icon` (bug/pill-push-to-talk dogfooding follow-up) is the
        /// widget's own SF Symbol glyph — the SAME one the `+ Widget`
        /// popover shows for it — resolved by the CALLER
        /// (`CustomWidgetSessionServices.swift`, Work42App) via
        /// `Work42WidgetCatalog.shared` at comment-creation time, since
        /// this store can't reach that catalog itself (see `kindTag`
        /// below). `nil` when the catalog has no spec for the slug
        /// (shouldn't normally happen) — falls back to the generic
        /// puzzle-piece glyph.
        case widget(slug: String, sourceLabel: String, icon: String? = nil)
        /// A line-anchored selection inside a Markdown document owned by a
        /// custom widget. `documentKey` isolates comment marks between the
        /// widget's documents while `title` stays concise in the composer.
        case widgetDocument(
            slug: String,
            documentKey: String,
            title: String,
            icon: String? = nil
        )
        /// A WHOLE-WIDGET comment (comments-on-widgets.3): the user dictated
        /// while a widget was focused with NO text selection, so the comment
        /// targets the entire widget rather than a highlighted span. Carries
        /// the widget's own agent-drivable type/kindId (`widgetType` — drives
        /// `widgetId`/`work42 widget <id>`), its SF Symbol `iconGlyph` (for the
        /// card icon, resolved by the caller in Work42App), a human `title`, and
        /// the widget's type-specific `context` (browser page URL, file path,
        /// artifact id+title, PR URL, custom slug+label — nil when none). The
        /// comment box is TEXT-ONLY: the widget screenshot is sent as a SEPARATE
        /// `ChatAttachment` (image rendered OUTSIDE the comment card, like a
        /// manually-attached file, removable independently — comments-on-
        /// widgets.6), not embedded here. `startLine`/`endLine` are both 0;
        /// `excerpt` is empty (no selection) — the dictated text is the `body`.
        case wholeWidget(
            widgetType: String,
            iconGlyph: String,
            title: String,
            context: String?
        )
        /// A comment restored from the session's persisted composer draft
        /// (`ComposerComment.serializedText`) after an app relaunch —
        /// per-session-composer AC2. Only the flat, already-serialized text
        /// survives the round trip through `session_composer`, not the
        /// original structured `Source` (a `.screenHighlight`'s `CGRect`,
        /// a `.prWebView`'s resolved diff anchor, etc. are gone). Carries
        /// that raw block VERBATIM so `serializedBlock` echoes it byte-for-
        /// byte back into the prompt on send — `sourceLabel`/`kindTag`/the
        /// card's `body` are re-derived once at restore time via
        /// `CommentMarker.decodeStaged`. No typed re-anchoring (e.g.
        /// `updateAnchor`) applies once a comment is in this shape.
        case restored(rawBlock: String)
    }

    public let id: UUID
    public let source: Source
    /// 1-based inclusive.
    public let startLine: Int
    public let endLine: Int
    /// The first ~3 lines of the underlying text — rendered in the
    /// composer card as a `> quoted` block so the user can see
    /// what they're commenting on without leaving the chat.
    public let excerpt: String
    public var body: String

    public init(
        id: UUID = UUID(),
        source: Source,
        startLine: Int,
        endLine: Int,
        excerpt: String,
        body: String
    ) {
        self.id = id
        self.source = source
        self.startLine = startLine
        self.endLine = endLine
        self.excerpt = excerpt
        self.body = body
    }

    /// Human-readable label for the composer card — e.g.
    /// `spec.md:12–18`, `auth.swift:42`, `Diff README.md (+14)`,
    /// or `PR #123` for a WebView selection.
    public var sourceLabel: String {
        let lineSuffix = startLine == endLine ? "\(startLine)" : "\(startLine)–\(endLine)"
        switch source {
        case .spec(let path):
            return "\((path as NSString).lastPathComponent):\(lineSuffix)"
        case .file(let absolutePath):
            return "\((absolutePath as NSString).lastPathComponent):\(lineSuffix)"
        case .diff(let absolutePath, let side):
            let sign = side == .new ? "+" : "−"
            let name = (absolutePath as NSString).lastPathComponent
            return "Diff \(name) (\(sign)\(lineSuffix))"
        case .prWebView(let prUrl, _, let filePath, let line, let change):
            // Diff-aware label (AC6). When the selection has a file + line,
            // mirror the `.diff` sign convention: removed → `Bar.swift −88`,
            // added → `Bar.swift +88`, context → `Bar.swift 88`. Without a
            // line, fall back to the PR-number label: `PR #123 · Bar.swift`
            // or just `PR #123`.
            if let filePath, !filePath.isEmpty, let line {
                let fileName = (filePath as NSString).lastPathComponent
                let sign: String
                switch change {
                case .removed: sign = "−"
                case .added: sign = "+"
                case .context, .none: sign = ""
                }
                return "\(fileName) \(sign)\(line)"
            }
            // Extract PR number from the URL for a concise label, e.g.
            // "PR #123". Fall back to the last path component if parsing
            // fails (e.g. a non-standard URL shape).
            let prNumber: String
            if let url = URL(string: prUrl),
               let num = url.pathComponents.last.flatMap(Int.init) {
                prNumber = "PR #\(num)"
            } else {
                prNumber = (prUrl as NSString).lastPathComponent
            }
            if let filePath, !filePath.isEmpty {
                let fileName = (filePath as NSString).lastPathComponent
                return "\(prNumber) · \(fileName)"
            }
            return prNumber
        case .browserHighlight(let pageUrl, let selector, _, _):
            // Truncate the selector to ~40 chars for a compact card label,
            // then append the page host so the user can glance at both.
            let truncated = selector.count > 40
                ? String(selector.prefix(37)) + "…"
                : selector
            let host = URL(string: pageUrl)?.host ?? pageUrl
            return "\(truncated) — \(host)"
        case .artifact(_, let title, _):
            return "Artifact — \(title)"
        case .screenHighlight(let appName, let rect, _, _, _):
            // "Highlight — <app> WxH" (e.g. "Highlight — Safari 480×220").
            // Width and height are rounded to integers for a compact label.
            let app = appName ?? "Unknown"
            let w = Int(rect.size.width.rounded())
            let h = Int(rect.size.height.rounded())
            return "Highlight — \(app) \(w)×\(h)"
        case .recording(_, let deviceName, let stepCount, _):
            let steps = stepCount == 1 ? "1 step" : "\(stepCount) steps"
            return "Recording — \(deviceName) (\(steps))"
        case .widget(_, let label, _):
            return label
        case .widgetDocument(_, _, let title, _):
            return "\(title):\(lineSuffix)"
        case .wholeWidget(_, _, let title, _):
            return title
        case .restored(let rawBlock):
            return CommentMarker.decodeStaged(rawBlock).label
        }
    }

    /// Stable kind tag for the `[[comment:...]]` display marker (bug/pill-
    /// push-to-talk.8) — shared with `PendingCommentCard.icon(forKindTag:)`
    /// so both the live card (keyed by `comment.kindTag`) and the sent-bubble
    /// renderer (keyed by the tag decoded from the marker) use the exact same
    /// icon table. `.recording` is excluded — it already has its own
    /// `[[recording:<dir>]]` display convention, untouched here.
    public var kindTag: String {
        switch source {
        case .spec:              return "spec"
        case .file:               return "file"
        case .diff:               return "diff"
        case .prWebView:         return "prWebView"
        case .browserHighlight:  return "browserHighlight"
        case .artifact:           return "artifact"
        case .screenHighlight:   return "screenHighlight"
        case .recording:         return "recording"   // unused — see above
        // Compound tag (dogfooding follow-up) carrying the widget's OWN
        // resolved glyph — `PendingCommentCard.icon(forKindTag:)` special-
        // cases the "widget:" prefix so both the live card and the sent-
        // bubble card (which only ever sees this decoded tag string, never
        // the original `Source`) show the SAME real widget icon rather than
        // the generic puzzle-piece fallback. Plain "widget" when the icon
        // couldn't be resolved at creation time.
        case .widget(_, _, let icon):
            guard let icon, !icon.isEmpty else { return "widget" }
            return "widget:\(icon)"
        case .widgetDocument(_, _, _, let icon):
            guard let icon, !icon.isEmpty else { return "widget" }
            return "widget:\(icon)"
        // Whole-widget comment: reuse the `widget:<glyph>` icon path so the
        // card shows the focused widget's real SF Symbol (built-in or custom).
        case .wholeWidget(_, let iconGlyph, _, _):
            return iconGlyph.isEmpty ? "widget" : "widget:\(iconGlyph)"
        // Re-derived from the persisted block's own marker so a restored
        // chip shows the SAME icon it had before the app relaunched.
        case .restored(let rawBlock):
            return CommentMarker.decodeStaged(rawBlock).kindTag
        }
    }

    /// `"w_" + kindId` with colons mapped to underscores (e.g. `widget:github`
    /// becomes `w_widget_github`) — reproduced inline rather than calling
    /// `Flow42Core.WidgetRuntime.runtimeId(forKindId:)` (task42-plugin-
    /// conversion, s5): Work42UI must never depend on Flow42Core, which
    /// plugins don't link at all. Single source of truth for the derivation
    /// stays `WidgetRuntime.runtimeId(forKindId:)` in Flow42Core — this is a
    /// verbatim reproduction, same policy `Work42DB.StorageValue` documents
    /// for a cross-target primitive.
    private static func widgetRuntimeId(forKindId kindId: String) -> String {
        "w_" + kindId.replacingOccurrences(of: ":", with: "_")
    }

    /// The kind id (`WidgetRuntime.Descriptor.type`) of the session widget this
    /// comment originated from, or nil when the comment has no owning widget
    /// (a raw screen-region capture, or a recording). These string literals
    /// MIRROR `SessionDetailPanel.Widget`'s rawValues + `CustomWidgetLoader
    /// .kindId(forSlug:)` (both in Work42App, which this SDK can't import —
    /// same dependency direction + keep-in-sync contract as
    /// `PendingCommentCard.icon(forKindTag:)`). This is what travels to the
    /// agent as the drivable widget's `type` (comments-on-widgets AC6).
    public var widgetType: String? {
        switch source {
        case .spec:              return "spec"
        case .file:               return "files"
        case .diff:               return "diff"
        // The GitHub PR surface is the prebuilt `github` custom widget
        // (work42-plugins) — kindId `widget:github`.
        case .prWebView:         return "widget:github"
        case .browserHighlight:  return "browser"
        case .artifact:           return "artifacts"
        case .widget(let slug, _, _): return "widget:\(slug)"
        case .widgetDocument(let slug, _, _, _): return "widget:\(slug)"
        // Whole-widget comment carries the focused widget's own kindId already.
        case .wholeWidget(let widgetType, _, _, _): return widgetType
        // No owning widget instance to drive. A restored comment's original
        // owning widget (if any) isn't recoverable from flat text.
        case .screenHighlight, .recording, .restored: return nil
        }
    }

    /// The stable, agent-addressable id of the originating widget —
    /// `w_<kindId>` with colons mapped to underscores, matching
    /// `SessionDetailPanel.widgetRuntimeId(for:)` /
    /// `WidgetRuntime.runtimeId(forKindId:)` so `work42 widget <id> …`
    /// resolves it. Nil when `widgetType` is nil (comments-on-widgets AC6).
    public var widgetId: String? {
        widgetType.map(Self.widgetRuntimeId(forKindId:))
    }

    /// One agent-facing line telling the agent it can inspect or drive the
    /// originating widget (comments-on-widgets AC6). Empty (no line) when the
    /// comment has no owning widget. Injected into the serialized block AFTER
    /// the header and BEFORE the excerpt/body so it reaches the agent's prompt
    /// but is not rendered on the sent card (whose label is the header line and
    /// whose body is the text after the first blank line — see
    /// `CommentMarker.reconstruct`). Includes a trailing newline when present
    /// so callers can interpolate it inline.
    var widgetHintLine: String {
        guard let id = widgetId, let type = widgetType else { return "" }
        return "Widget: `\(id)` (type `\(type)`) — inspect or drive it with `work42 widget \(id) list`.\n"
    }

    /// Wraps `block` with the lean `[[comment:<kindTag>]] ... [[/comment]]`
    /// display marker (comments-on-widgets.1) — mirrors the existing
    /// `[[recording:<dir>]]` convention (Flow42ChatView.swift's
    /// `Flow42UserMessageBubble.parseAttachments`) already parsed out of sent
    /// text to swap prose for a rich card.
    ///
    /// The marker carries ONLY the `kindTag` — nothing else. The renderer
    /// reconstructs the card's label + body from the enclosed prose `block`
    /// itself (label = the header line, body = the text after the first blank
    /// line), so nothing is duplicated into the outgoing prompt: previously
    /// the label AND body were base64-encoded into the marker on top of the
    /// same content already written in `block`, roughly doubling the comment
    /// payload the agent received (comments-on-widgets thread 2).
    ///
    /// Because `kindTag` is the ONLY field and the last thing before `]]`, a
    /// colon inside it (the compound `widget:<icon>` tag, where `<icon>` is an
    /// SF Symbol name containing a dot — e.g. `widget:puzzlepiece.extension`)
    /// is now harmless: the decoder strips the `[[comment:` prefix and `]]`
    /// suffix and takes the remainder verbatim, with no positional colon split
    /// to miscount (comments-on-widgets thread 1 — the "weird raw comment"
    /// bug, which fired only on custom-widget comments).
    private func markedBlock(_ block: String) -> String {
        return "[[comment:\(kindTag)]]\n\(block)\n[[/comment]]"
    }

    /// Caps OCR text bulk for the `.screenHighlight` prompt block
    /// (comments-on-widgets AC5) and strips blank lines. The blank-line strip
    /// is load-bearing: the sent-bubble renderer reconstructs a comment's body
    /// as the block text after the FIRST blank line, so an OCR dump containing
    /// its own blank line would otherwise split the body in the wrong place.
    public static func boundedOCR(_ text: String, max: Int = 800) -> String {
        let collapsed = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if collapsed.count <= max { return collapsed }
        return String(collapsed.prefix(max)) + " […]"
    }

    /// Markdown block that goes into the outgoing prompt for this
    /// one comment. The excerpt is rendered as a blockquote and
    /// the body follows after a blank line.
    public var serializedBlock: String {
        let header: String
        switch source {
        case .spec(let path):
            header = "On \((path as NSString).lastPathComponent) (lines \(lineSpan)):"
        case .file(let absolutePath):
            header = "On \((absolutePath as NSString).lastPathComponent) (lines \(lineSpan)):"
        case .diff(let absolutePath, let side):
            let sign = side == .new ? "+" : "−"
            header = "On \((absolutePath as NSString).lastPathComponent) diff (line \(sign)\(lineSpan)):"
        case .prWebView(let prUrl, _, let filePath, let line, let change):
            // Diff-aware framing (AC6). When the selection carries a file +
            // line, point the agent at the PR git diff and name the side —
            // a removed line is NOT in the checkout, so reading the file
            // would show the wrong (or no) content. The agent reads the line
            // from the PR diff on the named side.
            if let filePath, !filePath.isEmpty, let line {
                let fileName = (filePath as NSString).lastPathComponent
                switch change {
                case .removed:
                    header = "In \(fileName) — removed line (old #\(line)), read from the PR diff:"
                case .added:
                    header = "In \(fileName) — added line (new #\(line)), read from the PR diff:"
                case .context, .none:
                    header = "In \(fileName) — line \(line) (read from the PR diff):"
                }
            } else if let filePath, !filePath.isEmpty {
                // File known but no line (selection wasn't in a diff row).
                header = "On PR (\(prUrl)) in \(filePath) — selected text:"
            } else {
                // No file-line anchor (PR description / comment thread).
                header = "On PR (\(prUrl)) — selected text:"
            }
        case .browserHighlight(let pageUrl, let selector, _, let screenshotPath):
            // Build the main block with a markdown inline-code selector and a
            // blockquote excerpt; append the screenshot path line if present.
            let quote = excerpt
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            var block = "On \(pageUrl), the user is pointing at `\(selector)`:\n\(widgetHintLine)\(quote)\n\n\(body)"
            if let screenshotPath {
                block += "\nScreenshot: \(screenshotPath)"
            }
            return markedBlock(block)
        case .screenHighlight(let appName, let rect, let screenshotPath, let ocrText, let bundleId):
            // Full rich payload block (AC10): app, rect, OCR text, screenshot.
            // The agent sees the capture context (what app + what region) and
            // the extracted text so it can reason without opening the image.
            let app = appName ?? "Unknown"
            let w = Int(rect.size.width.rounded())
            let h = Int(rect.size.height.rounded())
            var lines: [String] = [
                "The user captured a screen region in \(app) (\(w)×\(h) px).",
            ]
            if let bundleId {
                lines.append("App bundle: \(bundleId)")
            }
            if let screenshotPath {
                lines.append("Screenshot: \(screenshotPath)")
            }
            if let ocrText, !ocrText.isEmpty {
                lines.append("Extracted text:\n\(Self.boundedOCR(ocrText))")
            }
            if !body.isEmpty {
                lines.append("\n\(body)")
            }
            return markedBlock(lines.joined(separator: "\n"))
        case .recording(let bundlePath, let deviceName, let stepCount, let videoPath):
            // The leading `[[recording:<dir>]]` token is the CHAT-RENDER hook:
            // the sent user bubble replaces the token + the contiguous prose
            // lines under it with a clickable RecordingMessageCard (the agent
            // still sees the whole block verbatim — the prose is for it).
            // Untouched by bug/pill-push-to-talk.8's [[comment:...]] marker —
            // this is its own pre-existing convention.
            var lines = [
                "[[recording:\(bundlePath)]]",
                "The user recorded a demonstration on \(deviceName) "
                    + "(\(stepCount) step(s)) to show you what they did.",
                "Recording bundle: \(bundlePath)",
            ]
            if let videoPath { lines.append("Video: \(videoPath)") }
            lines.append(
                "The video is the source of truth for each step's visual — "
                    + "extract any event's frame with `flow42 frame \(bundlePath) --event N`."
            )
            if !body.isEmpty { lines.append("\n\(body)") }
            return lines.joined(separator: "\n")
        case .wholeWidget(_, _, let title, let context):
            // No text selection — the whole widget is the subject. The header
            // is the card label; the widget hint + type-specific context ride in
            // the "ignored middle" (between header and the blank line) so the
            // agent sees them but the sent card (label + body-after-blank) stays
            // clean; the dictated text is the body. The screenshot is NOT here —
            // it ships as a separate ChatAttachment (comments-on-widgets.6).
            var lines = ["The user is pointing at the whole \(title) widget."]
            if !widgetHintLine.isEmpty { lines.append(String(widgetHintLine.dropLast())) }
            if let context, !context.isEmpty { lines.append(context) }
            lines.append("")          // blank separator
            lines.append(body)
            return markedBlock(lines.joined(separator: "\n"))
        case .restored(let rawBlock):
            // Echo the persisted text back VERBATIM — it is already the
            // exact block that was flushed into a prompt before (or would
            // have been, had the draft been sent). Re-deriving it from the
            // reconstructed label/body would drop the original excerpt
            // quote + widget hint riding in the "ignored middle".
            return rawBlock
        case .artifact(let artifactId, let title, _):
            header = "On artifact '\(title)' (id `\(artifactId)`) — the user highlighted this text:"
        case .widget(let slug, let label, _):
            header = "From the '\(slug)' widget (\(label)):"
        case .widgetDocument(let slug, _, let title, _):
            header = "On \(title) in the '\(slug)' widget (lines \(lineSpan)):"
        }
        let quote = excerpt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        // The widget self-drive hint (comments-on-widgets AC6) sits between the
        // header and the excerpt/body: the agent sees it in the prompt, but the
        // sent card (label = header, body = after the first blank line) does
        // not render it. Empty for a comment with no owning widget.
        return markedBlock("\(header)\n\(widgetHintLine)\(quote)\n\n\(body)")
    }

    private var lineSpan: String {
        startLine == endLine ? "\(startLine)" : "\(startLine)–\(endLine)"
    }
}

/// Pure decode/reconstruct helpers for the sent-bubble comment marker
/// (comments-on-widgets thread 1 & 2). Extracted so the chat renderer
/// (`Flow42UserMessageBubble.parseAttachments`, a private view type in
/// Flow42Core) and unit tests exercise the SAME logic — the write side is
/// `PendingComment.markedBlock`.
///
/// New lean marker: `[[comment:<kindTag>]] … [[/comment]]` — the `kindTag` is
/// the only field, taken verbatim so the compound `widget:<glyph>` tag (whose
/// glyph is a dot-bearing SF Symbol name) is preserved rather than miscounted
/// by a positional split; the card's label + body are reconstructed from the
/// enclosed prose block. Legacy markers
/// (`[[comment:<kindTag>:<labelB64>:<bodyB64>]]`) still decode for old
/// transcripts.
public enum CommentMarker {
    /// A decoded opening `[[comment:…]]` line. For a legacy marker the
    /// base64-carried `legacyLabel`/`legacyBody` are populated; for the new
    /// lean marker both are nil (label/body come from the block).
    public struct Decoded: Equatable, Sendable {
        public let kindTag: String
        public let legacyLabel: String?
        public let legacyBody: String?
    }

    private static let openPrefix = "[[comment:"
    public static let closeMarker = "[[/comment]]"

    /// Decodes an opening marker line (already whitespace-trimmed). Returns
    /// nil for a non-marker line.
    public static func decodeOpen(_ trimmed: String) -> Decoded? {
        guard trimmed.hasPrefix(openPrefix), trimmed.hasSuffix("]]"),
              trimmed.count > openPrefix.count + 2
        else { return nil }
        let innerStart = trimmed.index(trimmed.startIndex, offsetBy: openPrefix.count)
        let innerEnd = trimmed.index(trimmed.endIndex, offsetBy: -2)
        let inner = String(trimmed[innerStart..<innerEnd])
        // Legacy 4-field marker: exactly 3 colon fields whose 2nd + 3rd
        // base64-decode to UTF-8. A new marker never satisfies this (a bare
        // tag like `file`, or `widget:<glyph>` whose glyph isn't valid base64).
        let parts = inner.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3,
           let labelData = Data(base64Encoded: String(parts[1])),
           let bodyData = Data(base64Encoded: String(parts[2])),
           let label = String(data: labelData, encoding: .utf8),
           let body = String(data: bodyData, encoding: .utf8) {
            return Decoded(kindTag: String(parts[0]), legacyLabel: label, legacyBody: body)
        }
        return Decoded(kindTag: inner, legacyLabel: nil, legacyBody: nil)
    }

    /// Reconstructs a lean-marker comment's card fields from the enclosed
    /// prose `block`: `label` is the header (first non-empty line, trailing
    /// `:` dropped); `body` is the text after the FIRST blank line (empty when
    /// there is none — a context-only comment). The excerpt/quote lines
    /// between header and blank are intentionally omitted, matching the
    /// pre-redesign sent-card look.
    public static func reconstruct(block: [String]) -> (label: String, body: String) {
        let label: String = block
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasSuffix(":") ? String(t.dropLast()) : t
            } ?? ""
        var body = ""
        if let blankIdx = block.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            body = block[block.index(after: blankIdx)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (label: label, body: body)
    }

    /// Reconstructs a persisted comment's chip-display fields (`kindTag`,
    /// `label`, `body`) from its full stored block —
    /// `ComposerComment.serializedText`, i.e. exactly what
    /// `PendingComment.serializedBlock` produced when it was staged. Used to
    /// restore a pending-comment chip after an app relaunch (`.restored`),
    /// once only the flat text survives. Splits off the opening
    /// `[[comment:<tag>]]` / closing `[[/comment]]` lines the same way the
    /// sent-bubble parser does (`Flow42ChatView`'s attachment scanner), then
    /// delegates to `reconstruct`. Falls back to a generic "Comment" label
    /// with the raw text as the body when the block doesn't carry that
    /// wrapper at all (e.g. a `.recording` block, which uses its own
    /// `[[recording:<dir>]]` convention and was never eligible for this path).
    public static func decodeStaged(_ fullBlock: String) -> (kindTag: String, label: String, body: String) {
        var lines = fullBlock.components(separatedBy: "\n")
        guard let first = lines.first,
              let decoded = decodeOpen(first.trimmingCharacters(in: .whitespaces))
        else {
            return (kindTag: "widget", label: "Comment", body: fullBlock)
        }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == closeMarker {
            lines.removeLast()
        }
        if let legacyLabel = decoded.legacyLabel {
            return (kindTag: decoded.kindTag, label: legacyLabel, body: decoded.legacyBody ?? "")
        }
        let reconstructed = reconstruct(block: lines)
        return (kindTag: decoded.kindTag, label: reconstructed.label, body: reconstructed.body)
    }
}

/// Persistence hook for a `PendingCommentsStore` bound to a real session
/// (task42-plugin-conversion, s5). Flow42Core's session-aware convenience
/// init (`Sources/Flow42Core/Chat/PendingCommentsStore.swift`) wires this to
/// `ComposerDraftHandle` so comments survive tab switches, panel close, and
/// app restart; a store constructed with the bare `init()` (a plugin
/// widget's own instance, or the environment-key default) has no
/// persistence — appends/removes/clears stay in-memory only, the same
/// graceful degrade the rest of this store already uses.
@MainActor
public protocol PendingCommentsPersisting: AnyObject {
    func commentAdded(id: UUID, serializedText: String)
    func commentRemoved(id: UUID)
    func commentsCleared()
}

/// Shared, observable queue of pending comments for a single
/// session. Injected via `.environmentObject(...)` on
/// `SessionDetailPanel` so every widget and the chat composer talk
/// to the same instance.
@MainActor
public final class PendingCommentsStore: ObservableObject {

    @Published public var comments: [PendingComment] = []

    /// The bound session's persistence hook, or nil when this store is a
    /// placeholder (the `PendingCommentsKey` environment default, or a
    /// not-yet-wired coordinator) or a plugin widget's own unbound instance
    /// — matches the app's "unbound = silently no-op" posture rather than
    /// crashing. Settable so Flow42Core's session-aware convenience init can
    /// wire it without Work42UI needing to know `ChatSession` exists.
    public var persistence: (any PendingCommentsPersisting)?

    public init() {}

    /// Animated centrally (not left to each call site) so every caller —
    /// widget services, the composer, the accessory — gets the same smooth
    /// grow-in for free; `PendingCommentCard`'s `.transition()` (applied
    /// where it's rendered — ComposerAccessory.swift, PendingCommentsStrip
    /// .swift) supplies the actual visual (scale + fade), this just makes
    /// sure a real animation transaction is ambient when the array mutates.
    /// bug/pill-push-to-talk dogfooding: "the animation... looks a bit
    /// forced... it should increase in size... smooth... not abruptly."
    ///
    /// Persists via `persistence` (when bound) as `comment.serializedBlock`
    /// — the same text `serializedForPrompt()` would send — so the comment
    /// survives tab switches, panel close, and app restart (AC2).
    public func append(_ comment: PendingComment) {
        withAnimation(.spring(response: 0.46, dampingFraction: 0.72)) {
            comments.append(comment)
        }
        persistence?.commentAdded(id: comment.id, serializedText: comment.serializedBlock)
    }

    public func remove(id: UUID) {
        withAnimation(.spring(response: 0.46, dampingFraction: 0.72)) {
            comments.removeAll { $0.id == id }
        }
        persistence?.commentRemoved(id: id)
    }

    public func update(id: UUID, body: String) {
        guard let idx = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[idx].body = body
    }

    /// Fill in the diff anchor (`line` + `change`) on a `.prWebView` comment
    /// after the asynchronous `UnifiedDiffLocator` resolve completes (AC7 —
    /// cozy-nimbus). The comment is appended immediately with `line: nil,
    /// change: nil` so the UI is responsive; this back-fills the precise anchor
    /// once `gh pr diff` + the locator return. `.prWebView`'s `Source` fields
    /// are `let`, so we rebuild the case (preserving `prUrl` / `excerpt` /
    /// `filePath`) rather than mutating in place. No-op for a missing id or a
    /// non-`.prWebView` source.
    /// Back-fill the diff anchor resolved from the PR patch (AC7). The patch
    /// is authoritative for ALL THREE of `filePath` / `line` / `change` — the
    /// DOM `data-path` hint is often nil on GitHub's React diff, so we take the
    /// resolved `filePath` here (when non-nil) rather than keeping the DOM
    /// value, which is how the comment finally gets its file·line·side anchor.
    public func updateAnchor(id: UUID, filePath: String?, line: Int?, change: PRChangeKind?) {
        guard let idx = comments.firstIndex(where: { $0.id == id }) else { return }
        guard case let .prWebView(prUrl, excerpt, domFilePath, _, _) = comments[idx].source else { return }
        let old = comments[idx]
        comments[idx] = PendingComment(
            id: old.id,
            source: .prWebView(
                prUrl: prUrl,
                excerpt: excerpt,
                // Prefer the patch-resolved path; fall back to the DOM hint.
                filePath: filePath ?? domFilePath,
                line: line,
                change: change
            ),
            startLine: old.startLine,
            endLine: old.endLine,
            excerpt: old.excerpt,
            body: old.body
        )
    }

    public func clear() {
        comments.removeAll()
        persistence?.commentsCleared()
    }

    /// Header for the question section (AC6 — cozy-nimbus). `.prWebView`
    /// comments are *questions about someone else's PR*, not feedback on the
    /// user's own work, so they get their own section + framing.
    public static let questionsHeader = "Have a few questions regarding this PR:"

    /// Header for the browser highlight section (AC4 — lanky-pine).
    /// `.browserHighlight` comments are page-element references the user is
    /// pointing at — framed as "I want to show you something", not feedback.
    public static let browserHighlightHeader = "The user is pointing at the following elements in the browser:"

    /// Header for the screen-highlight section (gleeful-glacier AC9, AC10).
    /// `.screenHighlight` comments are Cmd-Shift-A region captures routed to
    /// the comment box — framed as screen captures the user wants to discuss.
    public static let screenHighlightHeader = "The user captured the following screen region(s):"

    public static let recordingsHeader = "The user recorded the following demonstration(s) — review the steps/video to see what they did:"

    /// Build the prefix the chat composer prepends to the outgoing prompt.
    /// Returns nil when the queue is empty so the composer can skip the join.
    ///
    /// Comments are split by kind (AC6): `.prWebView` selections serialize
    /// under their own `"Have a few questions regarding this PR:"` section,
    /// `.browserHighlight` selections serialize under their own
    /// `"The user is pointing at the following elements in the browser:"`
    /// section (placed before feedback so the agent sees the reference first),
    /// while `.spec` / `.file` / `.diff` / `.widget` comments serialize as
    /// bare blocks with NO section header — every block already names its own
    /// source ("On Foo.swift (lines …)", "From the 'github' widget (…)"), so
    /// a "Some feedback on your work:" banner was pure noise. When a session
    /// holds several kinds, sections appear questions-first. A section is
    /// omitted entirely when it has no comments.
    public func serializedForPrompt() -> String? {
        guard !comments.isEmpty else { return nil }

        var questions: [PendingComment] = []
        var highlights: [PendingComment] = []
        var screenHighlights: [PendingComment] = []
        var recordings: [PendingComment] = []
        var feedback: [PendingComment] = []
        for comment in comments {
            // Keyed off `kindTag` rather than pattern-matching `source`
            // directly so a `.restored` comment (whose original structured
            // `Source` didn't survive the persist/reload round trip) still
            // lands in the section its ORIGINAL kind belongs to — the tag
            // itself is reconstructed from the persisted marker regardless.
            switch comment.kindTag {
            case "prWebView": questions.append(comment)
            case "browserHighlight": highlights.append(comment)
            case "screenHighlight": screenHighlights.append(comment)
            case "recording": recordings.append(comment)
            default: feedback.append(comment)
            }
        }

        var sections: [String] = []
        if !questions.isEmpty {
            let blocks = questions.map(\.serializedBlock).joined(separator: "\n\n")
            sections.append("\(Self.questionsHeader)\n\n\(blocks)")
        }
        if !highlights.isEmpty {
            let blocks = highlights.map(\.serializedBlock).joined(separator: "\n\n")
            sections.append("\(Self.browserHighlightHeader)\n\n\(blocks)")
        }
        if !screenHighlights.isEmpty {
            let blocks = screenHighlights.map(\.serializedBlock).joined(separator: "\n\n")
            sections.append("\(Self.screenHighlightHeader)\n\n\(blocks)")
        }
        if !recordings.isEmpty {
            let blocks = recordings.map(\.serializedBlock).joined(separator: "\n\n")
            sections.append("\(Self.recordingsHeader)\n\n\(blocks)")
        }
        if !feedback.isEmpty {
            // No section banner: each block is self-describing.
            sections.append(feedback.map(\.serializedBlock).joined(separator: "\n\n"))
        }
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }
}

// MARK: - SwiftUI Environment Key

/// Environment key that provides a non-crashing fallback for
/// `PendingCommentsStore`. Widgets reading `@Environment(\.pendingComments)`
/// receive a shared empty store when no ancestor injects one via
/// `.environment(\.pendingComments, store)`, so the `+ Widget` engine can
/// mount any comment-consumer on any host without fatal-erroring.
///
/// Hosts that own a real per-session store inject it via BOTH
/// `.environmentObject(store)` (kept for observer propagation) AND
/// `.environment(\.pendingComments, store)` so that consumers reading
/// `@Environment(\.pendingComments)` see the live session store.
/// When neither injection is present the default — a fresh empty
/// `PendingCommentsStore` — is used instead and comment appends are silently
/// discarded (acceptable degrade; the regression guard prevents a crash).
public struct PendingCommentsKey: EnvironmentKey {
    public static let defaultValue = PendingCommentsStore()
}

extension EnvironmentValues {
    /// The session-scoped pending-comments store. Widgets MUST read this via
    /// `@Environment(\.pendingComments)` rather than
    /// `@EnvironmentObject var pendingComments: PendingCommentsStore` so that
    /// a missing injection degrades gracefully to an empty store rather than
    /// fatal-erroring (AC4 — janks-and-random-crashes regression guard).
    public var pendingComments: PendingCommentsStore {
        get { self[PendingCommentsKey.self] }
        set { self[PendingCommentsKey.self] = newValue }
    }
}
