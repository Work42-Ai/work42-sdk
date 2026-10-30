// ChatMetrics.swift - One spacing system for the chat, its composer and the activity components (WOR-470).
//
// The chat used to mix 16/18/20/24 pt edges and a flat 16 pt between everything. These are the agreed values
// (artifact `chat-spacing`): one side margin, a clear gap between turns, a smaller one between the blocks of a
// turn, and an airy reply text. `ConversationMetrics` and the app's chat and composer read from here.

import AppKit
import SwiftUI

public enum ChatMetrics {
    /// Distance from the window edge to the transcript, header, composer box and status strip.
    public static let sideMargin: CGFloat = DT.s20
    /// Gap between turns (the speaker changes).
    public static let turnSpacing: CGFloat = 28
    /// Gap between the blocks of one turn (text, activity card, text).
    public static let blockSpacing: CGFloat = 16

    public static let avatarSize: CGFloat = 28
    public static let avatarGap: CGFloat = 10
    /// From the speaker's header to the first line of the turn.
    public static let headerToBody: CGFloat = 10

    public static let bodyFontSize: CGFloat = 16
    /// Line height of reply text (about 1.6x, WOR-510: a little more air than the first 1.5x).
    public static let bodyLineHeight: CGFloat = 26
    public static let paragraphSpacing: CGFloat = 16
    /// Letter spacing of reply text, in points (WOR-510). Code keeps its own spacing.
    public static let bodyTracking: CGFloat = 0.2
    /// Extra space between wrapped lines that brings the body font to `bodyLineHeight`.
    public static var bodyLineSpacing: CGFloat {
        max(0, bodyLineHeight - NSFont.systemFont(ofSize: bodyFontSize).boundingRectForFont.height.rounded())
    }

    /// Padding inside my message card.
    public static let myCardPadding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)

    /// Text inside the composer box.
    public static let composerTextInsets = EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18)
    /// The composer box inside the widget: side margin, with air above and below.
    /// Left, right and bottom are the same `sideMargin`, so the box is as far from the widget's edge below as at the
    /// sides (WOR-504); the top is the gap to the transcript above it.
    public static let composerOuter = EdgeInsets(top: 14, leading: sideMargin, bottom: sideMargin, trailing: sideMargin)

    /// Height of one row in an activity card, and the air around an opened detail. About 1.2x what they were (WOR-509):
    /// the card read tight.
    public static let activityRowHeight: CGFloat = 36
    public static let detailTop: CGFloat = 8
    public static let detailBottom: CGFloat = 14
    /// Padding between an activity card's edge and its rows.
    public static let activityCardPadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    /// Padding inside a detail panel (the code, diff or output under a step), and the room its header buttons get.
    public static let panelPadding: CGFloat = 14
    /// Height of a detail panel's header: the same as the chat's code card, so their buttons line up (WOR-507).
    public static let panelHeaderHeight: CGFloat = 38

    /// Text sizes of the activity card (WOR-508): the same size for the sentence and its rows, so the card reads as
    /// one quiet block of the reply; the sentence differs by colour and a medium-light weight, not by size.
    public static let activitySentenceSize: CGFloat = 13
    public static let activityRowSize: CGFloat = 13
    public static let activityMetaSize: CGFloat = 12
}
