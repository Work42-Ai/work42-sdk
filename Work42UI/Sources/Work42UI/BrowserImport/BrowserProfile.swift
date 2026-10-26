// BrowserProfile.swift - the profiles a browser has, and where each keeps its cookies (WOR-417).

import Foundation

public nonisolated struct BrowserProfile: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let cookiesURL: URL

    public init(id: String, name: String, cookiesURL: URL) {
        self.id = id
        self.name = name
        self.cookiesURL = cookiesURL
    }

    /// The profiles of `browser` that have a cookie store. Empty when the browser has none.
    public static func profiles(for browser: ImportableBrowser) throws -> [BrowserProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return try profiles(for: browser, root: browser.dataRoot(home: home), home: home)
    }

    static func profiles(for browser: ImportableBrowser, root: URL, home: URL) throws -> [BrowserProfile] {
        switch browser {
        case .safari: return safariProfiles(root: root, home: home)
        case .firefox: return try firefoxProfiles(root: root)
        case .chrome, .arc, .brave, .edge, .chromium: return try chromiumProfiles(root: root)
        }
    }

    // MARK: Chromium

    /// `<root>/Local State` lists the profiles under `profile.info_cache`: `{ "<dir>": { name, user_name } }`.
    private static func chromiumProfiles(root: URL) throws -> [BrowserProfile] {
        let localState = root.appendingPathComponent("Local State")
        guard FileManager.default.fileExists(atPath: localState.path) else { return [] }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: Data(contentsOf: localState))
        } catch {
            throw CookieImportError.unreadable("The profile list (Local State) could not be read.")
        }
        guard let top = json as? [String: Any],
              let profile = top["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }
        return cache.keys.sorted(by: chromiumDirectoryOrder).compactMap { directory in
            let folder = root.appendingPathComponent(directory, isDirectory: true)
            let candidates = [folder.appendingPathComponent("Network/Cookies"), folder.appendingPathComponent("Cookies")]
            guard let cookies = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
            let info = cache[directory] ?? [:]
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directory
            let user = info["user_name"] as? String ?? ""
            return BrowserProfile(id: directory, name: user.isEmpty ? name : "\(name) (\(user))", cookiesURL: cookies)
        }
    }

    /// "Default" first, then "Profile 1", "Profile 2", … in numeric order.
    private static func chromiumDirectoryOrder(_ a: String, _ b: String) -> Bool {
        if a == "Default" || b == "Default" { return a == "Default" && b != "Default" }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    // MARK: Firefox

    /// `<root>/profiles.ini`: `[ProfileN]` sections with `Name=`, `IsRelative=` and `Path=`.
    private static func firefoxProfiles(root: URL) throws -> [BrowserProfile] {
        let ini = root.appendingPathComponent("profiles.ini")
        guard FileManager.default.fileExists(atPath: ini.path) else { return [] }
        guard let text = try? String(contentsOf: ini, encoding: .utf8) else {
            throw CookieImportError.unreadable("The profile list (profiles.ini) could not be read.")
        }
        var sections: [[String: String]] = []
        var isProfile = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                isProfile = line.lowercased().hasPrefix("[profile")
                if isProfile { sections.append([:]) }
            } else if isProfile, let equals = line.firstIndex(of: "=") {
                sections[sections.count - 1][String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        return sections.compactMap { section in
            guard let path = section["Path"] else { return nil }
            let folder = section["IsRelative"] == "1"
                ? root.appendingPathComponent(path, isDirectory: true)
                : URL(fileURLWithPath: path, isDirectory: true)
            let cookies = folder.appendingPathComponent("cookies.sqlite")
            guard FileManager.default.fileExists(atPath: cookies.path) else { return nil }
            return BrowserProfile(id: path, name: section["Name"] ?? path, cookiesURL: cookies)
        }
    }

    // MARK: Safari

    /// One profile. The cookie file lives in Safari's container, which macOS protects: a permission error there
    /// still means the file is present (the reader reports Full Disk Access), so only a missing file falls back to
    /// the older location.
    private static func safariProfiles(root: URL, home: URL) -> [BrowserProfile] {
        let container = root.appendingPathComponent("Cookies.binarycookies")
        let legacy = home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")
        let url = isMissing(container) && !isMissing(legacy) ? legacy : container
        return [BrowserProfile(id: "safari", name: "Safari", cookiesURL: url)]
    }

    private static func isMissing(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) != 0 && errno == ENOENT
    }
}
