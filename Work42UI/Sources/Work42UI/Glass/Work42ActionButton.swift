// Work42ActionButton.swift — the SDK-owned action-area button primitive.
//
// Widget intents describe content and colour; this view owns the visual family:
// control size, border shape, and the macOS-version fallback. Keeping those
// decisions here prevents built-in and plugin widgets from drifting to subtly
// different heights while preserving glass, solid, and bordered treatments.

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

    @ViewBuilder
    private func menuButton(
        options: [Work42ActionMenuOption],
        onSelect: @escaping @MainActor @Sendable (String) -> Void
    ) -> some View {
        let menu = Menu {
            menuItems(options: options, onSelect: onSelect)
        } label: {
            label
        }

        if #available(macOS 26.0, *) {
            menu
                .controlSize(.extraLarge)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        } else {
            menu
                .controlSize(.large)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }

    @ViewBuilder
    private func menuItems(
        options: [Work42ActionMenuOption],
        onSelect: @escaping @MainActor @Sendable (String) -> Void
    ) -> some View {
        ForEach(options) { option in
            Button {
                onSelect(option.id)
            } label: {
                if option.isSelected {
                    SwiftUI.Label(option.title, systemImage: "checkmark")
                } else if let systemImage = option.systemImage {
                    SwiftUI.Label(option.title, systemImage: systemImage)
                } else {
                    Text(option.title)
                }
            }
            .disabled(!option.isEnabled)
        }
    }
}
