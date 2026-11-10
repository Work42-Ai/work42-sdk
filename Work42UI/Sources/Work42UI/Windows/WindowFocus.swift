// WindowFocus.swift — which window is the user in, across every window of the app?
//
// The Mac has floating session windows and the iPad has one window per account. Both need the same answers: which window do Return,
// dictation, the Pencil and a comment on a highlight act on? One model holds the rules, and each app only reports its platform's
// window events (AppKit key-window changes on the Mac, UIKit key-window and scene changes on the iPad).
//
// Rules:
//   - A window becoming key is the most recently focused window and the target of what the user does next.
//   - The last focused window stays the target when the app goes to the background (no window is key then).
//   - When the last focused window closes, the most recently focused one still open takes over.
//   - A window that is not registered (Settings, an open panel) changes nothing but `keyWindow`: it never becomes a target.

import Observation
import SwiftUI

@MainActor
@Observable
public final class WindowFocus {
    /// One window: the `NSWindow` on the Mac, the `UIWindowScene` on the iPad.
    public typealias ID = ObjectIdentifier

    /// The app's windows. Tests make their own.
    public static let shared = WindowFocus()

    public init() {}

    /// The window that has the keyboard now; nil when none does (the app is in the background, or a panel has it).
    public private(set) var keyWindow: ID?

    /// The registered window the user focused last. It outlives the keyboard leaving the app.
    public private(set) var lastFocused: ID?

    /// The registered windows, the most recently focused first.
    public private(set) var order: [ID] = []

    @ObservationIgnored private var registered: Set<ID> = []

    /// Starts tracking `id`. A window that is already key becomes the focused one at once.
    public func register(_ id: ID, isKey: Bool) {
        if registered.insert(id).inserted { order.append(id) }
        if isKey { becameKey(id) }
    }

    /// Stops tracking `id`. If it was the last focused window, the most recent survivor takes over (nil when none is left).
    public func unregister(_ id: ID) {
        guard registered.remove(id) != nil else {
            if keyWindow == id { keyWindow = nil }
            return
        }
        order.removeAll { $0 == id }
        if keyWindow == id { keyWindow = nil }
        if lastFocused == id { lastFocused = order.first }
    }

    public func becameKey(_ id: ID) {
        keyWindow = id
        guard registered.contains(id) else { return }
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        lastFocused = id
    }

    /// `id` lost the keyboard. `lastFocused` stays: the target does not change when the app goes to the background.
    public func resignedKey(_ id: ID) {
        if keyWindow == id { keyWindow = nil }
    }

    /// The window `view` is in, as both apps name it: `nil` while the view is in no window.
    public static func id(of view: PlatformView) -> ID? {
        #if canImport(AppKit)
        return view.window.map { ObjectIdentifier($0) }
        #else
        return view.window?.windowScene.map { ObjectIdentifier($0) }
        #endif
    }
}

extension EnvironmentValues {
    /// The window the view is in, set by each window's root so SDK surfaces can say which window their selection belongs to.
    @Entry public var windowFocusID: WindowFocus.ID?
}
