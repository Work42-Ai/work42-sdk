// FollowModeView.swift — what a personal widget shows while this device follows another device (WOR-796).
//
// Following a device shows its personal widgets as that device sees them: a fixed header over their live picture, framed in their colour.
// The header replaces the widget's own: the followed device's avatar, "Following <name> · <device>", and their tabs read-only with the
// one in front marked. There is no "Live", no control, no presence capsule and no way to stop in here (stopping is the session's people
// pill), and nothing in the view takes a touch: the picture is theirs to move.

import SwiftUI

/// The words and order of the follow header, worked out apart from the view so they are tested.
nonisolated public struct FollowModeHeaderModel: Equatable, Sendable {
    public let title: String
    public let tabs: [String]
    public let selected: Int?
    /// "Claude is acting" while an agent acts in the followed instance, else nil.
    public let acting: String?

    /// `device` is how the followed device is named ("iPad", "Mac"). A selection outside `tabs` marks none.
    public init(name: String, device: String, tabs: [String], selected: Int?, agentActing: String? = nil) {
        self.title = "Following \(name) · \(device)"
        self.tabs = tabs
        self.selected = selected.flatMap { tabs.indices.contains($0) ? $0 : nil }
        self.acting = agentActing.map { "\($0) is acting" }
    }
}

/// The follow header over `picture`, which the host supplies (their live picture with the darts over it). The whole view is read-only:
/// it takes no touch.
public struct FollowModeView<Picture: View>: View {
    private let model: FollowModeHeaderModel
    private let initials: String
    private let color: Color
    private let imageURL: URL?
    private let device: Work42AvatarDevice
    private let picture: Picture

    public init(
        _ model: FollowModeHeaderModel, initials: String, color: Color, imageURL: URL? = nil, device: Work42AvatarDevice = .none,
        @ViewBuilder picture: () -> Picture
    ) {
        self.model = model
        self.initials = initials
        self.color = color
        self.imageURL = imageURL
        self.device = device
        self.picture = picture()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Work42Avatar(initials: initials, color: color, imageURL: imageURL, device: device, size: .s24)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                if let acting = model.acting {
                    Text("✳︎ \(acting)").font(.system(size: 11)).foregroundStyle(color).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !model.tabs.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(model.tabs.enumerated()), id: \.offset) { index, title in
                        let isFront = index == model.selected
                        Text(title).font(.system(size: 11.5, weight: isFront ? .semibold : .regular)).lineLimit(1)
                            .foregroundStyle(isFront ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Capsule().fill(isFront ? color : Color.clear))
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            picture
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(Rectangle().strokeBorder(color, lineWidth: 2))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.title)
    }
}
