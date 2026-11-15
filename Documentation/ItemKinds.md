# Item kinds (SDK 2.15.0, ABI 16)

A widget that is a **collection** (a list of artifacts, notes, pull requests) can let each item stand alone as a tile of its own, next to the
chat. The SDK calls this an *item kind*. No ABI bump: a plugin built for ABI 16 loads unchanged, and a widget that adopts item kinds still
loads in an older host, which ignores them.

## The vocabulary (`Work42UI`)

| Type | What it is |
|---|---|
| `WidgetItemKind` | A kind of item: `id`, `collection` (the widget slug that lists it), `symbol`, `viewers`, `detachable`, `missingTitle`, `missingDetail`. |
| `WidgetItemViewers` | `.many` (the same item may be in several tiles) or `.one` (one tile shows it; the others give way). |
| `WidgetItemRef` | One item: `kind` and `id`. Its `key` is `<kind>:<id>`, which is also the leaf the tab stores. `init?(key:)` parses one. |
| `WidgetItemInfo` | What the host shows about an item: `ref`, `title`, `phase`, `updatedAt`. |
| `WidgetItemPhase` | `.ready`, `.working`, `.ended`, `.missing`. |
| `WidgetItemSurface` | The key of one tile's surface, handed to `makeItemViewer` and, when the tile closes, to `release`. |
| `WidgetItemAction` | A title, a symbol and a closure, for an entry the host puts in an item tile's header. |
| `WidgetItemProvider` | The host-side protocol a provider implements (`kinds`, `items(of:)`, `info(for:)`, `makeViewer(for:surface:)`, `currentItem`, `release(_:)`, `tilesChanged(_:)`). |

`WidgetChrome.itemAction` is set by the host: a collection widget's own header can show the "Open as its own widget" entry for the item it
is showing.

Work42UI uses library evolution, so a `switch` over `WidgetItemViewers` or `WidgetItemPhase` needs `@unknown default`.

## Kind ids

A kind id is a lowercase slug (`WidgetItemRef.isValidKindId`). `widget` and `file` are reserved, since other leaves already begin with
them. A kind id is global, so a second registration of one that exists is refused, naming it. A plugin's kind must be its widget's slug or
the slug and a hyphenated suffix (`github-prs`, `github-prs-pr`; see `WidgetItemKind.isPluginKind(_:ownedBy:)`).

## Offering item kinds from a plugin (`Work42PluginKit`)

Adopt `Work42ItemWidget` next to `Work42Widget`. The host finds it with a conditional cast, as it does `Work42WidgetHeaderLabels`, so it is
not a requirement of `Work42Widget`.

```swift
final class NotesWidget: Work42Widget, Work42ItemWidget {
    var itemKinds: [WidgetItemKind] {
        [WidgetItemKind(id: "notes-note", collection: "notes", symbol: "note.text", viewers: .many, detachable: true,
                        missingTitle: "Note not written yet", missingDetail: "It appears here once it is written.")]
    }

    func items(of kind: String, services: SessionServices) -> [WidgetItemInfo] { /* every note */ }
    func info(for ref: WidgetItemRef, services: SessionServices) -> WidgetItemInfo { /* title and phase */ }
    func makeItemViewer(for ref: WidgetItemRef, surface: WidgetItemSurface, services: SessionServices) -> AnyView { /* the note */ }

    // Optional, with no-op defaults:
    func currentItem(services: SessionServices) -> WidgetItemRef? { /* the note being shown now */ }
    func releaseItem(_ surface: WidgetItemSurface, services: SessionServices) {}
    func tilesChanged(_ tiled: Set<WidgetItemRef>, services: SessionServices) {}
}
```

To open or focus an item's tile from the widget's own UI, call `widget_open` with the item key (`WidgetItemRef.key`) through
`services.tools`; the host does the rest.

## What the host does with a kind

- **One router.** The `···` entry ("Open as its own widget", or "Go to its widget" when the item has a tile), a card in the chat, the
  agent's `widget_open` and a device's request all take the same path: a tab that already holds the tile is focused, otherwise the tile
  joins the tab in front.
- **Not in the picker.** An item tile is never offered by `+ Widget`; it is opened by its key.
- **Missing items.** A ref whose item does not exist shows the kind's `missingTitle` and `missingDetail` instead of an error.
- **One viewer.** For a `.one` kind the tab in front wins, then tab order; the others give way.
- **The collection's view.** `tilesChanged(_:)` tells the collection which items have a tile, so it can mark them "in a widget".

## Limits

- A plugin cannot announce that its items changed: the host reads them again when the layout changes.
- The one-viewer rule holds across the views and duplicated tabs of one panel, not across windows.
- The iPad draws artifact tiles only; an item of a plugin's kind is kept in the layout but not drawn there.
