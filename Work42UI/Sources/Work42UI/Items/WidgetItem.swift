// WidgetItem.swift — item kinds: collections whose items can stand alone (SDK 2.15.0, WOR-559).
//
// Some widgets are collections: the Artifacts gallery holds artifacts, the Terminal holds terminals, the chat strip holds chats.
// A collection widget describes what its items ARE (a `WidgetItemKind`) and how ONE item is drawn (a `WidgetItemProvider`); the host
// does everything else once, for every kind: the layout leaf `<kind>:<id>`, saving and restoring it, the "Open as its own widget"
// entry in the widget's `···` menu, the "in a widget" mark, the agent's `widget_open` / `widget_list`, the iPad.
//
// Nothing here is a stored field of an existing public struct, so adopting it changes no binary layout: a widget built for an
// earlier SDK loads and behaves as before.

import Foundation
import SwiftUI

// MARK: - Kind

/// How many places an item can be shown at once.
public enum WidgetItemViewers: String, Sendable, Codable {
    /// The item can show in its collection and in tiles at the same time (an artifact: each view is its own web view).
    case many
    /// The item is in exactly one place (a terminal's native view, a chat's composer). While it has a tile, clicking its entry in
    /// the collection focuses the tile and the collection never switches to it.
    case one
}

/// What a collection holds. Declared once, by the widget that owns the collection.
public struct WidgetItemKind: Hashable, Sendable {

    /// The kind's id and the first half of its layout key. Built-in kinds use short names (`artifact`); a plugin's kinds start
    /// with the id of the widget that declares them (see `isPluginKind(_:ownedBy:)`).
    public let id: String
    /// The kind id of the collection widget whose availability and access rules apply to this kind's tiles (`artifacts`).
    public let collection: String
    /// SF Symbol for the kind's generic states and its entry in the agent's widget list.
    public let symbol: String
    public let viewers: WidgetItemViewers
    /// Whether the host offers "Open as its own widget" for the item the collection is showing.
    public let detachable: Bool
    /// The generic empty state's wording when an item does not exist (yet, or any more).
    public let missingTitle: String
    public let missingDetail: String

    public init(
        id: String,
        collection: String,
        symbol: String = "square",
        viewers: WidgetItemViewers = .many,
        detachable: Bool = false,
        missingTitle: String = "Not available",
        missingDetail: String = ""
    ) {
        self.id = id
        self.collection = collection
        self.symbol = symbol
        self.viewers = viewers
        self.detachable = detachable
        self.missingTitle = missingTitle
        self.missingDetail = missingDetail
    }

    /// Whether `kindId` is a kind the widget `widgetSlug` may declare: its own slug, or the slug plus `-` and a suffix, so two
    /// plugins can never claim the same kind.
    public static func isPluginKind(_ kindId: String, ownedBy widgetSlug: String) -> Bool {
        guard WidgetItemRef.isValidKindId(kindId), WidgetItemRef.isValidKindId(widgetSlug) else { return false }
        return kindId == widgetSlug || kindId.hasPrefix(widgetSlug + "-")
    }
}

// MARK: - Ref

/// One item of a kind. Its `key` is the layout leaf: `<kind>:<id>`, the shape `file:<path>` already has.
public struct WidgetItemRef: Hashable, Sendable, Codable {

    public let kind: String
    public let id: String

    public init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }

    public var key: String { kind + ":" + id }

    /// Parses `<kind>:<id>`, splitting at the first colon (an id may contain colons). Nil when the kind is not a valid kind id or
    /// the id is empty. Purely syntactic: a ref is an item only when its kind is registered with the host.
    public init?(key: String) {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let kind = String(key[..<colon])
        let id = String(key[key.index(after: colon)...])
        guard Self.isValidKindId(kind), !id.isEmpty else { return nil }
        self.init(kind: kind, id: id)
    }

    /// `^[a-z0-9][a-z0-9-]*$`, the same shape as a widget slug and an artifact id.
    public static func isValidKindId(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, Self.isLowerAlnum(first) else { return false }
        return value.unicodeScalars.allSatisfy { Self.isLowerAlnum($0) || $0 == "-" }
    }

    private static func isLowerAlnum(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
    }
}

// MARK: - Phase, info, surface

/// Where an item is. Read live on every render; the host draws the generic parts (a spinner while `working`, an "Ended" mark,
/// the kind's missing wording).
public enum WidgetItemPhase: String, Equatable, Sendable, Codable {
    /// There, and idle.
    case ready
    /// Alive and doing something: a terminal's process, a chat's agent.
    case working
    /// Was alive and is over: a terminal that exited.
    case ended
    /// Not there, yet or any more: an artifact not written, a chat archived.
    case missing
}

public struct WidgetItemInfo: Equatable, Sendable {
    public let ref: WidgetItemRef
    public let title: String
    public let phase: WidgetItemPhase
    public let updatedAt: Date?

    public init(ref: WidgetItemRef, title: String, phase: WidgetItemPhase = .ready, updatedAt: Date? = nil) {
        self.ref = ref
        self.title = title
        self.phase = phase
        self.updatedAt = updatedAt
    }
}

/// A tile's identity: unique per tile, so two tiles of one item never share state. A viewer keeps whatever it holds per tile (a web
/// view, a find query) under `key`, and drops it in `WidgetItemProvider.release`.
public struct WidgetItemSurface: Hashable, Sendable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

// MARK: - Menu action

/// The entry the host adds to a widget's `···` menu while the widget is showing a detachable item. The host builds it; a widget never
/// does.
public struct WidgetItemAction {
    public let title: String
    public let systemImage: String
    public let perform: () -> Void

    public init(title: String, systemImage: String, perform: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.perform = perform
    }
}

// MARK: - Provider

/// What a collection widget implements to describe its items.
@MainActor
public protocol WidgetItemProvider: AnyObject {

    var kinds: [WidgetItemKind] { get }

    /// The item this widget is showing right now, or nil (a list, nothing selected). Read live. While it is non-nil and its kind is
    /// `detachable`, the host offers "Open as its own widget" in the widget's `···` menu.
    var currentItem: WidgetItemRef? { get }

    /// Every item of `kind`, for the agent's widget list and the iPad.
    func items(of kind: String) -> [WidgetItemInfo]

    /// The item's title and phase, read live.
    func info(for ref: WidgetItemRef) -> WidgetItemInfo

    /// The view that draws exactly this item, edge to edge.
    func makeViewer(for ref: WidgetItemRef, surface: WidgetItemSurface) -> AnyView

    /// A tile closed: drop what it held under `surface`.
    func release(_ surface: WidgetItemSurface)

    /// Which of this provider's items have a tile now. A collection marks them "in a widget"; a `.one` collection moves off an item
    /// that just got a tile.
    func tilesChanged(_ tiled: Set<WidgetItemRef>)
}

extension WidgetItemProvider {
    public var currentItem: WidgetItemRef? { nil }
    public func release(_ surface: WidgetItemSurface) {}
    public func tilesChanged(_ tiled: Set<WidgetItemRef>) {}
}
