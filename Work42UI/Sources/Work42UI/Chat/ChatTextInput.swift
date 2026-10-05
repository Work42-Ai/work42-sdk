// ChatTextInput.swift - Multi-line chat composer text input.
//
// Wraps `NSTextView` in `NSScrollView` so the field behaves like a
// real macOS text editor instead of a single-line SwiftUI TextField
// shoehorned into multi-line. The wrapping is necessary because the
// SwiftUI `TextField(axis: .vertical)` path:
//
//   - Doesn't reliably re-wrap when the column resizes (text stays
//     glued to the original width and only the typed `\n` triggers
//     a new line).
//   - Silently drops standard editor key bindings (CMD+Shift+A,
//     CMD+Option+arrow word motion, ⌃A/⌃E line motion) because the
//     `.onKeyPress` and `.onSubmit` handlers we attach short-circuit
//     the responder chain.
//   - Has no built-in min/max line behavior — `lineLimit` clamps
//     the visible height but doesn't introduce internal scrolling
//     when content exceeds the cap.
//
// Behavior of this component:
//
//   - Full native editor: CMD+A select all, CMD+Z/CMD+Shift+Z
//     undo/redo, CMD+arrow line nav, Option+arrow word nav, full
//     macOS text-input bindings.
//   - Word wraps to the field's current width and re-wraps on
//     resize.
//   - Sizes by content: starts at `minLines` (default 1), grows
//     line-by-line up to `maxLines` (default 10), then scrolls
//     internally — no overflow into the parent, no truncation.
//   - Return submits. Shift+Return inserts a newline.
//   - Plain text only. Smart-quote / dash / replacement substitutions
//     are off so pasted code doesn't get silently mangled.
//   - Auto-focuses on first window appearance — the chat composer
//     wants the cursor on arrival.
//   - Placeholder rendered as a SwiftUI overlay behind a transparent
//     text view so the field doesn't look empty when there's no
//     content.
//   - Optional `isFocused` binding so the parent can draw a focus
//     ring around the surrounding surface.

import AppKit
import SwiftUI

public struct ChatTextInput: View {

    @Binding var text: String
    public let placeholder: String
    public let minLines: Int
    public let maxLines: Int
    public let fontSize: CGFloat
    @Binding var isFocused: Bool
    /// Called when the user presses Cmd-V and the general pasteboard
    /// contains an image (TIFF, PNG, PDF, …) with NO backing file — a
    /// true in-memory clipboard image (e.g. copied out of a browser or
    /// captured via a raw-image-to-clipboard screenshot tool). When
    /// `nil`, image paste falls through to the normal NSTextView paste
    /// behaviour (usually a no-op for image-only pasteboards on a
    /// plain-text field).
    public var onPasteImage: ((NSImage) -> Void)?
    /// Called when the user presses Cmd-V and the pasteboard carries a
    /// one or more `public.file-url` items pointing at image files —
    /// e.g. Cmd-C on one or several screenshot files in Finder. Checked
    /// BEFORE `onPasteImage`: a Finder file-copy also advertises a
    /// `com.apple.icns`/generic document-icon representation that LOOKS
    /// like valid image data to a naive pasteboard read but is just the
    /// Finder icon, not the real pixels — so real file URLs always win
    /// when present.
    public var onPasteFiles: (([URL]) -> Void)?
    public let onSubmit: () -> Void

    public init(
        text: Binding<String>,
        placeholder: String = "",
        minLines: Int = 1,
        maxLines: Int = 10,
        fontSize: CGFloat = 16,
        isFocused: Binding<Bool> = .constant(false),
        onPasteImage: ((NSImage) -> Void)? = nil,
        onPasteFiles: (([URL]) -> Void)? = nil,
        onSubmit: @escaping () -> Void
    ) {
        self._text = text
        self.placeholder = placeholder
        self.minLines = minLines
        self.maxLines = maxLines
        self.fontSize = fontSize
        self._isFocused = isFocused
        self.onPasteImage = onPasteImage
        self.onPasteFiles = onPasteFiles
        self.onSubmit = onSubmit
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // Placeholder drawn beneath the (transparent) text view.
            // Only present while there's no content — it disappears
            // the moment the user types a character so we don't have
            // to compete with the cursor's blink.
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            ChatTextInputCore(
                text: $text,
                minLines: minLines,
                maxLines: maxLines,
                fontSize: fontSize,
                isFocused: $isFocused,
                onPasteImage: onPasteImage,
                onPasteFiles: onPasteFiles,
                onSubmit: onSubmit
            )
        }
    }
}

// MARK: - AppKit core

private struct ChatTextInputCore: NSViewRepresentable {

    @Binding var text: String
    let minLines: Int
    let maxLines: Int
    let fontSize: CGFloat
    @Binding var isFocused: Bool
    var onPasteImage: ((NSImage) -> Void)?
    var onPasteFiles: (([URL]) -> Void)?
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ChatScrollView {
        let font = NSFont.systemFont(ofSize: fontSize)
        let textView = SubmitInterceptingTextView()
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindBar = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onPasteImage = onPasteImage
        textView.onPasteFiles = onPasteFiles
        textView.onFocusChange = { focused in
            // Defer the binding mutation off the AppKit becomeFirst-
            // Responder stack so we don't re-enter SwiftUI mid-layout.
            DispatchQueue.main.async { isFocused = focused }
        }
        textView.textContainerInset = .zero
        if let container = textView.textContainer {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
            container.heightTracksTextView = false
        }
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scrollView = ChatScrollView(
            minLines: minLines, maxLines: maxLines, font: font
        )
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: ChatScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitInterceptingTextView else { return }
        let font = NSFont.systemFont(ofSize: fontSize)
        if textView.font?.pointSize != font.pointSize {
            textView.font = font
            scrollView.font = font
        }
        if textView.string != text {
            textView.string = text
        }
        textView.onSubmit = onSubmit
        textView.onPasteImage = onPasteImage
        textView.onPasteFiles = onPasteFiles
        scrollView.invalidateIntrinsicContentSize()
    }

    /// SwiftUI does NOT automatically respect an NSView's
    /// `intrinsicContentSize` — without this hook the wrapper fills
    /// whatever vertical space the parent VStack offers (which inside
    /// the chat column is "all of it"). Implementing `sizeThatFits`
    /// lets us answer "for the proposed width, how tall do I want to
    /// be?" with a width-aware calculation that clamps between
    /// `minLines` and `maxLines`.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ChatScrollView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width.isFinite, width > 0 else { return nil }
        let height = ChatScrollView.measureHeight(
            text: text,
            font: NSFont.systemFont(ofSize: fontSize),
            width: width,
            minLines: minLines,
            maxLines: maxLines
        )
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextInputCore

        init(parent: ChatTextInputCore) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            (textView.enclosingScrollView as? ChatScrollView)?
                .invalidateIntrinsicContentSize()
        }
    }
}

// MARK: - Return-aware text view
//
// Subclass overrides `keyDown` to translate plain Return into a
// submit and Shift+Return into a literal newline. Every OTHER key —
// CMD+A, CMD+Z, arrow keys with every modifier combo — falls
// through to `super.keyDown(with:)` and reaches the responder chain
// so all native editor commands keep working.

@MainActor
private final class SubmitInterceptingTextView: NSTextView {

    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    /// Called when the user presses Cmd-V and the pasteboard holds an
    /// image. When `nil`, image paste falls through to `super.paste`.
    var onPasteImage: ((NSImage) -> Void)?
    /// Called when the pasteboard carries one or more real file URLs to
    /// images (e.g. Cmd-C on one or several files in Finder). Checked
    /// before `onPasteImage`.
    var onPasteFiles: (([URL]) -> Void)?
    private var hasAutoFocused = false

    /// Intercepts Cmd-V. Priority, mirroring the composer's drag-drop
    /// handler:
    ///   1. One or more real file URLs on the pasteboard (e.g. Cmd-C on
    ///      one or several files in Finder) — attach each by its real
    ///      path directly, same as a dropped file. A Finder file-copy
    ///      ALSO advertises a `com.apple.icns`/generic-document-icon
    ///      representation that a naive image-data read would mistake
    ///      for the real picture, so the file-URL check must run first
    ///      and win.
    ///   2. Genuine in-memory image bytes with no backing file.
    /// All other paste actions (plain text, etc.) pass through to super.
    override func paste(_ sender: Any?) {
        if let filesHandler = onPasteFiles {
            let urls = Self.pasteboardImageFileURLs(from: .general)
            if !urls.isEmpty {
                filesHandler(urls)
                return
            }
        }
        if let handler = onPasteImage,
           let image = Self.pasteboardImage(from: .general) {
            handler(image)
            return
        }
        super.paste(sender)
    }

    /// Reads every `public.file-url` item off `pasteboard` (a Finder
    /// multi-file copy puts one pasteboard item per file — a
    /// single-item read like `NSURL(from:)` only ever sees the first
    /// one) and returns the ones pointing at an image-like extension
    /// (mirrors `ChatAttachment.isImage`'s extension check) — a
    /// non-image file paste should fall through to normal
    /// text/whatever-else handling, not silently attach an unrelated
    /// file.
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    private static func pasteboardImageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: nil
        ) as? [URL] else { return [] }
        return urls.filter { url in
            url.isFileURL && imageExtensions.contains(url.pathExtension.lowercased())
        }
    }

    /// Reads an image off `pasteboard`, preferring the raw bitmap bytes
    /// for the highest-fidelity image type over AppKit's class-based
    /// `readObjects(forClasses: [NSImage.self])`.
    ///
    /// `readObjects(forClasses: [NSImage.self])` asks each pasteboard
    /// item to synthesize an `NSImage` on its own, and for some item
    /// shapes — notably macOS screenshot clips, which place several
    /// representations (TIFF/PNG plus a `public.file-url`) on the same
    /// item — it can resolve to a generic file-type/icon representation
    /// instead of the real captured pixels. The bug is invisible
    /// downstream: `ChatAttachment.capture(image:)` faithfully
    /// re-encodes whatever bitmap the `NSImage` carries as a
    /// structurally valid PNG, so the corruption only shows up as wrong
    /// pixel content in the final attachment.
    ///
    /// Reading `.tiff`/`.png` data directly via `pasteboard.data(forType:)`
    /// and constructing the `NSImage` from those bytes ourselves bypasses
    /// that per-item synthesis entirely, so we always get the actual
    /// bitmap the source app put on the clipboard. The class-based read
    /// is kept as a last-resort fallback for pasteboard sources that
    /// don't expose raw TIFF/PNG data (e.g. some third-party apps that
    /// only vend a PDF or a custom UTI NSImage already knows how to
    /// decode).
    private static func pasteboardImage(from pasteboard: NSPasteboard) -> NSImage? {
        let rawImageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        for type in rawImageTypes {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
           let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            return image
        }
        return nil
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.specialKey == .carriageReturn
            || event.specialKey == .enter
            || event.keyCode == 36
            || event.keyCode == 76
        if isReturn {
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)   // Shift+Return → newline
            } else {
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !hasAutoFocused, window != nil else { return }
        hasAutoFocused = true
        // Defer so the AppKit responder chain is fully assembled
        // before we ask to become first responder. Without the
        // defer, the makeFirstResponder call no-ops on first mount.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }
}

// MARK: - Self-sizing scroll view
//
// Holds the line bounds and the current font so the static
// measurement helper can compute "for this text at this width, how
// tall am I" without mutating any live AppKit state. The actual
// height is returned via `ChatTextInputCore.sizeThatFits` — SwiftUI
// doesn't honour `intrinsicContentSize` for representables, so we
// answer the size question with the explicit sizing hook instead.

@MainActor
private final class ChatScrollView: NSScrollView {

    let minLines: Int
    let maxLines: Int
    var font: NSFont

    init(minLines: Int, maxLines: Int, font: NSFont) {
        self.minLines = minLines
        self.maxLines = maxLines
        self.font = font
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Pure measurement: lays the text out in a throwaway layout
    /// manager at the proposed width, returns the clamped height.
    /// No mutation of the live text view / container.
    ///
    /// The trailing-space trick handles "user pressed Return at the
    /// end" — `boundingRect` collapses the empty trailing line, so
    /// we append a space to force the layout to count the row.
    static func measureHeight(
        text: String,
        font: NSFont,
        width: CGFloat,
        minLines: Int,
        maxLines: Int
    ) -> CGFloat {
        let lineHeight = ceil(font.boundingRectForFont.height)
        let minHeight  = lineHeight * CGFloat(minLines)
        let maxHeight  = lineHeight * CGFloat(maxLines)

        if text.isEmpty { return minHeight }

        // Fast path for big pastes. The scroll view handles overflow
        // past `maxLines`, so we never need an exact height when the
        // text is clearly larger than the cap — laying out a multi-KB
        // string through Core Text on every relayout was a dominant
        // cost of the "paste long message freezes the composer" bug.
        //
        // Two cheap upper-bound signals. Either alone is sufficient
        // to return `maxHeight`; we run the precise layout below only
        // for short strings that genuinely sit between min and max.
        //
        //   1. Hard newline count >= maxLines  ⇒ already at or past
        //      the cap, no matter how the text wraps.
        //   2. UTF-8 byte count exceeds a generous chars-per-row
        //      estimate × (maxLines + 1). We assume a 3-point floor
        //      per glyph at any size we render — narrow even for
        //      condensed system fonts — so anything past this length
        //      will definitely wrap past `maxLines`.
        //
        // We exit the newline scan early once we cross the threshold
        // so a huge multi-line paste doesn't pay an O(n) pass either.
        var newlineCount = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                newlineCount += 1
                if newlineCount >= maxLines { return maxHeight }
            }
        }
        if width > 0 {
            let charsPerRowFloor = max(1, Int(width / 3))
            if text.utf8.count > charsPerRowFloor * (maxLines + 1) {
                return maxHeight
            }
        }

        let measure = text.hasSuffix("\n") ? text + " " : text
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let bounds = NSAttributedString(string: measure, attributes: attrs)
            .boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        let contentHeight = ceil(bounds.height)
        return max(minHeight, min(maxHeight, contentHeight))
    }
}
