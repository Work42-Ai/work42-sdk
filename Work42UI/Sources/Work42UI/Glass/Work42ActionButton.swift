// Work42ActionButton.swift — the SDK-owned action-area button primitive.
//
// Widget intents describe content and colour; this view owns the visual family:
// control size, border shape, and the macOS-version fallback. Keeping those
// decisions here prevents built-in and plugin widgets from drifting to subtly
// different heights while preserving glass, solid, and bordered treatments.

import AppKit
import SwiftUI

/// The two supported action-area label shapes. Callers supply the label's
/// content, but cannot alter the control's size or border geometry.
public enum Work42ActionButtonLabelStyle: Sendable {
    case labeled
    case iconOnly
}

/// One selectable entry in a ``Work42ActionButtonTreatment/menu(options:onSelect:)``
/// control.
public struct Work42ActionMenuOption: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String?
    public let isSelected: Bool
    public let isEnabled: Bool

    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isEnabled = isEnabled
    }
}

/// The closed set of visual treatments available to action-area controls.
///
/// Deliberately absent: height, control size, padding, material, and border
/// shape. Those belong to ``Work42ActionButton`` so SDK clients cannot create
/// an off-family action-area button.
public enum Work42ActionButtonTreatment {
    case glass(tint: Color)
    case solid(background: Color, foreground: Color)
    case bordered
    case menu(
        options: [Work42ActionMenuOption],
        onSelect: @MainActor @Sendable (String) -> Void
    )
}

/// The single SDK rendering primitive for widget-declared action-area buttons.
///
/// All treatments share the same platform control size: extra-large on macOS
/// 26 and the uniformly large compatibility treatment on older macOS releases.
/// Callers choose only label content, label shape, colour treatment, and action.
public struct Work42ActionButton<Label: View>: View {
    private let labelStyle: Work42ActionButtonLabelStyle
    private let treatment: Work42ActionButtonTreatment
    private let action: @MainActor () -> Void
    private let label: Label

    public init(
        labelStyle: Work42ActionButtonLabelStyle = .labeled,
        treatment: Work42ActionButtonTreatment,
        action: @escaping @MainActor () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.labelStyle = labelStyle
        self.treatment = treatment
        self.action = action
        self.label = label()
    }

    public var body: some View {
        switch treatment {
        case .glass(let tint):
            glassButton(tint: tint)
        case .solid(let background, let foreground):
            solidButton(background: background, foreground: foreground)
        case .bordered:
            borderedButton
        case .menu(let options, let onSelect):
            menuButton(options: options, onSelect: onSelect)
        }
    }

    @ViewBuilder
    private func glassButton(tint: Color) -> some View {
        let button = Button(action: action) { label }
        switch labelStyle {
        case .labeled:
            button.glassProminentCapsule(tint: tint)
        case .iconOnly:
            button
                .foregroundStyle(tint)
                .glassIconButton()
        }
    }

    @ViewBuilder
    private func solidButton(background: Color, foreground: Color) -> some View {
        let button = Button(action: action) { label }
        if #available(macOS 26.0, *) {
            button
                .controlSize(.extraLarge)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(labelStyle == .iconOnly ? .circle : .capsule)
                .tint(background)
                .foregroundStyle(foreground)
        } else {
            button
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(labelStyle == .iconOnly ? .circle : .capsule)
                .tint(background)
                .foregroundStyle(foreground)
        }
    }

    @ViewBuilder
    private var borderedButton: some View {
        let button = Button(action: action) { label }
        if #available(macOS 26.0, *) {
            button
                .controlSize(.extraLarge)
                .buttonStyle(.bordered)
                .buttonBorderShape(labelStyle == .iconOnly ? .circle : .capsule)
        } else {
            button
                .controlSize(.large)
                .buttonStyle(.bordered)
                .buttonBorderShape(labelStyle == .iconOnly ? .circle : .capsule)
        }
    }

    /// A bordered capsule that opens a native `NSMenu` under the pointer. Not a SwiftUI `Menu`: the action area
    /// redraws while it is clicked (focus and scope changes), and a redraw reset the SwiftUI menu before it could
    /// open; an AppKit menu runs its own tracking loop, independent of SwiftUI updates (WOR-420).
    @ViewBuilder
    private func menuButton(
        options: [Work42ActionMenuOption],
        onSelect: @escaping @MainActor @Sendable (String) -> Void
    ) -> some View {
        let button = Button {
            Work42ActionMenuPresenter.present(options: options, onSelect: onSelect)
        } label: {
            HStack(spacing: 6) {
                label
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }

        if #available(macOS 26.0, *) {
            button
                .controlSize(.extraLarge)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        } else {
            button
                .controlSize(.large)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }

}

// MARK: - Native menu

/// Shows an action-area menu as an `NSMenu` at the pointer (the click that opened it), checkmarking the
/// selected option and calling `onSelect` with the picked option's id.
@MainActor
public enum Work42ActionMenuPresenter {
    public static func present(
        options: [Work42ActionMenuOption],
        onSelect: @escaping @MainActor @Sendable (String) -> Void
    ) {
        guard !options.isEmpty else { return }
        let menu = NSMenu()
        let target = MenuTarget(onSelect: onSelect)
        for option in options {
            let item = NSMenuItem(title: option.title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = option.id
            item.state = option.isSelected ? .on : .off
            item.isEnabled = option.isEnabled
            if let symbol = option.systemImage {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        // The target is only weakly held by the items; keep it alive while the menu tracks.
        withExtendedLifetime(target) {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private final class MenuTarget: NSObject {
        let onSelect: @MainActor @Sendable (String) -> Void
        init(onSelect: @escaping @MainActor @Sendable (String) -> Void) { self.onSelect = onSelect }

        @objc func pick(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            MainActor.assumeIsolated { onSelect(id) }
        }
    }
}

// MARK: - Segmented group

/// Several action-area buttons sharing ONE glass capsule, split by hairline dividers: the shape of the title
/// bar's split controls. A widget's related actions (a date stepper's back / Today / next, its settings) read
/// as one control instead of a row of separate capsules. The capsule owns the material and the height (the
/// same as a ``Work42ActionButton``); each ``Work42ActionSegment`` inside is a plain button.
public struct Work42ActionButtonGroup<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ZStack {
            // The height comes from a real (hidden) action button of the same control size, so the group always
            // matches the extra-large capsules beside it, on every macOS release.
            Button(action: {}) { Text(" ") }
                .glassSubtleCapsule(tint: .clear)
                .frame(width: 1)
                .hidden()
                .accessibilityHidden(true)
            HStack(spacing: 0) { content }
                .padding(.horizontal, Work42ActionSegmentMetrics.inset)
                .frame(maxHeight: .infinity)
        }
        // The hidden reference is a glass button without the bordered capsule's outline; 1 pt each side
        // brings the group level with the bordered and glass capsules beside it.
        .padding(.vertical, 1)
        .fixedSize()
        .glassCapsuleSurface()
    }
}

/// One button inside a ``Work42ActionButtonGroup``: a circle for an icon, a capsule for text, highlighted on
/// hover and press like the title bar's grouped controls. Every segment after the first draws a divider first.
public struct Work42ActionSegment<Label: View>: View {
    private let showsDivider: Bool
    private let isIcon: Bool
    private let tint: Color?
    private let action: @MainActor () -> Void
    private let label: Label

    public init(
        showsDivider: Bool,
        isIcon: Bool,
        tint: Color? = nil,
        action: @escaping @MainActor () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.showsDivider = showsDivider
        self.isIcon = isIcon
        self.tint = tint
        self.action = action
        self.label = label()
    }

    public var body: some View {
        HStack(spacing: 0) {
            if showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 1, height: Work42ActionSegmentMetrics.dividerHeight)
                    .padding(.horizontal, 2)
            }
            Button(action: action) { label.fixedSize() }
                .buttonStyle(Work42ActionSegmentStyle(isIcon: isIcon))
                .foregroundStyle(tint ?? Color.primary)
        }
    }
}

/// Plain segment chrome: the highlight is a circle (icon) or capsule (text) inset from the group's edge.
private struct Work42ActionSegmentStyle: ButtonStyle {
    let isIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        SegmentChrome(label: configuration.label, isPressed: configuration.isPressed, isIcon: isIcon)
    }
}

/// The segment's highlight; a view so it can own its hover state.
private struct SegmentChrome<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let isIcon: Bool
    @State private var hovered = false

    var body: some View {
        let opacity = isPressed ? 0.14 : (hovered ? 0.08 : 0)
        Group {
            if isIcon {
                label
                    .frame(width: Work42ActionSegmentMetrics.iconWidth)
                    .frame(maxHeight: .infinity)
                    .background(
                        Circle().fill(Color.primary.opacity(opacity))
                            .frame(width: Work42ActionSegmentMetrics.iconWidth, height: Work42ActionSegmentMetrics.iconWidth)
                    )
                    .contentShape(Rectangle())
            } else {
                label
                    .padding(.horizontal, Work42ActionSegmentMetrics.textPadding)
                    .frame(maxHeight: .infinity)
                    .background(
                        Capsule().fill(Color.primary.opacity(opacity))
                            .padding(.vertical, Work42ActionSegmentMetrics.inset)
                    )
                    .contentShape(Capsule())
            }
        }
        .onHover { hovered = $0 }
    }
}

/// The measurements of a segmented action group.
public enum Work42ActionSegmentMetrics {
    /// Gap between the group's edge and a segment's highlight.
    public static let inset: CGFloat = 3
    public static let dividerHeight: CGFloat = 18
    /// Horizontal padding of a text segment inside its capsule highlight.
    public static let textPadding: CGFloat = 12
    /// Width of an icon segment, and the diameter of its circular highlight.
    public static let iconWidth: CGFloat = 32
}
