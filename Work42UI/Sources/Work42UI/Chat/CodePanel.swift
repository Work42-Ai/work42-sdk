// CodePanel.swift - The code card of the design system (WOR-516).
//
// One molecule for every card that shows code or terminal text under a small header: the chat's fenced code block, the
// detail panels of an activity card and the inline terminal. They used to be three hand-built copies with their own
// paddings, so they drifted apart. The panel owns everything the callers used to choose for themselves: the header
// (a mono title, optional meta text, a Copy button and the secondary actions), the padding of header and content, the
// surface, and how its buttons look (a glass capsule or circle with a subtle tint of the system accent, so they stand
// out on the neutral surface without turning it into a coloured one).

import AppKit
import SwiftUI

/// Where a panel sits, which decides its edge.
public enum CodePanelStyle: Sendable {
    /// On the transcript itself, like a fenced code block: a hairline border.
    case standalone
    /// Inside another card (an activity card): no border, so one surface is never stacked on another.
    case nested
}

public struct CodePanel<Actions: View, Content: View>: View {
    private let title: String
    private let titleTruncation: Text.TruncationMode
    private let meta: String?
    private let metaColor: Color
    private let copyText: String?
    private let copyHelp: String
    private let style: CodePanelStyle
    private let edgeToEdge: Bool
    private let actions: Actions
    private let content: Content

    /// - Parameters:
    ///   - title: the header's mono label: a language, a path or `$ command`.
    ///   - meta: small text before the buttons: "+3 −1", "exit 1".
    ///   - copyText: what Copy puts on the pasteboard; nil leaves the Copy button out.
    ///   - edgeToEdge: the content is not inset by the panel: it brings its own `codePanelPadding` inside a scroll view,
    ///     so what scrolls reaches the panel's edges and its scroller sits on the edge (WOR-517).
    ///   - actions: secondary actions after Copy, each a `CodePanelAction`.
    public init(
        title: String,
        titleTruncation: Text.TruncationMode = .tail,
        meta: String? = nil,
        metaColor: Color = .secondary,
        copyText: String? = nil,
        copyHelp: String = "Copy",
        style: CodePanelStyle = .standalone,
        edgeToEdge: Bool = false,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.titleTruncation = titleTruncation
        self.meta = meta
        self.metaColor = metaColor
        self.copyText = copyText
        self.copyHelp = copyHelp
        self.style = style
        self.edgeToEdge = edgeToEdge
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            // Scrolling content (the inline terminal) insets itself, so its scroller sits on the panel's edge.
            if edgeToEdge {
                content
            } else {
                content.padding(ChatMetrics.codePanelPadding)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous))
        .background(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay {
            if style == .standalone {
                RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
    }

    private var header: some View {
        HStack(spacing: DT.s8) {
            Text(title)
                .font(.system(size: DT.f12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(titleTruncation)
                .textSelection(.enabled)
            Spacer(minLength: DT.s8)
            if let meta, !meta.isEmpty {
                ChangeCountsText(meta, color: metaColor)
                    .font(.system(size: DT.f12, design: .monospaced))
                    .lineLimit(1)
            }
            if let copyText { CodePanelCopyButton(text: copyText, help: copyHelp) }
            actions
        }
        // As tall as its tallest button, so the panel is the same with and without the secondary actions.
        .frame(minHeight: ChatMetrics.codePanelHeaderHeight)
        .padding(.horizontal, ChatMetrics.codePanelPadding)
        .padding(.top, ChatMetrics.codePanelHeaderTop)
    }
}

extension CodePanel where Actions == EmptyView {
    public init(
        title: String,
        titleTruncation: Text.TruncationMode = .tail,
        meta: String? = nil,
        metaColor: Color = .secondary,
        copyText: String? = nil,
        copyHelp: String = "Copy",
        style: CodePanelStyle = .standalone,
        edgeToEdge: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, titleTruncation: titleTruncation, meta: meta, metaColor: metaColor, copyText: copyText,
            copyHelp: copyHelp, style: style, edgeToEdge: edgeToEdge, actions: { EmptyView() }, content: content
        )
    }
}

// MARK: - Buttons

/// A secondary action of a code panel ("Run", "Open in Files", "Open terminal"): one capsule, styled by the panel.
public struct CodePanelAction: View {
    private let title: String
    private let systemImage: String
    private let help: String?
    private let action: () -> Void

    public init(_ title: String, systemImage: String, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: DT.f12, weight: .semibold))
        }
        .modifier(CodePanelButtonLook(shape: .capsule))
        .help(help ?? title)
        .accessibilityLabel(help ?? title)
    }
}

/// Copy, as a circle with a checkmark for a moment after it is pressed.
struct CodePanelCopyButton: View {
    let text: String
    let help: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: DT.f13, weight: .medium))
        }
        .modifier(CodePanelButtonLook(shape: .circle))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// How every button of a code panel looks: the same glass capsule as "+ Add Widget" (a light fill in light mode, a dark
/// one in dark mode) at the large control size, with the system accent as its label colour and no tint on the fill.
/// The panel's buttons are defined here and nowhere else (WOR-517).
struct CodePanelButtonLook: ViewModifier {
    enum Shape { case capsule, circle }
    let shape: Shape

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .controlSize(.extraLarge)
                .buttonStyle(.glass)
                .buttonBorderShape(shape == .circle ? .circle : .capsule)
                .foregroundStyle(DT.systemAccent)
        } else {
            content
                .controlSize(.large)
                .buttonStyle(.bordered)
                .buttonBorderShape(shape == .circle ? .circle : .capsule)
                .foregroundStyle(DT.systemAccent)
        }
    }
}

/// Small header text where `+N` is green and `−N` red, the rest in `color`: "+16 −53", "exit 1", "3 matches".
public struct ChangeCountsText: View {
    private let text: String
    private let color: Color

    public init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        words.enumerated().reduce(Text("")) { result, item in
            let (index, word) = item
            let tint: Color = Self.isCount(word, sign: "+") ? DT.green : Self.isCount(word, sign: "\u{2212}") || Self.isCount(word, sign: "-") ? DT.red : color
            return result + Text((index == 0 ? "" : " ") + word).foregroundColor(tint)
        }
    }

    /// `+16`, `−53`: the sign followed by digits only.
    public static func isCount(_ word: String, sign: String) -> Bool {
        word.hasPrefix(sign) && word.count > sign.count && word.dropFirst(sign.count).allSatisfy(\.isNumber)
    }
}
