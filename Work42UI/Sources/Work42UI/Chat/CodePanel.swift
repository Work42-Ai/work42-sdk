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
    private let actions: Actions
    private let content: Content

    /// - Parameters:
    ///   - title: the header's mono label: a language, a path or `$ command`.
    ///   - meta: small text before the buttons: "+3 −1", "exit 1".
    ///   - copyText: what Copy puts on the pasteboard; nil leaves the Copy button out.
    ///   - actions: secondary actions after Copy, each a `CodePanelAction`.
    public init(
        title: String,
        titleTruncation: Text.TruncationMode = .tail,
        meta: String? = nil,
        metaColor: Color = .secondary,
        copyText: String? = nil,
        copyHelp: String = "Copy",
        style: CodePanelStyle = .standalone,
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
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content
                .padding(ChatMetrics.codePanelPadding)
        }
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
                Text(meta)
                    .font(.system(size: DT.f12, design: .monospaced))
                    .foregroundStyle(metaColor)
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
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, titleTruncation: titleTruncation, meta: meta, metaColor: metaColor, copyText: copyText,
            copyHelp: copyHelp, style: style, actions: { EmptyView() }, content: content
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

/// How every button of a code panel looks: glass at the regular control size, tinted with the system accent at a low
/// opacity, with the accent as its label colour. The panel's buttons are defined here and nowhere else.
struct CodePanelButtonLook: ViewModifier {
    enum Shape { case capsule, circle }
    let shape: Shape

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .controlSize(.regular)
                .buttonStyle(.glass)
                .buttonBorderShape(shape == .circle ? .circle : .capsule)
                .tint(DT.systemAccent.opacity(ChatMetrics.codePanelButtonTint))
                .foregroundStyle(DT.systemAccent)
        } else {
            content
                .controlSize(.regular)
                .buttonStyle(.bordered)
                .buttonBorderShape(shape == .circle ? .circle : .capsule)
                .tint(DT.systemAccent)
        }
    }
}
