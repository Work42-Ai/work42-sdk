// ConversationView.swift — the shared scrolling conversation (WOR-235).
//
// One component for the agent chat and the meeting transcript. It owns everything about a long,
// growing, bottom-anchored list so no consumer re-implements it:
//
//   • Windowing. Only the newest `renderCount` items are laid out (starts at one page). The rest
//     load automatically, a page at a time, when the user scrolls within a viewport of the top;
//     the previously topmost row stays under the pointer (no "Show earlier" button).
//   • Bottom pinning. The view starts at, and follows, the newest item while the user is at the
//     bottom. Scrolled up, it never moves; a "Jump to latest" pill counts what arrived.
//   • Labels. With three or more actors every non-me run is labeled with a `GlassAvatar`, a name
//     and a time; with two it is sides only (see `ConversationLayout`).
//
// The scroll machinery is lifted from `Flow42ChatView` (the plain-VStack, `defaultScrollAnchor`,
// live-scroll-gesture design and its hard-won lessons are preserved on purpose).

import AppKit
import SwiftUI

// MARK: - Public model

/// Who an item belongs to, as the avatar and name to draw.
public struct ConversationActor: Sendable, Hashable {
    /// Stable identity. Items with equal ids are the same actor.
    public let id: String
    public let name: String
    public let initials: String
    /// The plain colour of this actor's avatar glass, initials and name.
    public let color: Color
    /// True for the local user: trailing edge, accent bubble, never labeled in automatic mode.
    public let isMe: Bool
    /// A profile photo shown in the avatar's glass ring instead of the initials, when there is one.
    public let imageURL: URL?

    public init(id: String, name: String, initials: String, color: Color, isMe: Bool) {
        self.init(id: id, name: name, initials: initials, color: color, isMe: isMe, imageURL: nil)
    }

    public init(id: String, name: String, initials: String, color: Color, isMe: Bool, imageURL: URL?) {
        self.id = id
        self.name = name
        self.initials = initials
        self.color = color
        self.isMe = isMe
        self.imageURL = imageURL
    }
}

/// What a row builder needs to know about where its item sits.
public struct ConversationRowContext: Sendable {
    /// The item's actor; nil for items that belong to no one (system events, tool cards).
    public let actor: ConversationActor?
    /// True once the conversation has three or more actors.
    public let labeled: Bool
    /// True when the item is the first of a run from the same actor.
    public let isRunStart: Bool
    public let date: Date?
    /// True when my own runs are labeled too (`ConversationLabels.always`).
    public let labelsMe: Bool

    public init(actor: ConversationActor?, labeled: Bool, isRunStart: Bool, date: Date?) {
        self.init(actor: actor, labeled: labeled, isRunStart: isRunStart, date: date, labelsMe: false)
    }

    public init(actor: ConversationActor?, labeled: Bool, isRunStart: Bool, date: Date?, labelsMe: Bool) {
        self.actor = actor
        self.labeled = labeled
        self.isRunStart = isRunStart
        self.date = date
        self.labelsMe = labelsMe
    }

    /// Avatar, name and time belong with this item: labeled mode and first of a run, and either not
    /// me or my runs are labeled too.
    public var showsLabel: Bool {
        guard labeled, isRunStart, let actor else { return false }
        return !actor.isMe || labelsMe
    }
}

// MARK: - Bubble helper

/// A `ChatBubble` placed according to a `ConversationRowContext`: me trailing in accent, others
/// leading and neutral. In labeled mode a run's first item carries the avatar, coloured name and
/// time, and its continuation lines are indented to line up under the first.
public struct ConversationBubble<Content: View>: View {
    let context: ConversationRowContext
    let avatarSize: CGFloat
    @ViewBuilder let content: () -> Content

    public init(
        context: ConversationRowContext,
        avatarSize: CGFloat = 32,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.context = context
        self.avatarSize = avatarSize
        self.content = content
    }

    private static var timeFormatter: DateFormatter { conversationTimeFormatter }

    public var body: some View {
        if let actor = context.actor, actor.isMe {
            if context.labeled && context.labelsMe {
                mineLabeled(actor)
            } else {
                ChatBubble(side: .trailing, style: .accent, content: content)
            }
        } else if context.labeled, let actor = context.actor {
            HStack(alignment: .top, spacing: 8) {
                if context.showsLabel {
                    GlassAvatar(initials: actor.initials, color: actor.color, size: avatarSize, imageURL: actor.imageURL)
                } else {
                    Color.clear.frame(width: avatarSize, height: 1)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if context.showsLabel {
                        caption(actor, nameFirst: true).padding(.horizontal, 6).padding(.top, 2)
                    }
                    ChatBubble(side: .leading, style: .neutral, content: content)
                }
            }
        } else {
            ChatBubble(side: .leading, style: .neutral, content: content)
        }
    }

    /// My run in a conversation that labels everyone: the time and my name above the bubble, my
    /// avatar to its right; continuation lines keep a same-width gap so they line up.
    private func mineLabeled(_ actor: ConversationActor) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                if context.showsLabel {
                    caption(actor, nameFirst: false).padding(.horizontal, 6).padding(.top, 2)
                }
                ChatBubble(side: .trailing, style: .accent, content: content)
            }
            if context.showsLabel {
                GlassAvatar(initials: actor.initials, color: actor.color, size: avatarSize, imageURL: actor.imageURL)
            } else {
                Color.clear.frame(width: avatarSize, height: 1)
            }
        }
    }

    /// Name and time, in reading order for the side: name then time on the leading side, time then
    /// name on the trailing side.
    private func caption(_ actor: ConversationActor, nameFirst: Bool) -> some View {
        let name = Text(actor.name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(actor.color)
        return HStack(spacing: 6) {
            if nameFirst { name }
            if let date = context.date {
                Text(date, formatter: Self.timeFormatter)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            }
            if !nameFirst { name }
        }
    }
}

private let conversationTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
}()

// MARK: - Date divider

/// The thin centred divider shown where two items are five or more minutes apart.
public struct ConversationDateDivider: View {
    let label: String

    public init(label: String) { self.label = label }

    /// "5 min. ago", "2 hr. ago": the agent chat's label.
    public nonisolated static func relativeLabel(for date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// "10:42 AM": a clock time, for recorded meetings that are read after the fact.
    public nonisolated static func clockLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    public var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
            Text(label.uppercased())
                .font(.system(size: DT.f10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
        }
    }
}

// MARK: - Scroll probes (lifted from Flow42ChatView)

/// Distance (pt) from the bottom anchor's bottom edge to the viewport's bottom edge. ~0 or
/// negative means pinned. macOS-14 safe: GeometryReader plus PreferenceKey, not
/// `onScrollGeometryChange`. Reducing with `min` coalesces to a single reported frame.
private struct ConversationBottomDistanceKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// The content top's Y in the scroll viewport's space: 0 at the very top, `-offset` when scrolled.
private struct ConversationTopOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// Tells the view when the USER is scrolling, as opposed to our own `scrollTo` or content changes
/// shifting the distance: only a real gesture may unpin the view or arm the older-page load.
///
/// Two sources, because macOS posts live-scroll notifications only for gestures with phases
/// (trackpad, Magic Mouse, dragging the scrollbar thumb) and NOT for a plain mouse wheel:
///   • `NSScrollView`'s will-start / did-end live-scroll notifications, for those gestures;
///   • a local `NSEvent` monitor for wheel events that land inside this scroll view, for a mouse
///     wheel (a burst of wheel events counts as one scroll that ends 0.25s after the last).
/// A programmatic scroll posts neither, so "only the user can unpin" still holds. Every historical
/// "jumps off the bottom" bug in the chat traced back to using distance as a proxy for intent.
private struct ConversationLiveScrollProbe: NSViewRepresentable {
    let onLiveScrollChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onLiveScrollChange = onLiveScrollChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.onLiveScrollChange = onLiveScrollChange
    }

    private final class ProbeView: NSView {
        var onLiveScrollChange: ((Bool) -> Void)?
        // `deinit` is nonisolated, so these tokens are `nonisolated(unsafe)`: removal is thread-safe
        // and they are opaque and never mutated concurrently.
        nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
        nonisolated(unsafe) private var wheelMonitor: Any?
        private weak var foundScrollView: NSScrollView?
        private var wheelActive = false
        private var wheelEnd: DispatchWorkItem?

        /// How long after the last wheel event the scroll is considered over.
        private static let wheelIdle: TimeInterval = 0.25

        // Observe only: never take part in hit testing.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                // Left its window: stop watching, so a torn-down view never keeps a monitor alive.
                removeWheelMonitor()
                endWheel()
                return
            }
            guard foundScrollView == nil else { return }
            var candidate = superview
            while let v = candidate, !(v is NSScrollView) { candidate = v.superview }
            guard let scrollView = candidate as? NSScrollView else { return }
            foundScrollView = scrollView
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onLiveScrollChange?(true) }
                },
                center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onLiveScrollChange?(false) }
                },
            ]
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handleWheel(event) }
                return event
            }
        }

        private func handleWheel(_ event: NSEvent) {
            guard let scrollView = foundScrollView, event.window === window else { return }
            // Phased events (trackpad, Magic Mouse) already post live-scroll notifications.
            guard event.phase.isEmpty, event.momentumPhase.isEmpty else { return }
            // Only a wheel over THIS scroll view: scrolling another tile must not unpin this one.
            guard scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil)) else { return }
            if !wheelActive {
                wheelActive = true
                onLiveScrollChange?(true)
            }
            wheelEnd?.cancel()
            let end = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.endWheel() }
            }
            wheelEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wheelIdle, execute: end)
        }

        private func endWheel() {
            wheelEnd?.cancel()
            wheelEnd = nil
            guard wheelActive else { return }
            wheelActive = false
            onLiveScrollChange?(false)
        }

        private func removeWheelMonitor() {
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
        }

        deinit {
            let center = NotificationCenter.default
            observers.forEach { center.removeObserver($0) }
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        }
    }
}

/// Latest probe readings, kept off `@State` so a scroll does not re-evaluate the body each frame.
@MainActor
private final class ConversationScrollMetrics {
    var bottomDistance: CGFloat = .infinity
    var topOffset: CGFloat = .infinity
    /// One automatic page load per arrival at the top; re-armed once the page has landed.
    var loadArmed = true
    /// True once the user has scrolled by hand. The first layout pass reports the top before the
    /// bottom anchor applies, so without this a fresh open would load a page it does not need.
    var userHasScrolled = false
}

// MARK: - Labels

/// When a conversation shows avatars, names and times.
public enum ConversationLabels: Sendable {
    /// Labeled once there are three or more distinct actors (counted over the whole conversation),
    /// and never labeling me: the agent chat.
    case automatic
    /// Every run is labeled whatever the number of actors, mine included: the meeting transcript,
    /// where who spoke is the point.
    case always
}

// MARK: - ConversationView

/// A bottom-anchored, windowed, auto-loading conversation list.
///
/// ```swift
/// ConversationView(
///     items: lines, pageSize: 100,
///     actor: { line in actor(for: line) },
///     date: { $0.date }
/// ) { line, context in
///     ConversationBubble(context: context) { Text(line.text) }
/// }
/// ```
@MainActor
public struct ConversationView<Item: Identifiable, Row: View, Footer: View>: View where Item.ID: Sendable {

    let items: [Item]
    let pageSize: Int
    let resetKey: AnyHashable
    let scrollToBottomTrigger: Int
    let rowSpacing: CGFloat
    let runSpacing: CGFloat?
    let labels: ConversationLabels
    let dividerLabel: (Date) -> String
    let actor: (Item) -> ConversationActor?
    let date: (Item) -> Date?
    let row: (Item, ConversationRowContext) -> Row
    let footer: () -> Footer

    /// - Parameters:
    ///   - items: The whole conversation, oldest first. Pass all of it; the view windows it.
    ///   - pageSize: Items laid out initially and added by each automatic load.
    ///   - resetKey: Changing it (a different session) resets to the newest page at the bottom.
    ///   - scrollToBottomTrigger: Bump to pin and animate to the newest item (the user sent a
    ///     message, a turn finished). It also trims the window back to one page.
    ///   - rowSpacing: Space between rows.
    ///   - runSpacing: Tighter space between consecutive items of one actor; nil keeps `rowSpacing`.
    ///   - labels: `.automatic` (labels from three actors, never mine) or `.always` (every run, mine too).
    ///   - dividerLabel: The text of a time divider.
    ///   - actor: The item's actor, or nil for items that are no one's (they neither count towards
    ///     labeled mode nor break a run).
    ///   - date: When the item happened (drives dividers and the label time).
    ///   - row: The row for an item. `ConversationBubble` does the standard placement.
    ///   - footer: Content after the last row and inside the scroll (typing indicator, queued messages).
    public init(
        items: [Item],
        pageSize: Int,
        resetKey: AnyHashable = 0,
        scrollToBottomTrigger: Int = 0,
        rowSpacing: CGFloat = 12,
        runSpacing: CGFloat? = nil,
        labels: ConversationLabels = .automatic,
        dividerLabel: @escaping (Date) -> String = ConversationDateDivider.relativeLabel(for:),
        actor: @escaping (Item) -> ConversationActor?,
        date: @escaping (Item) -> Date?,
        @ViewBuilder row: @escaping (Item, ConversationRowContext) -> Row,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.items = items
        self.pageSize = max(1, pageSize)
        self.resetKey = resetKey
        self.scrollToBottomTrigger = scrollToBottomTrigger
        self.rowSpacing = rowSpacing
        self.runSpacing = runSpacing
        self.labels = labels
        self.dividerLabel = dividerLabel
        self.actor = actor
        self.date = date
        self.row = row
        self.footer = footer
        _renderCount = State(initialValue: max(1, pageSize))
    }

    // MARK: State

    @State private var renderCount: Int
    @State private var isPinnedToBottom = true
    @State private var isLiveScrolling = false
    @State private var viewportHeight: CGFloat = 0
    @State private var lastItemCount = 0
    /// Item count when the user last was at the bottom; the pill shows `count - seenCount`.
    @State private var seenCount = 0
    @State private var metrics = ScrollMetrics()

    private typealias ScrollMetrics = ConversationScrollMetrics

    private static var scrollSpace: String { "conversationScroll" }
    private static var bottomAnchorID: String { "conversation-bottom-anchor" }
    /// Within this many points of the bottom edge counts as "at the bottom".
    private static var bottomPinThreshold: CGFloat { 24 }

    // MARK: Layout

    private struct RowKey {
        let index: Int
        let id: Item.ID
    }

    private struct Layout {
        var labeled: Bool
        var runStarts: Set<Item.ID>
        var dividers: Set<Item.ID>
        var actors: [Item.ID: ConversationActor]
    }

    private func layout(windowStart: Int) -> Layout {
        let always = labels == .always
        // Automatic labeled mode counts actors over the WHOLE conversation: it must not flip while
        // the user scrolls through history, and a late third speaker labels the earlier items too.
        // `.always` needs no count, so it only visits the window (the cost that matters on a
        // transcript of thousands of lines, redrawn on every appended line).
        var all: [ConversationEntry<Item.ID>] = []
        var actors: [Item.ID: ConversationActor] = [:]
        if always {
            for item in items[windowStart...] {
                if let a = actor(item) { actors[item.id] = a }
            }
        } else {
            for (index, item) in items.enumerated() {
                guard let a = actor(item) else { continue }
                all.append(ConversationEntry(id: item.id, actorID: a.id, isMe: a.isMe, date: nil))
                if index >= windowStart { actors[item.id] = a }
            }
        }
        // Runs and dividers are only needed for the window, plus one item before it so the first
        // rendered row knows whether it continues a run.
        let from = max(0, windowStart - 1)
        var windowActors: [ConversationEntry<Item.ID>] = []
        var windowDated: [ConversationEntry<Item.ID>] = []
        for item in items[from...] {
            if let a = actor(item) {
                windowActors.append(ConversationEntry(id: item.id, actorID: a.id, isMe: a.isMe, date: nil))
            }
            windowDated.append(ConversationEntry(id: item.id, actorID: "", isMe: false, date: date(item)))
        }
        return Layout(
            labeled: always || ConversationLayout.labeledMode(entries: all),
            runStarts: ConversationLayout.runStarts(entries: windowActors),
            dividers: ConversationLayout.dividerBefore(entries: windowDated),
            actors: actors
        )
    }

    // MARK: Body

    public var body: some View {
        let windowStart = ConversationLayout.renderedStart(itemCount: items.count, renderCount: renderCount)
        let hiddenOlder = windowStart
        // The ForEach iterates light keys (an index and an id), not `Item` values: SwiftUI copies
        // the data element on every placement pass, and for a multi-word enum that copy plus its
        // ARC traffic dominated a fast scroll in the agent chat. The row looks its item up.
        let rowKeys = (windowStart..<items.count).map { RowKey(index: $0, id: items[$0].id) }
        let layout = layout(windowStart: windowStart)

        return ScrollViewReader { proxy in
            ScrollView {
                // A PLAIN VStack, deliberately. Under `defaultScrollAnchor(.bottom)` a LazyVStack
                // can place the viewport over unrealized rows (estimated heights) and render
                // nothing until a scroll forces realization: the blank-chat bug. The window keeps
                // this stack bounded (a page, growing only as the user reads history), so eager
                // layout is affordable and the bottom anchor always lands on real content. Do not
                // make this lazy without re-testing the blank-at-mount state.
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 1)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ConversationTopOffsetKey.self,
                                    value: geo.frame(in: .named(Self.scrollSpace)).minY
                                )
                            }
                        )
                    if hiddenOlder > 0 {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading earlier\u{2026}")
                                .font(.system(size: DT.f11))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    ForEach(rowKeys, id: \.id) { key in
                        let item = items[key.index]
                        let offset = key.index - windowStart
                        let actor = layout.actors[item.id]
                        let isRunStart = actor == nil || layout.runStarts.contains(item.id)
                        let isFirst = offset == 0
                        if layout.dividers.contains(item.id), let when = date(item) {
                            ConversationDateDivider(label: dividerLabel(when))
                                .padding(.top, isFirst ? 0 : rowSpacing)
                        }
                        row(item, ConversationRowContext(
                            actor: actor, labeled: layout.labeled, isRunStart: isRunStart, date: date(item),
                            labelsMe: labels == .always
                        ))
                        .id(item.id)
                        .padding(.top, isFirst ? 0 : spacing(before: isRunStart, hasDivider: layout.dividers.contains(item.id)))
                        // Rows land instantly: no insert/remove animation inside the list.
                        .transition(.identity)
                    }
                    footer()
                    Color.clear
                        .frame(height: 6)
                        .id(Self.bottomAnchorID)
                        .background(
                            GeometryReader { anchor in
                                Color.clear.preference(
                                    key: ConversationBottomDistanceKey.self,
                                    value: anchor.frame(in: .named(Self.scrollSpace)).maxY - viewportHeight
                                )
                            }
                        )
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: Self.scrollSpace)
            .background(
                GeometryReader { viewport in
                    Color.clear
                        .onAppear { viewportHeight = viewport.size.height }
                        .onChange(of: viewport.size.height) { _, h in viewportHeight = h }
                }
            )
            .background(
                ConversationLiveScrollProbe { scrolling in
                    isLiveScrolling = scrolling
                    if scrolling { metrics.userHasScrolled = true }
                }
                .frame(width: 0, height: 0)
            )
            // Distance may RE-pin (arriving back at the bottom is unambiguous, whatever the cause)
            // but may UNPIN only during a real gesture: content insertion, an animation settling
            // or our own scrollTo must never take the view away from the bottom.
            .onPreferenceChange(ConversationBottomDistanceKey.self) { distance in
                guard distance.isFinite else { return }
                metrics.bottomDistance = distance
                let pinned = distance <= Self.bottomPinThreshold
                if pinned {
                    if !isPinnedToBottom { isPinnedToBottom = true }
                } else if isLiveScrolling, isPinnedToBottom {
                    isPinnedToBottom = false
                }
            }
            // Automatic older-page loading, once per arrival near the top.
            .onPreferenceChange(ConversationTopOffsetKey.self) { top in
                guard top.isFinite else { return }
                metrics.topOffset = top
                guard metrics.loadArmed else { return }
                let hidden = ConversationLayout.renderedStart(itemCount: items.count, renderCount: renderCount)
                guard hidden > 0 else { return }
                let nearTop = metrics.userHasScrolled && top > -viewportHeight
                // A window shorter than the viewport has nothing to scroll: fill it.
                let underfilled = top >= 0 && metrics.bottomDistance <= 0
                guard nearTop || underfilled else { return }
                metrics.loadArmed = false
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    renderCount = ConversationLayout.grownRenderCount(current: renderCount, pageSize: pageSize)
                }
            }
            // The scroll view starts at the bottom and STAYS there while content grows, as long as
            // the user has not scrolled away: following needs no scrollTo at all.
            .defaultScrollAnchor(.bottom)
            // Back at the bottom: trim the window to one page (invisible, rows above the viewport)
            // and mark everything seen.
            .onChange(of: isPinnedToBottom) { _, pinned in
                guard pinned else { return }
                seenCount = items.count
                if renderCount != pageSize {
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { renderCount = pageSize }
                }
            }
            // Boundary stability while reading history: when the conversation grows and the user is
            // NOT at the bottom, grow the window by the same delta so the rendered set stays a
            // superset and the oldest visible row never changes under them.
            .onChange(of: items.count) { _, count in
                defer { lastItemCount = count }
                if isPinnedToBottom {
                    seenCount = count
                } else if count > lastItemCount {
                    renderCount += count - lastItemCount
                }
            }
            // A page was added above the viewport: keep the user's place by re-anchoring on the
            // previously topmost row. Synchronous handler, so the proxy is live.
            .onChange(of: renderCount) { oldCount, newCount in
                defer { metrics.loadArmed = true }
                guard newCount > oldCount else { return }
                let previousTop = ConversationLayout.renderedStart(itemCount: items.count, renderCount: oldCount)
                guard items.indices.contains(previousTop) else { return }
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    proxy.scrollTo(items[previousTop].id, anchor: .top)
                }
            }
            .onChange(of: resetKey) { _, _ in
                isPinnedToBottom = true
                renderCount = pageSize
                lastItemCount = items.count
                seenCount = items.count
                metrics.userHasScrolled = false
                metrics.loadArmed = true
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: scrollToBottomTrigger) { _, _ in
                isPinnedToBottom = true
                seenCount = items.count
                // Order matters (a chat bug fixed the hard way): scroll to the bottom of the CURRENT,
                // not-yet-trimmed content first, THEN trim the window. Dropping rows above the
                // viewport once we are at the bottom is invisible; trimming before or together with
                // the animated scroll races the content shrink's offset clamping against the scroll
                // and can land away from the bottom.
                scrollToBottom(proxy, animated: true)
                if renderCount != pageSize {
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { renderCount = pageSize }
                }
            }
            // A turn can finish while the app is in the background, where the scroll cannot apply.
            // Re-pin on return, but only when already pinned so a deliberate scroll-up is kept.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if isPinnedToBottom { scrollToBottom(proxy, animated: false) }
            }
            .onAppear {
                lastItemCount = items.count
                seenCount = items.count
            }
            .overlay(alignment: .bottom) {
                if !isPinnedToBottom {
                    jumpToLatest(proxy)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isPinnedToBottom)
        }
    }

    private func spacing(before isRunStart: Bool, hasDivider: Bool) -> CGFloat {
        if hasDivider { return rowSpacing }
        if let runSpacing, !isRunStart { return runSpacing }
        return rowSpacing
    }

    private func jumpToLatest(_ proxy: ScrollViewProxy) -> some View {
        let unseen = max(0, items.count - seenCount)
        return Button {
            // Synchronous button action: a safe scroll site.
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { renderCount = pageSize }
            isPinnedToBottom = true
            seenCount = items.count
            scrollToBottom(proxy, animated: true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: DT.f11, weight: .semibold))
                Text("Jump to latest")
                    .font(.system(size: DT.f12, weight: .medium))
                if unseen > 0 {
                    Text("\(unseen)")
                        .font(.system(size: DT.f10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(DT.systemAccent))
                }
            }
            .padding(.horizontal, 4)
        }
        .glassSubtleCapsule(tint: DT.systemAccent)
        .help("Scroll to the newest message")
    }

    /// Scroll to the bottom anchor. MUST be called from a synchronous SwiftUI context (an
    /// `.onChange`/event handler), never from an async `Task`: `ScrollViewProxy.scrollTo` traps
    /// (`EXC_BREAKPOINT`) when its ScrollView has been torn down, and only the synchronous update
    /// path guarantees a live proxy.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }
}

extension ConversationView where Footer == EmptyView {
    /// A conversation without a footer.
    public init(
        items: [Item],
        pageSize: Int,
        resetKey: AnyHashable = 0,
        scrollToBottomTrigger: Int = 0,
        rowSpacing: CGFloat = 12,
        runSpacing: CGFloat? = nil,
        labels: ConversationLabels = .automatic,
        dividerLabel: @escaping (Date) -> String = ConversationDateDivider.relativeLabel(for:),
        actor: @escaping (Item) -> ConversationActor?,
        date: @escaping (Item) -> Date?,
        @ViewBuilder row: @escaping (Item, ConversationRowContext) -> Row
    ) {
        self.init(
            items: items, pageSize: pageSize, resetKey: resetKey,
            scrollToBottomTrigger: scrollToBottomTrigger, rowSpacing: rowSpacing, runSpacing: runSpacing,
            labels: labels, dividerLabel: dividerLabel, actor: actor, date: date, row: row, footer: { EmptyView() }
        )
    }
}

// MARK: - Preview

private struct PreviewLine: Identifiable {
    let id: Int
    let who: Int
    let text: String
}

private func previewConversation(speakers: Int, labels: ConversationLabels = .automatic) -> some View {
    let people: [ConversationActor] = [
        ConversationActor(id: "me", name: "You", initials: "Y", color: .blue, isMe: true),
        ConversationActor(id: "ana", name: "Ana L\u{00F3}pez", initials: "AL", color: Color(red: 0.86, green: 0.15, blue: 0.47), isMe: false),
        ConversationActor(id: "s2", name: "Speaker 2", initials: "S2", color: Color(red: 0.02, green: 0.59, blue: 0.41), isMe: false),
        ConversationActor(id: "ai", name: "Work42 agent", initials: "42", color: Color(red: 0.49, green: 0.23, blue: 0.93), isMe: false),
    ]
    let lines = (0..<120).map { i in
        PreviewLine(id: i, who: i % 3 == 0 ? 0 : 1 + (i / 2) % max(1, speakers - 1),
                    text: "Line \(i): " + String(repeating: "the quick brown fox ", count: 1 + i % 4))
    }
    let start = Date().addingTimeInterval(-3600)
    return ConversationView(
        items: lines, pageSize: 40, runSpacing: 4, labels: labels,
        dividerLabel: ConversationDateDivider.clockLabel(for:),
        actor: { people[$0.who] },
        date: { start.addingTimeInterval(Double($0.id) * (($0.id % 40 == 0) ? 400 : 8)) }
    ) { line, context in
        ConversationBubble(context: context) { Text(line.text).padding(12) }
    }
    .frame(width: 520, height: 560)
}

#Preview("2 actors") { previewConversation(speakers: 2) }
#Preview("3 actors") { previewConversation(speakers: 4) }
#Preview("transcript 1:1, everyone labeled") { previewConversation(speakers: 2, labels: .always) }
