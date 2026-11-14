// HeaderControls.swift — the controls a widget's header is made of, ready to use (SDK 2.14.0, ABI 16; WOR-773, AC48).
//
// A header is one or more rows, and inside a row a widget uses only these: the title block, a round button, a pill of segments, a
// segmented toggle. Each carries its own size, fill, hairline and glyph colour from `TileMetrics` and the design tokens, so a widget
// never writes a height or a colour of its own and every header, the app's and a plugin's, on the Mac and the iPad, lines up.
//
//   • `WidgetHeaderTitle`     the widget's name over an optional muted identifier (a path, a URL)
//   • `HeaderRoundButton`     one control that stands alone, such as Back: a circle of the control height
//   • `HeaderPill`            a capsule of `HeaderSegment`s (icon buttons, with a red/accent on-state and an optional label)
//   • `HeaderSegmentedToggle` a capsule of icon options, one selected (preview / source)

import SwiftUI

// MARK: - Title

/// A header's title: the widget's name over an optional muted identifier (a path, a URL), both one line. The name is 14 pt medium in
/// the primary colour, the subtitle 10 pt monospaced in the tertiary colour, truncating in the middle, 1 pt apart (a step up each on
/// a touch screen). `minWidth: 0` lets it truncate before it crowds the controls.
public struct WidgetHeaderTitle: View {
    private let name: String
    private let subtitle: String?

    public init(name: String, subtitle: String? = nil) {
        self.name = name
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.system(size: TileMetrics.titleSize, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: TileMetrics.subtitleSize, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        // The block is laid out at the control height: a name over a subtitle is a little taller than a control, and left to itself it
        // would make its header's row taller than every other header's. The text's own line space absorbs the difference.
        .frame(minWidth: 0, minHeight: TileMetrics.controlHeight, maxHeight: TileMetrics.controlHeight, alignment: .leading)
    }
}

// MARK: - Round button

/// A single control that stands alone in a header (Back): a circle exactly the control height, in the pill's fill, hairline and glyph
/// colour.
public struct HeaderRoundButton: View {
    private let systemImage: String
    private let label: String
    private let action: () -> Void

    /// `label` is what a screen reader says and what the tooltip shows.
    public init(systemImage: String, label: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    public var body: some View {
        let side = TileMetrics.controlHeight
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13 + (TileMetrics.isTouch ? 1 : 0), weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Circle().fill(DT.chipFill))
        .overlay(Circle().strokeBorder(DT.chipStroke, lineWidth: 1))
        .clipShape(Circle())
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - Pill of segments

/// One segment of a `HeaderPill`: an icon button.
public struct HeaderSegment: Identifiable {
    public let id: String
    public let systemImage: String
    /// What a screen reader says and the tooltip shows.
    public let label: String
    /// Whether the control is on (a recording running): the segment takes `onTint` and shows `onLabel` beside its icon.
    public let isOn: Bool
    /// Text shown beside the icon while on (the elapsed time of a recording).
    public let onLabel: String?
    public let isEnabled: Bool
    public let action: () -> Void

    public init(
        id: String, systemImage: String, label: String, isOn: Bool = false, onLabel: String? = nil, isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.systemImage = systemImage
        self.label = label
        self.isOn = isOn
        self.onLabel = onLabel
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// A capsule of segments: the tile control surface at the control height, a hairline between neighbours. A widget's actions use one
/// of these (or become segments of the tile's own pill); the hairlines and sizes are drawn here, never by the widget.
public struct HeaderPill: View {
    private let segments: [HeaderSegment]
    private let onTint: Color

    /// How many hairlines a pill of `count` segments draws.
    public static func dividerCount(for count: Int) -> Int { max(0, count - 1) }

    public init(_ segments: [HeaderSegment], onTint: Color = DT.red) {
        self.segments = segments
        self.onTint = onTint
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 { Rectangle().fill(DT.chipStroke).frame(width: 1, height: TileMetrics.controlHeight) }
                HeaderSegmentButton(segment, onTint: onTint)
            }
        }
        .frame(height: TileMetrics.controlHeight)
        .tileControlSurface()
    }
}

/// One `HeaderSegment` drawn as a button at the control height. `HeaderPill` draws its segments with it; a host that already owns a
/// pill (the tile's controls capsule) draws a widget's header actions with it too, so they look the same either way.
public struct HeaderSegmentButton: View {
    private let segment: HeaderSegment
    private let onTint: Color

    public init(_ segment: HeaderSegment, onTint: Color = DT.red) {
        self.segment = segment
        self.onTint = onTint
    }

    public var body: some View {
        Button(action: segment.action) {
            HStack(spacing: 4) {
                Image(systemName: segment.systemImage)
                    .font(.system(size: 13 + (TileMetrics.isTouch ? 1 : 0), weight: .semibold))
                if segment.isOn, let text = segment.onLabel {
                    Text(text).font(.system(size: 12 + (TileMetrics.isTouch ? 1 : 0), weight: .semibold)).monospacedDigit()
                }
            }
            .foregroundStyle(segment.isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
            .frame(minWidth: TileMetrics.controlButtonWidth, minHeight: TileMetrics.controlHeight)
            .padding(.horizontal, segment.isOn && segment.onLabel != nil ? 8 : 0)
            .background(segment.isOn ? onTint : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!segment.isEnabled)
        .opacity(segment.isEnabled ? 1 : 0.4)
        .accessibilityLabel(segment.label)
        .accessibilityAddTraits(segment.isOn ? .isSelected : [])
        .help(segment.label)
    }
}

/// A divider at the control height, the hairline between two segments of a pill.
public struct HeaderSegmentDivider: View {
    public init() {}

    public var body: some View {
        Rectangle().fill(DT.chipStroke).frame(width: 1, height: TileMetrics.controlHeight)
    }
}

// MARK: - Tab strip

/// One tab of a `HeaderTabStrip`: whatever its label draws (a mark, a name, a status dot), and an optional close.
public struct HeaderTab<ID: Hashable>: Identifiable {
    public let id: ID
    public let help: String
    public let onClose: (() -> Void)?
    fileprivate let label: AnyView

    public init<Label: View>(id: ID, help: String, onClose: (() -> Void)? = nil, @ViewBuilder label: () -> Label) {
        self.id = id
        self.help = help
        self.onClose = onClose
        self.label = AnyView(label())
    }
}

/// A capsule of tabs, one selected, at exactly the control height so a header that holds one stays one row high. The selected tab is
/// tinted in the accent colour; a tab with `onClose` draws its ✕.
public struct HeaderTabStrip<ID: Hashable>: View {
    private let tabs: [HeaderTab<ID>]
    private let selection: ID?
    private let onSelect: (ID) -> Void

    public init(_ tabs: [HeaderTab<ID>], selection: ID?, onSelect: @escaping (ID) -> Void) {
        self.tabs = tabs
        self.selection = selection
        self.onSelect = onSelect
    }

    /// The tab's height: the strip's less its 2 pt inset on each side.
    public static var tabHeight: CGFloat { TileMetrics.controlHeight - 4 }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let selected = tab.id == selection
                Button { onSelect(tab.id) } label: {
                    HStack(spacing: 5) {
                        tab.label
                        if let onClose = tab.onClose {
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14, height: 14)
                                    .background(Circle().fill(Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Self.tabHeight)
                    .background {
                        if selected {
                            Capsule(style: .continuous).fill(DT.systemAccent.opacity(0.16))
                                .overlay(Capsule(style: .continuous).strokeBorder(DT.systemAccent.opacity(0.32), lineWidth: 0.5))
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(tab.help)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: TileMetrics.controlHeight)
        .tileControlSurface()
        .animation(.easeInOut(duration: 0.15), value: selection)
    }
}

// MARK: - Segmented toggle

/// One option of a `HeaderSegmentedToggle`.
public struct HeaderToggleOption<ID: Hashable>: Identifiable {
    public let id: ID
    public let systemImage: String
    public let label: String

    public init(id: ID, systemImage: String, label: String) {
        self.id = id
        self.systemImage = systemImage
        self.label = label
    }
}

/// A capsule of icon options with one selected, tinted in the accent colour: Files' preview / source, a list / grid switch.
public struct HeaderSegmentedToggle<ID: Hashable>: View {
    private let options: [HeaderToggleOption<ID>]
    @Binding private var selection: ID

    public init(selection: Binding<ID>, options: [HeaderToggleOption<ID>]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option.id == selection
                Button { selection = option.id } label: {
                    Image(systemName: option.systemImage)
                        .font(.system(size: 13 + (TileMetrics.isTouch ? 1 : 0), weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(DT.systemAccent) : AnyShapeStyle(.tertiary))
                        .frame(width: TileMetrics.controlButtonWidth, height: TileMetrics.controlHeight)
                        .background(selected ? DT.systemAccent.opacity(0.18) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(option.label)
            }
        }
        .frame(height: TileMetrics.controlHeight)
        .tileControlSurface()
    }
}
