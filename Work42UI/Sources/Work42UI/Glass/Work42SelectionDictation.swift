// Work42SelectionDictation.swift — who holds a highlight, for the Apple Pencil squeeze (AC166).
//
// A highlight's "Dictate Work42" menu item starts a dictation aimed at that highlight, and its widget glows. The squeeze has no menu to
// choose from, so every surface that offers the item registers here with the same action, and the squeeze runs whichever surface the
// person highlighted in last. Plain Swift (no UIKit), so the ordering is testable anywhere; only the iPad registers owners.

import Foundation

@MainActor
public enum Work42SelectionDictation {
    private struct Entry {
        weak var owner: AnyObject?
        var stamp: Int
        let dictate: @MainActor () async -> Bool
    }

    private static var entries: [Entry] = []
    private static var counter = 0

    /// Registers `owner`'s action: it dictates a comment on the owner's live highlight and returns true, or returns false when the
    /// owner has no highlight. Registering again replaces the action and keeps the owner's place in the order. Held weakly.
    public static func register(_ owner: AnyObject, dictate: @escaping @MainActor () async -> Bool) {
        entries.removeAll { $0.owner == nil }
        if let index = entries.firstIndex(where: { $0.owner === owner }) {
            entries[index] = Entry(owner: owner, stamp: entries[index].stamp, dictate: dictate)
        } else {
            entries.append(Entry(owner: owner, stamp: 0, dictate: dictate))
        }
    }

    public static func unregister(_ owner: AnyObject) {
        entries.removeAll { $0.owner == nil || $0.owner === owner }
    }

    /// The owner's selection just changed: it is now the one asked first.
    public static func noteSelectionChanged(_ owner: AnyObject) {
        guard let index = entries.firstIndex(where: { $0.owner === owner }) else { return }
        counter += 1
        entries[index].stamp = counter
    }

    /// Asks the owners, the most recently highlighted first, and stops at the first that dictates. False when none has a highlight.
    public static func dictateHighlight() async -> Bool {
        entries.removeAll { $0.owner == nil }
        for entry in entries.sorted(by: { $0.stamp > $1.stamp }) where entry.owner != nil {
            if await entry.dictate() { return true }
        }
        return false
    }
}
