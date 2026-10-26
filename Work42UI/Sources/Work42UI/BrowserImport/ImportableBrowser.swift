// ImportableBrowser.swift - the browsers whose sign-in cookies Work42 can import (WOR-417).
//
// Safari, the Chromium family (Chrome, Arc, Brave, Edge, Chromium) and Firefox. Everything here is a pure
// description of where a browser keeps its data and what its Keychain entry is called; reading the data is
// done by the readers next to this file.

import AppKit
import Foundation

public nonisolated enum ImportableBrowser: String, CaseIterable, Sendable {
    case safari, chrome, arc, brave, edge, chromium, firefox

    public var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .arc: "Arc"
        case .brave: "Brave"
        case .edge: "Edge"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .arc: "company.thebrowser.Browser"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .chromium: "org.chromium.Chromium"
        case .firefox: "org.mozilla.firefox"
        }
    }

    /// Chrome, Arc, Brave, Edge and Chromium keep cookies in the same encrypted SQLite format.
    public var isChromium: Bool {
        switch self {
        case .chrome, .arc, .brave, .edge, .chromium: true
        case .safari, .firefox: false
        }
    }

    /// Where the browser keeps its profiles (Safari: its cookie folder).
    public var dataRoot: URL { dataRoot(home: FileManager.default.homeDirectoryForCurrentUser) }

    func dataRoot(home: URL) -> URL {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        switch self {
        case .safari: return home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies", isDirectory: true)
        case .chrome: return support.appendingPathComponent("Google/Chrome", isDirectory: true)
        case .arc: return support.appendingPathComponent("Arc/User Data", isDirectory: true)
        case .brave: return support.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true)
        case .edge: return support.appendingPathComponent("Microsoft Edge", isDirectory: true)
        case .chromium: return support.appendingPathComponent("Chromium", isDirectory: true)
        case .firefox: return support.appendingPathComponent("Firefox", isDirectory: true)
        }
    }

    /// The Keychain item that holds the key a Chromium browser encrypts its cookies with (nil for the others).
    var keychainService: String? {
        switch self {
        case .chrome: "Chrome Safe Storage"
        case .arc: "Arc Safe Storage"
        case .brave: "Brave Safe Storage"
        case .edge: "Microsoft Edge Safe Storage"
        case .chromium: "Chromium Safe Storage"
        case .safari, .firefox: nil
        }
    }

    var keychainAccount: String? {
        switch self {
        case .chrome: "Chrome"
        case .arc: "Arc"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .chromium: "Chromium"
        case .safari, .firefox: nil
        }
    }

    /// The browsers installed on this Mac, in `allCases` order: the app is found by bundle identifier and, except
    /// for Safari (whose folder is protected), its data folder exists.
    @MainActor
    public static func installed() -> [ImportableBrowser] {
        allCases.filter { browser in
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil else { return false }
            return browser == .safari || FileManager.default.fileExists(atPath: browser.dataRoot.path)
        }
    }
}
