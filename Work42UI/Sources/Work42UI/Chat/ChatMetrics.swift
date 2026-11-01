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
    /// Line height of reply text (1.5x). A taller line, a wider paragraph gap and letter spacing were tried (WOR-510)
    /// and looked wrong on the regular chat, so they were taken out again (WOR-512).
    public static let bodyLineHeight: CGFloat = 24
    public static let paragraphSpacing: CGFloat = 14
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
    /// The code panel (`CodePanel`, WOR-516): the chat's fenced code block, an activity card's detail panels and the
    /// inline terminal are one component, so these are the only numbers they use. They are the chat code card's.
    public static let codePanelPadding: CGFloat = 12
    /// The panel's buttons are the large glass size ("+ Add Widget"); the header is as tall as one plus the air above
    /// and below it (WOR-517).
    public static let codePanelHeaderHeight: CGFloat = 52
    public static let codePanelHeaderTop: CGFloat = 0

    /// Text sizes of the activity card (WOR-508): the same size for the sentence and its rows, so the card reads as
    /// one quiet block of the reply; the sentence differs by colour, not by size or weight. 13 pt read too small, so
    /// it is 14 again (WOR-512).
    public static let activitySentenceSize: CGFloat = 14
    public static let activityRowSize: CGFloat = 14
    public static let activityMetaSize: CGFloat = 12
}
