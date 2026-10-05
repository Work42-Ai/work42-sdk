// ChatBubble.swift — shared bubble primitive for chat and meeting transcript.
//
// Extracted from Flow42UserMessageBubble (Flow42Core/Chat/Flow42ChatView.swift)
// so both the chat view and the meeting transcript tile render through the same
// chrome. Placement rationale: Flow42Core depends on Work42UI (see Package.swift
// target deps), so Work42UI is the lowest shared module that avoids an import
// cycle. Any surface that can see Work42UI — Flow42Core, Work42App, etc. — can
// use ChatBubble without cycle risk.
//
// quiet-lark.19

import AppKit
import SwiftUI

// MARK: - ChatBubble public types

/// Which edge of the conversation the bubble aligns to.
public enum ChatBubbleSide: Sendable {
    /// Leading (left) edge — used for others / incoming messages.
    case leading
    /// Trailing (right) edge — used for the local user / outgoing messages.
    case trailing
}

/// The visual tint/style of the bubble background and text.
public enum ChatBubbleStyle: Sendable {
    /// Translucent system-accent tint (`DT.systemAccent.opacity(0.12)`) with
    /// `DT.accentForeground` text. Used for the local user's messages.
    case accent
    /// Neutral/secondary tint with `.primary` text. Used for generic "other"
    /// speaker messages.
    case neutral
    /// Per-speaker hue: a deterministic per-name color with a low-alpha tint
    /// background and a readable foreground derived from the same hue. Used for
    /// named meeting participants so each gets a distinct tint.
    case speaker(Color)
}

/// Optional metadata shown in a header row above the bubble content.
/// All fields are optional — omit any combination.
public struct ChatBubbleHeader: Sendable {
    /// Display name shown beside the avatar (e.g. "Them", "Alice").
    public let name: String?
    /// Avatar to show. When nil, an initials circle is synthesised from `name`.
    public let avatar: ChatBubbleAvatar?
    /// Timestamp shown at the trailing edge of the header row.
    public let timestamp: Date?

    public init(name: String? = nil, avatar: ChatBubbleAvatar? = nil, timestamp: Date? = nil) {
        self.name = name
        self.avatar = avatar
        self.timestamp = timestamp
    }
}

/// Avatar specification for the bubble header row.
public enum ChatBubbleAvatar: Sendable {
    /// Render an initials circle using the provided initials string.
    /// Supply up to two characters (e.g. "AB"). The background color is
    /// derived from `speakerColor(for:)` using the initials as the key when
    /// no explicit color is given.
    case initials(String, color: Color? = nil)
}

// MARK: - ChatBubble

/// A reusable SwiftUI bubble primitive shared by the chat view and the
/// meeting transcript tile.
///
/// Usage:
/// ```swift
/// ChatBubble(side: .trailing, style: .accent, header: nil) {
///     Text("Hello!")
/// }
/// ```
///
/// The caller supplies the bubble content via a `@ViewBuilder` closure, so
/// any view (Text, Markdown, custom VStack, etc.) works inside the chrome.
/// The chrome handles:
///   - alignment (leading vs trailing)
///   - background tint (accent / neutral / per-speaker hue)
///   - 12pt continuous corner radius
///   - 75% max-width cap (measured via a zero-height `GeometryReader`)
///   - an optional header row (avatar + name + timestamp)
@MainActor
public struct ChatBubble<Content: View>: View {
    let side: ChatBubbleSide
    let style: ChatBubbleStyle
    let header: ChatBubbleHeader?
    /// Optional: makes the header avatar a click target (plain button +
    /// accent hover ring). nil — the default for every existing call site —
    /// keeps the avatar inert. Used by the meeting transcript's
    /// "who is this?" speaker resolver (the avatar IS the affordance there,
    /// per the confirmed speaker-people-redesign mockup).
    let onAvatarTap: (() -> Void)?
    @ViewBuilder let content: () -> Content

    public init(
        side: ChatBubbleSide,
        style: ChatBubbleStyle,
        header: ChatBubbleHeader? = nil,
        onAvatarTap: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.side = side
        self.style = style
        self.header = header
        self.onAvatarTap = onAvatarTap
        self.content = content
    }

    /// True while the pointer hovers a tappable avatar — drives the accent
    /// affordance ring.
    @State private var avatarHovered = false

    // Measured via a zero-height GeometryReader background so this state
    // doesn't disturb the bubble's intrinsic height. Starts at 0 so the
    // first layout pass simply hugs content (no cap) until the real
    // width arrives — same pattern as Flow42UserMessageBubble.
    @State private var availableWidth: CGFloat = 0

    /// Fraction of the container width the bubble may occupy at most.
    /// 75% matches the existing Flow42UserMessageBubble cap.
    private var maxWidthFraction: CGFloat { 0.75 }

    // MARK: background fill

    private var fillColor: Color {
        switch style {
        case .accent:
            return DT.systemAccent.opacity(0.12)
        case .neutral:
            return Color.secondary.opacity(0.10)
        case .speaker(let hue):
            return hue.opacity(0.12)
        }
    }

    // MARK: foreground (text) color

    /// Color for the MESSAGE TEXT inside the pill. The per-speaker hue is
    /// deliberately NOT used here — it would hurt readability on the 0.12
    /// tint. The hue colors only the name caption + avatar; the body text
    /// stays `.primary` (or `accentForeground` for the local user).
    private var foregroundColor: Color {
        switch style {
        case .accent:
            return DT.accentForeground
        case .neutral, .speaker:
            return .primary
        }
    }

    /// Color for the name caption (and avatar). This is where the per-speaker
    /// hue shows up, so each participant is identifiable at a glance.
    private var nameColor: Color {
        switch style {
        case .accent:
            return DT.accentForeground
        case .neutral:
            return .secondary
        case .speaker(let hue):
            return hue
        }
    }

    public var body: some View {
        Group {
            if side == .trailing {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    bubbleCluster
                }
            } else {
                HStack(spacing: 0) {
                    bubbleCluster
                    Spacer(minLength: 0)
                }
            }
        }
        .background(
            // Zero-height probe: measures the container's content width
            // without affecting the bubble's intrinsic height.
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: ChatBubbleWidthKey.self,
                        value: proxy.size.width
                    )
            }
        )
        .onPreferenceChange(ChatBubbleWidthKey.self) { width in
            availableWidth = width
        }
    }

    // MARK: - Bubble cluster (avatar + caption + pill)
    //
    // The PILL (fill + content) is the shared element — it always hugs its
    // content and is the exact same chrome the chat view uses. The avatar and
    // the name/timestamp caption live OUTSIDE the pill so they never force it
    // to stretch full-width (the previous header-with-Spacer-inside-the-card
    // bug). The whole cluster is capped at 75% of the container width, so a
    // long message wraps at the cap instead of inflating the bubble.

    private var bubbleCluster: some View {
        let hAlign: HorizontalAlignment = side == .leading ? .leading : .trailing
        return HStack(alignment: .top, spacing: 6) {
            if side == .leading, let avatar = header?.avatar {
                avatarView(avatar, name: header?.name)
            }
            VStack(alignment: hAlign, spacing: 3) {
                if let header, hasCaption(header) {
                    captionRow(header)
                }
                pill
            }
            if side == .trailing, let avatar = header?.avatar {
                avatarView(avatar, name: header?.name)
            }
        }
        .frame(
            maxWidth: availableWidth > 0 ? availableWidth * maxWidthFraction : nil,
            alignment: side == .leading ? .leading : .trailing
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    // The pill: the rounded, tinted container that hugs the content. This is
    // identical for the chat and the transcript — the single shared "bubble".
    private var pill: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .foregroundStyle(foregroundColor)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(fillColor)
        )
        // Expose the foreground color via the environment so nested views in
        // the content closure can inherit it.
        .environment(\.chatBubbleForegroundColor, foregroundColor)
    }

    private func hasCaption(_ h: ChatBubbleHeader) -> Bool {
        (h.name?.isEmpty == false) || h.timestamp != nil
    }

    // MARK: - Caption row (name + timestamp, outside the pill)

    @ViewBuilder
    private func captionRow(_ h: ChatBubbleHeader) -> some View {
        HStack(spacing: 6) {
            if let name = h.name, !name.isEmpty {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(nameColor)
            }
            if let ts = h.timestamp {
                Text(ts, formatter: relativeFormatter)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func avatarView(_ avatar: ChatBubbleAvatar, name: String?) -> some View {
        switch avatar {
        case .initials(let text, let color):
            let resolvedColor = color ?? speakerColor(for: text)
            if let onAvatarTap {
                Button(action: onAvatarTap) {
                    initialsCircle(text, color: resolvedColor)
                }
                .buttonStyle(.plain)
                .overlay(
                    Circle().strokeBorder(
                        DT.systemAccent.opacity(avatarHovered ? 0.55 : 0),
                        lineWidth: 2.5
                    )
                    .padding(-2.5)
                )
                .onHover { avatarHovered = $0 }
                .help("Who is this?")
            } else {
                initialsCircle(text, color: resolvedColor)
            }
        }
    }

    private func initialsCircle(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 22, height: 22)
            .background(color, in: Circle())
    }

    private var relativeFormatter: DateFormatter { chatBubbleRelativeFormatter }
}

// MARK: - ChatBubble environment key (foreground color)

/// Internal environment key so the content closure can read the bubble's
/// computed foreground color via `@Environment(\.chatBubbleForegroundColor)`.
public struct ChatBubbleForegroundColorKey: EnvironmentKey {
    public static let defaultValue: Color = .primary
}

public extension EnvironmentValues {
    var chatBubbleForegroundColor: Color {
        get { self[ChatBubbleForegroundColorKey.self] }
        set { self[ChatBubbleForegroundColorKey.self] = newValue }
    }
}

// MARK: - Width preference key

/// Carries the row's content width from the zero-height background probe so
/// `ChatBubble` can cap itself at 75% of that width.
private struct ChatBubbleWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Shared relative date formatter

/// Module-level singleton so every ChatBubble instance shares one DateFormatter
/// (generic structs cannot hold static stored properties — this avoids the
/// "static stored properties not supported in generic types" compiler error).
private let chatBubbleRelativeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.doesRelativeDateFormatting = true
    f.dateStyle = .none
    f.timeStyle = .short
    return f
}()

// MARK: - Speaker color helper

/// Returns a deterministic, stable hue-based `Color` for a given speaker key
/// (e.g. a display name or an opaque identifier).
///
/// The algorithm: hash the UTF-8 bytes of `key` via a simple FNV-1a 32-bit
/// hash (cheap, deterministic, no crypto dependency), then map the result to
/// a hue in the 0–360 range. Saturation and brightness are fixed at values
/// that look readable on both light and dark backgrounds at 0.12 alpha.
///
/// Both the chat view and the meeting transcript tile call this helper so
/// every surface assigns the same hue to the same participant.
public func speakerColor(for key: String) -> Color {
    var hash: UInt32 = 2_166_136_261 // FNV offset basis
    for byte in key.utf8 {
        hash ^= UInt32(byte)
        hash &*= 16_777_619 // FNV prime
    }
    let hue = Double(hash % 360) / 360.0
    // Fixed saturation/brightness chosen so all hues are vivid but not
    // overpowering on a 0.12-alpha tinted background. Adaptive via HSB
    // so both dark- and light-mode tints stay readable.
    return Color(hue: hue, saturation: 0.65, brightness: 0.85)
}

// MARK: - Initials helper

/// Returns a 1–2 character initials string for a display name.
///
/// Splits on whitespace and takes the first letter of each word (up to two
/// words). Falls back to the first character of the whole string. Returns
/// "?" when `name` is empty.
public func initialsString(for name: String) -> String {
    let words = name.split(separator: " ").map { String($0) }
    switch words.count {
    case 0:
        return name.isEmpty ? "?" : String(name.prefix(1)).uppercased()
    case 1:
        return String(words[0].prefix(1)).uppercased()
    default:
        let first = String(words[0].prefix(1))
        let second = String(words[1].prefix(1))
        return (first + second).uppercased()
    }
}
